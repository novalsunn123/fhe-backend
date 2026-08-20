#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   ./run_test.sh [handgun_images] [keyset] [train|val] [knife_images]
#   ./run_test.sh --full-val [keyset]
# Defaults: 3 Handgun, 3 Knife, keys_exp1, train split.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CLIENT_ROOT="$WORKSPACE/FHEClient"
SERVER_ROOT="$WORKSPACE/FHEServer"
CLIENT_BIN="$CLIENT_ROOT/build/FHEClient"
SERVER_BIN="$SERVER_ROOT/build/FHEServer"
RESULTS_DIR="$SCRIPT_DIR/results"
MODE="sample"
if [[ "${1:-}" == "--full-val" ]]; then
    MODE="full_val"
    HANDGUN_IMAGES=0
    KNIFE_IMAGES=0
    KEYSET="${2:-1}"
    SPLIT="${3:-val}"
else
    HANDGUN_IMAGES="${1:-3}"
    KEYSET="${2:-1}"
    SPLIT="${3:-train}"
    KNIFE_IMAGES="${4:-$HANDGUN_IMAGES}"
fi
DATASET="$WORKSPACE/LowMemoryFHEWeaponResNet20_v1/training/data/$SPLIT"
HISTORY="$SCRIPT_DIR/tested_images_${SPLIT}.txt"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
CSV="$RESULTS_DIR/run_${RUN_ID}.csv"
LOG_DIR="$RESULTS_DIR/run_${RUN_ID}_logs"

exec 9>"$SCRIPT_DIR/batch_test.lock"
if ! flock -n 9; then
    echo "Another FHE batch test is already running" >&2
    exit 1
fi
if pgrep -f '(^|/)FHEServer infer ' >/dev/null; then
    echo "Another FHEServer inference is already running" >&2
    exit 1
fi

if [[ "$MODE" == "sample" ]]; then
    if ! [[ "$HANDGUN_IMAGES" =~ ^[0-9]+$ && "$KNIFE_IMAGES" =~ ^[0-9]+$ ]] \
            || (( HANDGUN_IMAGES + KNIFE_IMAGES == 0 )); then
        echo "handgun_images and knife_images must be non-negative, with at least one image total" >&2
        exit 1
    fi
elif [[ "$SPLIT" != "val" ]]; then
    echo "--full-val only supports the val split" >&2
    exit 1
fi
if ! [[ "$KEYSET" =~ ^[1-4]$ ]]; then
    echo "keyset must be 1, 2, 3, or 4" >&2
    exit 1
fi
if [[ "$SPLIT" != "train" && "$SPLIT" != "val" ]]; then
    echo "split must be train or val" >&2
    exit 1
fi

for required in "$CLIENT_BIN" "$SERVER_BIN" "$DATASET/Handgun" "$DATASET/Knife"; do
    if [[ ! -e "$required" ]]; then
        echo "Missing required path: $required" >&2
        exit 1
    fi
done

if [[ ! -f "$CLIENT_ROOT/keys_exp${KEYSET}/secret-key.txt" ]]; then
    echo "Missing client secret key: $CLIENT_ROOT/keys_exp${KEYSET}/secret-key.txt" >&2
    exit 1
fi
if [[ -f "$SERVER_ROOT/keys_exp${KEYSET}/secret-key.txt" ]]; then
    echo "Security error: server contains secret-key.txt" >&2
    exit 1
fi
if [[ ! -f "$SERVER_ROOT/keys_exp${KEYSET}/crypto-context.txt" ]]; then
    echo "Missing server keyset: $SERVER_ROOT/keys_exp${KEYSET}" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR" "$LOG_DIR" \
    "$CLIENT_ROOT/ciphertexts" "$SERVER_ROOT/ciphertexts" "$SERVER_ROOT/results"
if [[ "$MODE" == "sample" ]]; then
    touch "$HISTORY"
fi
printf 'image,true_class,handgun_logit,knife_logit,prediction,correct,encrypt_seconds,inference_seconds,decrypt_seconds,total_seconds,status\n' > "$CSV"

elapsed_seconds() {
    awk -v start="$1" -v end="$2" 'BEGIN {printf "%.3f", (end - start) / 1000000000}'
}

declare -A TESTED=()
if [[ "$MODE" == "sample" ]]; then
    while IFS= read -r previous; do
        [[ -n "$previous" ]] && TESTED["$previous"]=1
    done < "$HISTORY"
fi

# RESERVED contains both previously attempted images and images already queued
# for this run. This prevents a replacement from duplicating a pending image.
declare -A RESERVED=()
for previous in "${!TESTED[@]}"; do
    RESERVED["$previous"]=1
done

select_images() {
    local class_name="$1"
    local requested="$2"
    local absolute relative
    local -a available=()

    if (( requested == 0 )); then
        return 0
    fi

    while IFS= read -r -d '' absolute; do
        relative="${absolute#"$DATASET/"}"
        if [[ -z "${RESERVED[$relative]+yes}" ]]; then
            available+=("$absolute")
        fi
    done < <(find "$DATASET/$class_name" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0)

    if (( ${#available[@]} < requested )); then
        echo "Not enough untested $class_name images: need $requested, have ${#available[@]}" >&2
        return 1
    fi

    printf '%s\n' "${available[@]}" | shuf -n "$requested"
}

declare -a TEST_IMAGES=()
declare -a TRUE_CLASSES=()
if [[ "$MODE" == "full_val" ]]; then
    for class_name in Handgun Knife; do
        mapfile -d '' chosen < <(find "$DATASET/$class_name" -maxdepth 1 -type f \
            \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 | sort -z)
        for image in "${chosen[@]}"; do
            TEST_IMAGES+=("$image")
            TRUE_CLASSES+=("$class_name")
        done
    done
    HANDGUN_IMAGES="$(find "$DATASET/Handgun" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | wc -l)"
    KNIFE_IMAGES="$(find "$DATASET/Knife" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | wc -l)"
else
    declare -A REQUESTED_IMAGES=( [Handgun]="$HANDGUN_IMAGES" [Knife]="$KNIFE_IMAGES" )
    for class_name in Handgun Knife; do
        requested="${REQUESTED_IMAGES[$class_name]}"
        mapfile -t chosen < <(select_images "$class_name" "$requested")
        if (( ${#chosen[@]} != requested )); then
            echo "Could not select $requested images for $class_name" >&2
            exit 1
        fi
        for image in "${chosen[@]}"; do
            relative="${image#"$DATASET/"}"
            TEST_IMAGES+=("$image")
            TRUE_CLASSES+=("$class_name")
            RESERVED["$relative"]=1
        done
    done
fi

TARGET_TOTAL=$((HANDGUN_IMAGES + KNIFE_IMAGES))
TOTAL=0
CORRECT=0
HANDGUN_TOTAL=0
HANDGUN_CORRECT=0
KNIFE_TOTAL=0
KNIFE_CORRECT=0
DECRYPT_ERRORS=0
CURRENT_FILES=()

cleanup_current_files() {
    if (( ${#CURRENT_FILES[@]} > 0 )); then
        rm -f -- "${CURRENT_FILES[@]}"
    fi
}
trap cleanup_current_files EXIT

echo "Run: $RUN_ID"
echo "Dataset split: $SPLIT"
if [[ "$MODE" == "full_val" ]]; then
    echo "Mode: full validation. Every image is attempted once; decrypt errors are logged, not replaced."
fi
echo "Target: $TARGET_TOTAL images (${HANDGUN_IMAGES} Handgun, ${KNIFE_IMAGES} Knife)."
echo "Each complete server inference currently takes about 12 minutes."

index=0
while (( index < ${#TEST_IMAGES[@]} )); do
    image="${TEST_IMAGES[$index]}"
    true_class="${TRUE_CLASSES[$index]}"
    relative="${image#"$DATASET/"}"
    base="$(basename -- "$image")"
    safe_base="${base//[^a-zA-Z0-9._-]/_}"
    request_id="${RUN_ID}_$((index + 1))_${true_class}_${safe_base}"

    client_input="$CLIENT_ROOT/ciphertexts/${request_id}-input.bin"
    server_input="$SERVER_ROOT/ciphertexts/${request_id}-input.bin"
    server_result="$SERVER_ROOT/results/${request_id}-result.bin"
    client_result="$CLIENT_ROOT/ciphertexts/${request_id}-result.bin"
    server_log="$LOG_DIR/${request_id}-server.log"
    client_log="$LOG_DIR/${request_id}-decrypt.log"
    CURRENT_FILES=("$client_input" "$server_input" "$server_result" "$client_result")

    echo
    echo "[Attempt $((index + 1)) | valid $TOTAL/$TARGET_TOTAL] $relative"

    total_start_ns="$(date +%s%N)"
    encrypt_start_ns="$total_start_ns"
    (
        cd "$CLIENT_ROOT/build"
        ./FHEClient encrypt "$KEYSET" "$image" "$client_input"
    )
    encrypt_end_ns="$(date +%s%N)"
    encrypt_seconds="$(elapsed_seconds "$encrypt_start_ns" "$encrypt_end_ns")"
    cp -- "$client_input" "$server_input"

    inference_start_ns="$(date +%s%N)"
    (
        cd "$SERVER_ROOT/build"
        ./FHEServer infer "$KEYSET" "$server_input" "$server_result" 1
    ) 2>&1 | tee "$server_log"
    inference_end_ns="$(date +%s%N)"
    inference_seconds="$(elapsed_seconds "$inference_start_ns" "$inference_end_ns")"

    cp -- "$server_result" "$client_result"
    decrypt_start_ns="$(date +%s%N)"
    decrypt_ok=1
    if decrypt_output="$(
        cd "$CLIENT_ROOT/build"
        ./FHEClient decrypt "$KEYSET" "$client_result" 2>&1
    )"; then
        status="ok"
    else
        decrypt_ok=0
        status="decrypt_error"
        DECRYPT_ERRORS=$((DECRYPT_ERRORS + 1))
    fi
    decrypt_end_ns="$(date +%s%N)"
    decrypt_seconds="$(elapsed_seconds "$decrypt_start_ns" "$decrypt_end_ns")"
    total_seconds="$(elapsed_seconds "$total_start_ns" "$decrypt_end_ns")"
    printf '%s\n' "$decrypt_output" | tee "$client_log"
    printf 'Timing: encrypt %ss | inference %ss | decrypt %ss | total %ss\n' \
        "$encrypt_seconds" "$inference_seconds" "$decrypt_seconds" "$total_seconds"

    if (( decrypt_ok )); then
        handgun_logit="$(awk -F': ' '/^Handgun:/ {print $2}' <<< "$decrypt_output")"
        knife_logit="$(awk -F': ' '/^Knife:/ {print $2}' <<< "$decrypt_output")"
        prediction="$(awk -F': ' '/^Prediction:/ {print $2}' <<< "$decrypt_output")"
        if [[ -z "$handgun_logit" || -z "$knife_logit" || -z "$prediction" ]]; then
            decrypt_ok=0
            status="decrypt_error"
            DECRYPT_ERRORS=$((DECRYPT_ERRORS + 1))
            printf '%s\n' "Could not parse client output for $relative" | tee -a "$client_log" >&2
        fi
    fi

    csv_image="${relative//\"/\"\"}"

    if (( ! decrypt_ok )); then
        handgun_logit=""
        knife_logit=""
        prediction="DECRYPT_ERROR"
        printf '"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$csv_image" "$true_class" "$handgun_logit" "$knife_logit" "$prediction" "" \
            "$encrypt_seconds" "$inference_seconds" "$decrypt_seconds" "$total_seconds" "$status" >> "$CSV"
        if [[ "$MODE" == "sample" ]]; then
            printf '%s\n' "$relative" >> "$HISTORY"
            TESTED["$relative"]=1
        fi

        rm -f -- "$client_input" "$server_input" "$server_result" "$client_result"
        CURRENT_FILES=()

        echo "[DECRYPT ERROR] $relative was logged and excluded from accuracy."

        if [[ "$MODE" == "full_val" ]]; then
            index=$((index + 1))
            continue
        fi

        mapfile -t replacement < <(select_images "$true_class" 1)
        if (( ${#replacement[@]} != 1 )); then
            echo "Cannot replace failed $true_class image; no untested image is available." >&2
            exit 1
        fi

        replacement_image="${replacement[0]}"
        replacement_relative="${replacement_image#"$DATASET/"}"
        TEST_IMAGES+=("$replacement_image")
        TRUE_CLASSES+=("$true_class")
        RESERVED["$replacement_relative"]=1
        echo "[REPLACEMENT] Queued $replacement_relative for $relative."

        index=$((index + 1))
        continue
    fi

    is_correct=0
    if [[ "$prediction" == "$true_class" ]]; then
        is_correct=1
        CORRECT=$((CORRECT + 1))
    fi
    TOTAL=$((TOTAL + 1))
    if [[ "$true_class" == "Handgun" ]]; then
        HANDGUN_TOTAL=$((HANDGUN_TOTAL + 1))
        HANDGUN_CORRECT=$((HANDGUN_CORRECT + is_correct))
    else
        KNIFE_TOTAL=$((KNIFE_TOTAL + 1))
        KNIFE_CORRECT=$((KNIFE_CORRECT + is_correct))
    fi

    printf '"%s",%s,%s,%s,%s,%d,%s,%s,%s,%s,%s\n' \
        "$csv_image" "$true_class" "$handgun_logit" "$knife_logit" "$prediction" "$is_correct" \
        "$encrypt_seconds" "$inference_seconds" "$decrypt_seconds" "$total_seconds" "$status" >> "$CSV"
    if [[ "$MODE" == "sample" ]]; then
        printf '%s\n' "$relative" >> "$HISTORY"
        TESTED["$relative"]=1
    fi

    rm -f -- "$client_input" "$server_input" "$server_result" "$client_result"
    CURRENT_FILES=()

    index=$((index + 1))
done

accuracy="$(awk -v correct="$CORRECT" -v total="$TOTAL" 'BEGIN {printf "%.2f", total ? 100 * correct / total : 0}')"
handgun_accuracy="$(awk -v correct="$HANDGUN_CORRECT" -v total="$HANDGUN_TOTAL" 'BEGIN {printf "%.2f", total ? 100 * correct / total : 0}')"
knife_accuracy="$(awk -v correct="$KNIFE_CORRECT" -v total="$KNIFE_TOTAL" 'BEGIN {printf "%.2f", total ? 100 * correct / total : 0}')"
attempted_total=$((TOTAL + DECRYPT_ERRORS))
pipeline_accuracy="$(awk -v correct="$CORRECT" -v total="$attempted_total" 'BEGIN {printf "%.2f", total ? 100 * correct / total : 0}')"
read -r inference_min inference_average inference_max < <(
    awk -F, 'NR > 1 {
        value=$8; sum+=value; count++;
        if (count == 1 || value < min) min=value;
        if (count == 1 || value > max) max=value
    } END {if (count) printf "%.3f %.3f %.3f\n", min, sum/count, max}' "$CSV"
)

echo
echo "========== SUMMARY =========="
echo "Handgun: $HANDGUN_CORRECT/$HANDGUN_TOTAL ($handgun_accuracy%)"
echo "Knife:   $KNIFE_CORRECT/$KNIFE_TOTAL ($knife_accuracy%)"
echo "Valid:   $CORRECT/$TOTAL ($accuracy%)"
if [[ "$MODE" == "full_val" ]]; then
    echo "Decrypt errors logged: $DECRYPT_ERRORS"
else
    echo "Decrypt errors replaced: $DECRYPT_ERRORS"
fi
echo "All attempts: $CORRECT/$attempted_total ($pipeline_accuracy%)"
echo "Inference wall time: min ${inference_min}s | avg ${inference_average}s | max ${inference_max}s"
echo "CSV:     $CSV"
if [[ "$MODE" == "sample" ]]; then
    echo "History: $HISTORY"
fi
