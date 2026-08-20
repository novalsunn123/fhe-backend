#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 1 )); then
    echo "Usage: validate_change_note.sh <change-note.md>" >&2
    exit 2
fi

NOTE_FILE="$1"
if [[ ! -s "$NOTE_FILE" ]]; then
    echo "Change note is missing or empty: $NOTE_FILE" >&2
    exit 2
fi

note_bytes="$(wc -c < "$NOTE_FILE")"
if (( note_bytes > 12000 )); then
    echo "Change note is too large (${note_bytes} bytes; maximum 12000)." >&2
    exit 2
fi

required_headings=(
    "## Đã sửa gì"
    "## Cơ chế"
    "## Cách hoạt động"
    "## Lợi ích"
)

for heading in "${required_headings[@]}"; do
    if ! grep -Fqx "$heading" "$NOTE_FILE"; then
        echo "Change note must contain the exact heading: $heading" >&2
        exit 3
    fi
    if ! awk -v heading="$heading" '
        $0 == heading {inside = 1; next}
        inside && /^## / {exit}
        inside && /[^[:space:]]/ {content = 1}
        END {exit !content}
    ' "$NOTE_FILE"; then
        echo "Change note heading has no content: $heading" >&2
        exit 3
    fi
done

if grep -Fq '<!-- DEV_HISTORY_' "$NOTE_FILE"; then
    echo "Change note may not contain README history control markers." >&2
    exit 3
fi

for placeholder in \
    'Mô tả ngắn gọn phần mã nguồn hoặc hành vi đã thay đổi.' \
    'Giải thích kỹ thuật hoặc cơ chế mới được thêm/cải tiến.' \
    'Mô tả luồng xử lý sau thay đổi và các thành phần liên quan.' \
    'Nêu lợi ích có thể kiểm chứng: tốc độ, RAM, độ ổn định hoặc khả năng bảo trì.'; do
    if grep -Fqx "$placeholder" "$NOTE_FILE"; then
        echo "Replace all template text before submitting: $placeholder" >&2
        exit 3
    fi
done
