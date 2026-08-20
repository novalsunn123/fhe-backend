#!/usr/bin/env bash
set -Eeuo pipefail

# Re-run only decrypt-error images from a completed full-validation CSV.
#
# Usage:
#   ./rerun_problem_images.sh [source_csv] [keyset]
#
# Defaults:
#   source_csv=results/run_20260810_085122.csv
#   keyset=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SOURCE_CSV="${1:-$SCRIPT_DIR/results/run_20260810_085122.csv}"
KEYSET="${2:-1}"
CLIENT_BIN="$WORKSPACE/FHEClient/build/FHEClient"
SERVER_BIN="$WORKSPACE/FHEServer/build/FHEServer"
DATASET="$WORKSPACE/LowMemoryFHEWeaponResNet20_v1/training/data/val"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$SCRIPT_DIR/rerun_problem_images/run_$RUN_ID"
CSV="$RUN_DIR/results.csv"
LOG="$RUN_DIR/results.log"
INPUT_LIST="$RUN_DIR/problem_images.csv"

if [[ ! -f "$SOURCE_CSV" ]]; then
    echo "Source CSV not found: $SOURCE_CSV" >&2
    exit 1
fi
if ! [[ "$KEYSET" =~ ^[1-4]$ ]]; then
    echo "keyset must be 1, 2, 3, or 4" >&2
    exit 1
fi
for required in "$CLIENT_BIN" "$SERVER_BIN" "$DATASET"; do
    [[ -e "$required" ]] || { echo "Missing required path: $required" >&2; exit 1; }
done
if [[ ! -f "$WORKSPACE/FHEClient/keys_exp${KEYSET}/secret-key.txt" ]]; then
    echo "Missing client secret key" >&2
    exit 1
fi
if [[ -e "$WORKSPACE/FHEServer/keys_exp${KEYSET}/secret-key.txt" ]]; then
    echo "Security error: server contains secret-key.txt" >&2
    exit 1
fi
if pgrep -f '(^|/)FHEServer infer ' >/dev/null; then
    echo "Another FHEServer inference is already running" >&2
    exit 1
fi

mkdir -p "$RUN_DIR" "$WORKSPACE/FHEClient/ciphertexts" \
    "$WORKSPACE/FHEServer/ciphertexts" "$WORKSPACE/FHEServer/results"

awk -F, '
    NR > 1 && $11 == "decrypt_error" {
        gsub(/^"|"$/, "", $1)
        print $1 "," $2
    }
' "$SOURCE_CSV" > "$INPUT_LIST"

total="$(wc -l < "$INPUT_LIST")"
if (( total == 0 )); then
    echo "No decrypt_error rows found in: $SOURCE_CSV" >&2
    exit 1
fi

printf 'image,true_class,handgun_logit,knife_logit,prediction,correct,status\n' > "$CSV"
printf 'Run: %s\nSource CSV: %s\nTarget: %s decrypt-error images\n\n' \
    "$RUN_ID" "$SOURCE_CSV" "$total" | tee "$LOG"

index=0
correct_count=0
decrypt_errors=0
while IFS=, read -r image true_class; do
    index=$((index + 1))
    image_path="$DATASET/$image"
    if [[ ! -f "$image_path" ]]; then
        echo "[$index/$total] Missing image: $image_path" | tee -a "$LOG" >&2
        printf '"%s",%s,,,,,missing_image\n' "$image" "$true_class" >> "$CSV"
        continue
    fi

    safe_name="${image//\//_}"
    request_id="${RUN_ID}_${index}_${safe_name}"
    client_input="$WORKSPACE/FHEClient/ciphertexts/${request_id}-input.bin"
    server_input="$WORKSPACE/FHEServer/ciphertexts/${request_id}-input.bin"
    server_result="$WORKSPACE/FHEServer/results/${request_id}-result.bin"
    client_result="$WORKSPACE/FHEClient/ciphertexts/${request_id}-result.bin"

    echo "[$index/$total] $image | true: $true_class" | tee -a "$LOG"
    (
        cd "$WORKSPACE/FHEClient/build"
        ./FHEClient encrypt "$KEYSET" "$image_path" "$client_input"
    ) >> "$LOG" 2>&1
    cp -- "$client_input" "$server_input"
    (
        cd "$WORKSPACE/FHEServer/build"
        ./FHEServer infer "$KEYSET" "$server_input" "$server_result" 1
    ) >> "$LOG" 2>&1
    cp -- "$server_result" "$client_result"

    if decrypt_output="$(
        cd "$WORKSPACE/FHEClient/build"
        ./FHEClient decrypt "$KEYSET" "$client_result" 2>&1
    )"; then
        printf '%s\n' "$decrypt_output" | tee -a "$LOG"
        handgun_logit="$(awk -F': ' '/^Handgun:/ {print $2}' <<< "$decrypt_output")"
        knife_logit="$(awk -F': ' '/^Knife:/ {print $2}' <<< "$decrypt_output")"
        prediction="$(awk -F': ' '/^Prediction:/ {print $2}' <<< "$decrypt_output")"
        if [[ -n "$handgun_logit" && -n "$knife_logit" && -n "$prediction" ]]; then
            is_correct=0
            [[ "$prediction" == "$true_class" ]] && is_correct=1
            correct_count=$((correct_count + is_correct))
            printf '"%s",%s,%s,%s,%s,%s,ok\n' \
                "$image" "$true_class" "$handgun_logit" "$knife_logit" "$prediction" "$is_correct" >> "$CSV"
        else
            decrypt_errors=$((decrypt_errors + 1))
            printf '"%s",%s,,,,,decrypt_error\n' "$image" "$true_class" >> "$CSV"
        fi
    else
        decrypt_errors=$((decrypt_errors + 1))
        printf '%s\n' "$decrypt_output" | tee -a "$LOG"
        printf '"%s",%s,,,,,decrypt_error\n' "$image" "$true_class" >> "$CSV"
    fi

    rm -f -- "$client_input" "$server_input" "$server_result" "$client_result"
    echo >> "$LOG"
done < "$INPUT_LIST"

echo "========== SUMMARY ==========" | tee -a "$LOG"
echo "Processed: $total" | tee -a "$LOG"
echo "Correct: $correct_count" | tee -a "$LOG"
echo "Decrypt errors: $decrypt_errors" | tee -a "$LOG"
echo "CSV: $CSV" | tee -a "$LOG"
echo "Log: $LOG" | tee -a "$LOG"
