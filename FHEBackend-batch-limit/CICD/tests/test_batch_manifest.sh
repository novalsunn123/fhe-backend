#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
"$ROOT/CICD/validate_batch_manifest.sh" \
    "$ROOT" "$ROOT/CICD/benchmark10-images.tsv" 10

actual_hash="$(sha256sum "$ROOT/CICD/benchmark10-images.tsv" | awk '{print $1}')"
[[ ${#actual_hash} -eq 64 ]]
echo "Batch manifest test passed."
