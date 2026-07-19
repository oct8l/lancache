#!/usr/bin/env bash
# TLS SNI pass-through test: proves the candidate sniproxy image correctly
# forwards a TLS connection to a controlled origin based on SNI, without
# terminating TLS itself. Run from this directory with SNIPROXY_IMAGE
# already exported and `docker compose up -d --build` already applied.
set -euo pipefail

EXPECTED_CONTENT="sniproxy-tls-passthrough-ok"

echo "== Sanity check: origin serves the expected content directly =="
# "sniproxy-test.internal" is registered as a network alias for the origin
# service itself, so a plain request (no --connect-to override) resolves
# straight to origin, bypassing sniproxy entirely -- confirming the fixture
# itself is correct before trusting the pass-through result below.
direct=$(docker compose exec -T client curl -sk "https://sniproxy-test.internal/")
if [ "${direct}" != "${EXPECTED_CONTENT}" ]; then
  echo "FAIL: origin fixture itself did not return the expected content (got '${direct}')" >&2
  exit 1
fi
echo "OK: origin fixture serves '${EXPECTED_CONTENT}' directly"

echo "== TLS SNI pass-through through candidate sniproxy =="
via_sniproxy=$(docker compose exec -T client curl -sk \
  --connect-to sniproxy-test.internal:443:sniproxy:443 \
  https://sniproxy-test.internal/)

if [ "${via_sniproxy}" != "${EXPECTED_CONTENT}" ]; then
  echo "FAIL: expected '${EXPECTED_CONTENT}' through sniproxy, got '${via_sniproxy}'" >&2
  exit 1
fi

echo "OK: TLS SNI pass-through through sniproxy reached the controlled origin"
