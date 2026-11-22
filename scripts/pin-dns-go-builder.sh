#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <dockerfile>" >&2
  exit 2
fi

dockerfile="$1"
DNS_GO_BUILDER_IMAGE="golang:1.27.4-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280"

# Match the stage alias and preserve any platform flag on its FROM line.
shopt -s nocasematch
stage_pattern='^([[:blank:]]*FROM[[:blank:]]+(--platform=[^[:space:]]+[[:blank:]]+)?)[^[:space:]]+([[:blank:]]+AS[[:blank:]]+builder-dnstool[[:space:]]*)$'
matches=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ "${line}" =~ ${stage_pattern} ]]; then
    original="${line}"
    replacement="${BASH_REMATCH[1]}${DNS_GO_BUILDER_IMAGE}${BASH_REMATCH[3]}"
    ((matches += 1))
  fi
done < "${dockerfile}"

if [ "${matches}" -ne 1 ]; then
  echo "ERROR: expected exactly 1 builder-dnstool stage in ${dockerfile}, found ${matches}" >&2
  exit 1
fi

bash "$(dirname "${BASH_SOURCE[0]}")/pin-base-image.sh" "${dockerfile}" "${original}" "${replacement}"
