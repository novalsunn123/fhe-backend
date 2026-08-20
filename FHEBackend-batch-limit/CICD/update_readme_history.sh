#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 6 || $# > 7 )); then
    echo "Usage: update_readme_history.sh <readme> <entry.md> <output> <repository> <code-sha> <title> [date]" >&2
    exit 2
fi

README_FILE="$1"
ENTRY_FILE="$2"
OUTPUT_FILE="$3"
REPOSITORY="$4"
CODE_SHA="$5"
TITLE="$6"
VERSION_DATE="${7:-$(date -u +%F)}"
START_MARKER='<!-- DEV_HISTORY_START -->'
END_MARKER='<!-- DEV_HISTORY_END -->'

for file in "$README_FILE" "$ENTRY_FILE"; do
    if [[ ! -s "$file" ]]; then
        echo "Missing README history input: $file" >&2
        exit 2
    fi
done
if [[ ! "$REPOSITORY" =~ ^[^/]+/[^/]+$ || ! "$CODE_SHA" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    echo "Invalid repository or code commit SHA." >&2
    exit 2
fi

start_count="$(grep -Fxc "$START_MARKER" "$README_FILE" || true)"
end_count="$(grep -Fxc "$END_MARKER" "$README_FILE" || true)"
if [[ "$start_count" != 1 || "$end_count" != 1 ]]; then
    echo "README must contain exactly one start and one end history marker." >&2
    exit 3
fi

start_line="$(grep -Fn "$START_MARKER" "$README_FILE" | cut -d: -f1)"
end_line="$(grep -Fn "$END_MARKER" "$README_FILE" | cut -d: -f1)"
if (( start_line >= end_line )); then
    echo "README history markers are out of order." >&2
    exit 3
fi

clean_title="$(printf '%s' "$TITLE" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
short_sha="${CODE_SHA:0:7}"
entry_tmp="$(mktemp /tmp/fhe-readme-entry.XXXXXX.md)"
trap 'rm -f -- "$entry_tmp"' EXIT

{
    echo
    echo "### $VERSION_DATE — $clean_title"
    echo
    echo "**Code:** [\`$short_sha\`](https://github.com/$REPOSITORY/commit/$CODE_SHA)"
    echo
    cat "$ENTRY_FILE"
    echo
} > "$entry_tmp"

{
    head -n "$start_line" "$README_FILE"
    cat "$entry_tmp"
    tail -n "+$((start_line + 1))" "$README_FILE"
} > "$OUTPUT_FILE"
