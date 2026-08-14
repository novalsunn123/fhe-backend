#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 2 || $# > 3 )); then
    echo "Usage: validate_batch_manifest.sh <repository-root> <manifest> [expected-count]" >&2
    exit 2
fi

REPO_ROOT="$(cd -- "$1" && pwd -P)"
MANIFEST="$2"
EXPECTED_COUNT="${3:-10}"

if [[ ! "$EXPECTED_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Expected count must be a positive integer." >&2
    exit 2
fi
if [[ ! -f "$MANIFEST" ]]; then
    echo "Missing batch manifest: $MANIFEST" >&2
    exit 2
fi

declare -A SEEN=()
count=0
handgun_count=0
knife_count=0
while IFS=$'\t' read -r image_path expected_class extra; do
    [[ -z "$image_path" || "$image_path" == \#* ]] && continue
    if [[ -n "${extra:-}" || -z "$expected_class" ]]; then
        echo "Invalid manifest row: expected exactly two tab-separated fields: $image_path" >&2
        exit 2
    fi
    if [[ "$image_path" == /* || "$image_path" == *".."* ]]; then
        echo "Unsafe image path in manifest: $image_path" >&2
        exit 2
    fi
    if [[ "$expected_class" != "Handgun" && "$expected_class" != "Knife" ]]; then
        echo "Invalid expected class for $image_path: $expected_class" >&2
        exit 2
    fi
    if [[ -n "${SEEN[$image_path]+present}" ]]; then
        echo "Duplicate image in manifest: $image_path" >&2
        exit 2
    fi
    if [[ ! -f "$REPO_ROOT/$image_path" ]]; then
        echo "Missing manifest image: $image_path" >&2
        exit 2
    fi
    case "${image_path,,}" in
        *.png|*.jpg|*.jpeg) ;;
        *) echo "Unsupported image extension: $image_path" >&2; exit 2 ;;
    esac
    SEEN["$image_path"]=1
    count=$((count + 1))
    if [[ "$expected_class" == "Handgun" ]]; then
        handgun_count=$((handgun_count + 1))
    else
        knife_count=$((knife_count + 1))
    fi
done < "$MANIFEST"

if (( count != EXPECTED_COUNT )); then
    echo "Manifest must contain $EXPECTED_COUNT images; found $count." >&2
    exit 2
fi
if (( EXPECTED_COUNT == 10 && (handgun_count != 5 || knife_count != 5) )); then
    echo "The 10-image baseline must contain 5 Handgun and 5 Knife images." >&2
    exit 2
fi

printf 'Validated %d images (%d Handgun, %d Knife).\n' \
    "$count" "$handgun_count" "$knife_count"
