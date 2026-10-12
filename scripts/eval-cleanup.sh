#!/usr/bin/env bash
# Measures dictation cleanup against tests/fixtures/cleanup-eval with Apple's
# on-device model and prints the results table. Needs Apple Intelligence.
# Usage: scripts/eval-cleanup.sh [variants] [runs]   e.g. scripts/eval-cleanup.sh a,b 3
# Variants: a model alone, b cleanup pipeline, c pipeline prompt unvalidated,
# d pipeline unchunked, e edit-based. Compare with docs/omniflow/cleanup-eval.md.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d "${TMPDIR:-/tmp}/omniflow-cleanup-eval.XXXXXX")"
OMNIFLOW_EVAL=1 OMNIFLOW_EVAL_VARIANTS="${1:-b}" OMNIFLOW_EVAL_RUNS="${2:-1}" OMNIFLOW_EVAL_OUT="$OUT" \
    swift test --filter cleanupEvaluation >"$OUT/test.log" 2>&1 || { tail -40 "$OUT/test.log"; exit 1; }
cat "$OUT/results.md"
echo
echo "Per-case rows: $OUT/results.tsv; outputs: $OUT/outputs.json"
