#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 2 )); then
    echo 'Usage: benchmark_key_read.sh <server-key-directory> <report.csv>' >&2
    exit 2
fi

key_directory="$1"
report="$2"
block_size=4194304
printf 'key_set,file_bytes,read_bytes,mode,wall_seconds\n' > "$report"

for key_set in \
    rotations-layer1.bin \
    rotations-layer2-downsample.bin \
    rotations-layer2.bin \
    rotations-layer3-downsample.bin \
    rotations-layer3.bin \
    rotations-finallayer.bin; do
    key_file="$key_directory/rot_$key_set"
    if [[ ! -f "$key_file" ]]; then
        echo "Missing evaluation-key file: $key_file" >&2
        exit 1
    fi
    file_bytes="$(stat -c '%s' "$key_file")"
    blocks=$((file_bytes / block_size))
    if (( blocks == 0 )); then
        echo "Evaluation-key file is too small for direct-read control: $key_file" >&2
        exit 1
    fi
    read_bytes=$((blocks * block_size))
    started="$(date +%s%N)"
    if dd if="$key_file" of=/dev/null bs="$block_size" count="$blocks" \
          iflag=direct status=none 2>/dev/null; then
        mode=direct
    else
        # Some filesystems do not support O_DIRECT. Keep the measurement, but
        # label it buffered so it cannot be mistaken for a physical-I/O control.
        started="$(date +%s%N)"
        dd if="$key_file" of=/dev/null bs="$block_size" count="$blocks" status=none
        mode=buffered_fallback
    fi
    ended="$(date +%s%N)"
    wall_seconds="$(awk -v start="$started" -v end="$ended" \
        'BEGIN {printf "%.3f", (end-start)/1000000000}')"
    printf '%s,%s,%s,%s,%s\n' \
        "$key_set" "$file_bytes" "$read_bytes" "$mode" "$wall_seconds" >> "$report"
done
