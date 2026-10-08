#!/usr/bin/env bash
# Replaces a Dockerfile's FROM line with a pinned, digest-referenced base
# image, failing loudly if the expected line doesn't appear exactly once.
# Upstream Dockerfiles here hardcode "FROM lancachenet/<image>:latest" rather
# than parameterizing the base image via ARG, so a build-arg isn't available
# and this checked replacement is the safer alternative to a blind sed.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <dockerfile> <exact-from-line-to-replace> <replacement-from-line>" >&2
  exit 2
fi

dockerfile="$1"
pattern="$2"
replacement="$3"

# grep returns 1 for zero matches; allow the count check below to report it.
# Preserve other errors, such as an unreadable Dockerfile.
matches=$(grep -c -F -x -- "${pattern}" "${dockerfile}") || {
  status=$?
  if [ "${status}" -ne 1 ]; then
    exit "${status}"
  fi
}

if [ "${matches}" -ne 1 ]; then
  echo "ERROR: expected exactly 1 line matching '${pattern}' in ${dockerfile}, found ${matches}" >&2
  exit 1
fi

line_number=$(grep -n -F -x -- "${pattern}" "${dockerfile}" | cut -d: -f1)
sed -i "${line_number}c${replacement}" "${dockerfile}"
echo "Replaced line ${line_number} in ${dockerfile}: ${replacement}"
