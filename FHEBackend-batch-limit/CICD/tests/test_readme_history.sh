#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d /tmp/fhe-readme-test.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cat > "$TMP_ROOT/README.md" <<'EOF'
# Demo

## Lịch sử phiên bản dev

<!-- DEV_HISTORY_START -->

### 2026-08-01 — Older version

Old entry.

<!-- DEV_HISTORY_END -->
EOF

cat > "$TMP_ROOT/entry.md" <<'EOF'
#### Đã sửa gì

New behavior.

#### Benchmark so với phiên bản dev trước

| Chỉ số | Trước | Sau |
|---|---:|---:|
| Suy luận | 10s | 9s |
EOF

sha='0123456789abcdef0123456789abcdef01234567'
"$SCRIPT_DIR/update_readme_history.sh" \
    "$TMP_ROOT/README.md" "$TMP_ROOT/entry.md" "$TMP_ROOT/output.md" \
    'novalsunn123/fhe-backend' "$sha" 'perf: faster inference' '2026-08-07'

grep -Fq '### 2026-08-07 — perf: faster inference' "$TMP_ROOT/output.md"
grep -Fq '[`0123456`](https://github.com/novalsunn123/fhe-backend/commit/' "$TMP_ROOT/output.md"
new_line="$(grep -Fn 'perf: faster inference' "$TMP_ROOT/output.md" | cut -d: -f1)"
old_line="$(grep -Fn 'Older version' "$TMP_ROOT/output.md" | cut -d: -f1)"
if (( new_line >= old_line )); then
    echo "Newest README version was not inserted first." >&2
    exit 1
fi

echo "README version history test passed."
