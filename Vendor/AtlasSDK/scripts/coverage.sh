#!/usr/bin/env bash
set -euo pipefail

coverage_file="${1:-coverage.out}"
minimum="${ATLAS_GO_COVERAGE_MIN:-50.0}"

# Public SDK packages are the coverage boundary. Examples are compiled by the
# race suite, but are excluded from the library coverage denominator.
go test -count=1 -covermode=atomic -coverprofile="$coverage_file" ./pkg/...

total="$({ go tool cover -func="$coverage_file"; } | awk '/^total:/ { gsub(/%/, "", $3); print $3 }')"

if [[ -z "$total" ]]; then
  echo "Unable to read total Go coverage from $coverage_file" >&2
  exit 1
fi

echo "Go coverage: ${total}% (minimum ${minimum}%)"

awk -v total="$total" -v minimum="$minimum" 'BEGIN { exit(total + 0 >= minimum + 0 ? 0 : 1) }'
