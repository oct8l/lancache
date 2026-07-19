#!/usr/bin/env bash
# Deterministic DNS + cache content integration test. Run from this directory
# with DNS_IMAGE and MONOLITHIC_IMAGE already exported. Assumes
# `docker compose up -d --build` has already brought the stack up and it is
# healthy (the caller owns bring-up/teardown so it can capture diagnostics on
# failure).
set -euo pipefail

# Must match the static addresses assigned in docker-compose.yml.
DNS_IP="10.24.0.10"
MONOLITHIC_IP="10.24.0.11"
ORIGIN_IP="10.24.0.20"

# A real, currently-configured cache domain. Content-flow and 20_cache.conf
# assertions are run against this single hostname (see Phase 2.4: cache-semantic
# coverage is intentionally decoupled from service-name/RPZ coverage below).
PRIMARY_HOST="lancache.steamcontent.com"

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

client_exec() {
  docker compose exec -T client "$@"
}

# Fetches $2 through the cache with Host header $1, writing headers to $3 and
# body to $4. Extra curl args may follow.
fetch() {
  local host="$1" path="$2" headers_out="$3" body_out="$4"
  shift 4
  client_exec curl -s -D "$headers_out" -o "$body_out" -H "Host: ${host}" "$@" \
    "http://${MONOLITHIC_IP}${path}"
}

# $1 is a path to a headers file written inside the client container by fetch().
cache_status() {
  client_exec cat "$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-upstream-cache-status"{print $2}'
}

http_status() {
  client_exec cat "$1" | tr -d '\r' | head -n1 | awk '{print $2}'
}

origin_hits() {
  client_exec curl -s "http://${ORIGIN_IP}:8080/stats" | client_exec jq -r ".hits[\"$1\"] // 0"
}

echo "== Installing test-only fixture location on monolithic =="
docker compose exec -T monolithic sh -c '
cat > /etc/nginx/sites-available/cache.conf.d/50_ci_fixture.conf << "NGINXEOF"
location ^~ /lancache-ci-fixture/ {
    include /etc/nginx/sites-available/cache.conf.d/root/30_cache_key.conf;
    include /etc/nginx/sites-available/cache.conf.d/root/20_cache.conf;
    include /etc/nginx/sites-available/cache.conf.d/root/99_debug_header.conf;

    proxy_pass http://'"${ORIGIN_IP}"':8080/;
    proxy_set_header Host $host;
}
NGINXEOF
nginx -t && nginx -s reload
'

echo "== DNS: representative cache-domain names resolve to monolithic =="
for domain in \
  lancache.steamcontent.com \
  download.epicgames.com \
  origin-a.akamaihd.net \
  blzddist1-a.akamaihd.net \
  uplaypc-s-ubisoft.cdn.ubi.com \
  ; do
  result=$(client_exec dig +short "@${DNS_IP}" "${domain}" A | tail -n1)
  if [ "${result}" != "${MONOLITHIC_IP}" ]; then
    fail "DNS: ${domain} resolved to '${result}', expected monolithic IP ${MONOLITHIC_IP}"
  else
    echo "OK: ${domain} -> ${MONOLITHIC_IP}"
  fi
done

echo "== DNS: a non-cache-domain name is not hijacked to monolithic =="
noncache_result=$(client_exec dig +short "@${DNS_IP}" example.com A | tail -n1)
if [ "${noncache_result}" = "${MONOLITHIC_IP}" ]; then
  fail "DNS: example.com incorrectly resolved to monolithic IP ${MONOLITHIC_IP}"
else
  echo "OK: example.com did not resolve to monolithic (got '${noncache_result}')"
fi

echo "== Content flow: miss, hit, correctness, persistence =="
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/fixture.bin" /tmp/h1.txt /tmp/b1.bin
status1=$(cache_status /tmp/h1.txt)
[ "${status1}" = "MISS" ] || fail "expected first request to be MISS, got '${status1}'"

fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/fixture.bin" /tmp/h2.txt /tmp/b2.bin
status2=$(cache_status /tmp/h2.txt)
[ "${status2}" = "HIT" ] || fail "expected second request to be HIT, got '${status2}'"

want=$(sha256sum fixtures/fixture.bin | awk '{print $1}')
for body in /tmp/b1.bin /tmp/b2.bin; do
  got=$(client_exec sha256sum "${body}" | awk '{print $1}')
  [ "${got}" = "${want}" ] || fail "${body} checksum mismatch: got ${got}, want ${want}"
done

cache_size=$(docker compose exec -T monolithic sh -c 'du -sk /data/cache/cache 2>/dev/null | cut -f1' | tr -d '\r')
[ "${cache_size:-0}" -gt 0 ] || fail "cache storage is empty after priming (expected non-zero size, got '${cache_size}')"

echo "== Strong cache-hit proof: stop origin, confirm cached content still serves =="
docker compose stop origin >/dev/null
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/fixture.bin" /tmp/h3.txt /tmp/b3.bin
status3=$(cache_status /tmp/h3.txt)
[ "${status3}" = "HIT" ] || fail "expected HIT while origin is stopped, got '${status3}'"
got3=$(client_exec sha256sum /tmp/b3.bin | awk '{print $1}')
[ "${got3}" = "${want}" ] || fail "response served while origin stopped did not match fixture checksum"

echo "== Persistence across monolithic restart (origin still stopped) =="
docker compose restart monolithic >/dev/null
for _ in $(seq 1 15); do
  docker compose exec -T monolithic curl -fsS -o /dev/null http://127.0.0.1/lancache-heartbeat && break
  sleep 2
done
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/fixture.bin" /tmp/h4.txt /tmp/b4.bin
status4=$(cache_status /tmp/h4.txt)
[ "${status4}" = "HIT" ] || fail "expected HIT after monolithic restart, got '${status4}'"
got4=$(client_exec sha256sum /tmp/b4.bin | awk '{print $1}')
[ "${got4}" = "${want}" ] || fail "response served after restart did not match fixture checksum"

echo "== Restarting origin for remaining 20_cache.conf scenario tests =="
docker compose start origin >/dev/null
for _ in $(seq 1 15); do
  docker compose exec -T origin wget -qO- http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break
  sleep 1
done

echo "== nocache=1 bypasses the cache =="
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/nocache.bin" /tmp/hn1.txt /tmp/bn1.bin
[ "$(cache_status /tmp/hn1.txt)" = "MISS" ] || fail "nocache.bin: expected first request MISS"
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/nocache.bin" /tmp/hn2.txt /tmp/bn2.bin
[ "$(cache_status /tmp/hn2.txt)" = "HIT" ] || fail "nocache.bin: expected second request HIT"
hits_before_bypass=$(origin_hits "/nocache.bin")
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/nocache.bin?nocache=1" /tmp/hn3.txt /tmp/bn3.bin
status_bypass=$(cache_status /tmp/hn3.txt)
[ "${status_bypass}" = "BYPASS" ] || fail "nocache=1: expected BYPASS, got '${status_bypass}'"
hits_after_bypass=$(origin_hits "/nocache.bin")
[ "${hits_after_bypass}" -gt "${hits_before_bypass}" ] || fail "nocache=1: origin was not actually re-fetched (hits ${hits_before_bypass} -> ${hits_after_bypass})"

echo "== Range requests return correct bytes across a slice boundary =="
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/range.bin" /tmp/hr.txt /tmp/br.bin -H "Range: bytes=900000-1100000"
range_status=$(http_status /tmp/hr.txt)
[ "${range_status}" = "206" ] || fail "range request: expected HTTP 206, got ${range_status}"
dd if=fixtures/fixture.bin bs=1 skip=900000 count=200001 2>/dev/null >/tmp/expected_range.bin
got_range=$(client_exec sha256sum /tmp/br.bin | awk '{print $1}')
want_range=$(sha256sum /tmp/expected_range.bin | awk '{print $1}')
[ "${got_range}" = "${want_range}" ] || fail "range response bytes did not match expected slice of the fixture"
rm -f /tmp/expected_range.bin

echo "== Redirect responses are not cached =="
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/redirect" /tmp/hd1.txt /tmp/bd1.bin
fetch "${PRIMARY_HOST}" "/lancache-ci-fixture/redirect" /tmp/hd2.txt /tmp/bd2.bin
[ "$(http_status /tmp/hd1.txt)" = "302" ] || fail "redirect: expected HTTP 302 on first request"
[ "$(http_status /tmp/hd2.txt)" = "302" ] || fail "redirect: expected HTTP 302 on second request"
[ "$(cache_status /tmp/hd1.txt)" = "MISS" ] || fail "redirect: expected first request MISS"
[ "$(cache_status /tmp/hd2.txt)" = "MISS" ] || fail "redirect: expected second request MISS (redirects must not be cached), got '$(cache_status /tmp/hd2.txt)'"

echo "== Concurrent first requests do not produce uncontrolled duplicate origin downloads =="
pids=()
for i in $(seq 1 8); do
  client_exec curl -s -o "/tmp/slow_${i}.bin" -H "Host: ${PRIMARY_HOST}" \
    "http://${MONOLITHIC_IP}/lancache-ci-fixture/slow.bin" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "${pid}"
done
for i in $(seq 1 8); do
  got_slow=$(client_exec sha256sum "/tmp/slow_${i}.bin" | awk '{print $1}')
  [ "${got_slow}" = "${want}" ] || fail "slow.bin request ${i}: checksum mismatch"
done
# The 2.5MB fixture spans 3 proxy_cache slices, so even a single logical
# request causes up to 3 origin fetches (one per slice). Correct
# proxy_cache_lock dedup means 8 concurrent requests still only cause the
# slice count worth of origin fetches, not 8x that.
slow_hits=$(origin_hits "/slow.bin")
if [ "${slow_hits}" -gt 3 ]; then
  fail "slow.bin: expected at most 3 origin fetches (one per slice) across 8 concurrent requests, got ${slow_hits}"
else
  echo "OK: slow.bin origin fetches = ${slow_hits} (<=3, concurrent requests were deduplicated)"
fi

if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} cache integration test(s) failed" >&2
  exit 1
fi

echo "All cache integration tests passed"
