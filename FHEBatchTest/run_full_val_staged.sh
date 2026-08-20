#!/usr/bin/env bash
set -Eeuo pipefail

# Full validation for the staged, layer-major FHEServer infer_batch command.
# Usage:
#   ./run_full_val_staged.sh [batch_size] [keyset]
#   ./run_full_val_staged.sh --check [batch_size] [keyset]
#   ./run_full_val_staged.sh --resume <run-directory>

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
BACKEND="${FHE_BATCH_BACKEND_ROOT:-$WORKSPACE/FHEBackend-batch-limit}"
DATASET="$WORKSPACE/LowMemoryFHEWeaponResNet20_v1/training/data/val"
RESULTS_ROOT="$SCRIPT_DIR/results"

MODE="new"
RESUME_DIR=""
if [[ "${1:-}" == "--check" ]]; then
    MODE="check"
    shift
elif [[ "${1:-}" == "--resume" ]]; then
    MODE="resume"
    RESUME_DIR="${2:?Usage: $0 --resume <run-directory>}"
    shift 2
fi

if [[ "$MODE" == "resume" ]]; then
    RUN_DIR="$(cd -- "$RESUME_DIR" && pwd -P)"
    [[ -f "$RUN_DIR/run.conf" ]] || { echo "Error: Not a staged full-val run: $RUN_DIR" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$RUN_DIR/run.conf"
    [[ "$SAVED_BACKEND" == "$BACKEND" ]] || { echo "Error: Resume backend differs from saved backend" >&2; exit 1; }
    BATCH_SIZE="$SAVED_BATCH_SIZE"
    KEYSET="$SAVED_KEYSET"
else
    BATCH_SIZE="${1:-10}"
    KEYSET="${2:-1}"
fi
CLIENT_ROOT="$BACKEND/FHEClient"
SERVER_ROOT="$BACKEND/FHEServer"
CLIENT_BIN="$CLIENT_ROOT/build/FHEClient"
SERVER_BIN="$SERVER_ROOT/build/FHEServer"
CLIENT_KEYS="$CLIENT_ROOT/keys_exp${KEYSET}"
SERVER_KEYS="$SERVER_ROOT/keys_exp${KEYSET}"

die() { echo "Error: $*" >&2; exit 1; }
elapsed_seconds() {
    awk -v start="$1" -v end="$2" 'BEGIN {printf "%.3f", (end-start)/1000000000}'
}
require_file() { [[ -s "$1" ]] || die "Missing required file: $1"; }

[[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || die "batch_size must be an integer"
(( BATCH_SIZE >= 1 && BATCH_SIZE <= 20 )) || \
    die "batch_size must be between 1 and 20 for this 24 GB host"
[[ "$KEYSET" =~ ^[1-4]$ ]] || die "keyset must be 1, 2, 3, or 4"

[[ -x "$CLIENT_BIN" ]] || die "Missing FHEClient binary: $CLIENT_BIN"
[[ -x "$SERVER_BIN" ]] || die "Missing FHEServer binary: $SERVER_BIN"
require_file "$SERVER_ROOT/build/packed-weights.bin"
require_file "$SERVER_ROOT/weights/fc.bin"

for key in crypto-context.txt public-key.txt secret-key.txt mult-keys.txt \
        level_budget.txt relu_degree.txt rot_rotations-layer1.bin \
        rot_rotations-layer2-downsample.bin rot_rotations-layer2.bin \
        rot_rotations-layer3-downsample.bin rot_rotations-layer3.bin \
        rot_rotations-finallayer.bin; do
    require_file "$CLIENT_KEYS/$key"
done
for key in crypto-context.txt public-key.txt mult-keys.txt level_budget.txt \
        relu_degree.txt rot_rotations-layer1.bin \
        rot_rotations-layer2-downsample.bin rot_rotations-layer2.bin \
        rot_rotations-layer3-downsample.bin rot_rotations-layer3.bin \
        rot_rotations-finallayer.bin; do
    require_file "$SERVER_KEYS/$key"
done
[[ ! -e "$SERVER_KEYS/secret-key.txt" ]] || \
    die "Security error: server key directory contains secret-key.txt"
cmp -s "$CLIENT_KEYS/crypto-context.txt" "$SERVER_KEYS/crypto-context.txt" || \
    die "Client and server crypto contexts do not match"

for class_name in Handgun Knife; do
    [[ -d "$DATASET/$class_name" ]] || die "Missing validation class: $DATASET/$class_name"
done
handgun_count="$(find "$DATASET/Handgun" -maxdepth 1 -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | wc -l)"
knife_count="$(find "$DATASET/Knife" -maxdepth 1 -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | wc -l)"
total_images=$((handgun_count + knife_count))
(( total_images > 0 )) || die "Validation dataset is empty"

if pgrep -f '(^|/)FHEServer (infer|infer_batch) ' >/dev/null; then
    die "Another FHEServer inference is already running"
fi
available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
free_disk_kb="$(df -Pk "$SCRIPT_DIR" | awk 'NR==2 {print $4}')"
(( free_disk_kb >= 40*1024*1024 )) || die "At least 40 GiB free disk is required"

echo "Preflight OK"
echo "Backend:       $BACKEND"
echo "Dataset:       $total_images images ($handgun_count Handgun, $knife_count Knife)"
echo "Batch size:    $BATCH_SIZE"
echo "Batch count:   $(((total_images + BATCH_SIZE - 1) / BATCH_SIZE))"
echo "Keyset:        keys_exp${KEYSET}"
echo "Available RAM: $(awk -v kb="$available_kb" 'BEGIN {printf "%.2f GiB", kb/1048576}')"
echo "Free disk:     $(awk -v kb="$free_disk_kb" 'BEGIN {printf "%.2f GiB", kb/1048576}')"
if (( available_kb < 18*1024*1024 )); then
    echo "Memory safety check failed: at least 18 GiB available RAM is recommended." >&2
    echo "Stop other memory-heavy jobs, or set FHE_ALLOW_LOW_MEMORY=1 to accept swap/OOM risk." >&2
    [[ "${FHE_ALLOW_LOW_MEMORY:-0}" == "1" ]] || exit 75
fi
[[ "$MODE" != "check" ]] || exit 0

exec 9>"$SCRIPT_DIR/batch_test.lock"
flock -n 9 || die "Another FHEBatchTest process holds batch_test.lock"

if [[ "$MODE" != "resume" ]]; then
    RUN_ID="$(date +%Y%m%d_%H%M%S)"
    RUN_DIR="$RESULTS_ROOT/staged_full_val_${RUN_ID}"
    mkdir -p "$RUN_DIR"
    printf 'SAVED_BACKEND=%q\nSAVED_BATCH_SIZE=%q\nSAVED_KEYSET=%q\n' \
        "$BACKEND" "$BATCH_SIZE" "$KEYSET" > "$RUN_DIR/run.conf"
fi

IMAGES_TSV="$RUN_DIR/images.tsv"
RESULTS_CSV="$RUN_DIR/results.csv"
PROGRESS="$RUN_DIR/progress.txt"
SUMMARY="$RUN_DIR/summary.txt"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/runtime" "$RUN_DIR/decrypt_errors"

if [[ ! -s "$IMAGES_TSV" ]]; then
    : > "$IMAGES_TSV"
    for class_name in Handgun Knife; do
        while IFS= read -r -d '' image; do
            relative="${image#"$DATASET/"}"
            [[ "$relative" != *$'\t'* && "$relative" != *','* ]] || \
                die "Unsupported tab/comma in image path: $relative"
            printf '%s\t%s\t%s\n' "$relative" "$class_name" "$image" >> "$IMAGES_TSV"
        done < <(find "$DATASET/$class_name" -maxdepth 1 -type f \
            \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) \
            -print0 | sort -z)
    done
fi

if [[ ! -s "$RESULTS_CSV" ]]; then
    printf 'image,true_class,handgun_logit,knife_logit,prediction,correct,batch_id,encrypt_seconds,batch_inference_seconds,amortized_inference_seconds,decrypt_seconds,circuit_seconds,layer1_seconds,layer2_seconds,layer3_seconds,final_seconds,status\n' > "$RESULTS_CSV"
fi
echo "$RUN_DIR" > "$SCRIPT_DIR/latest_staged_full_val_run.txt"
echo "Results directory: $RUN_DIR"
echo "Resume command: $0 --resume '$RUN_DIR'"

declare -A COMPLETED=()
load_completed() {
    COMPLETED=()
    while IFS= read -r image; do
        [[ -n "$image" ]] && COMPLETED["$image"]=1
    done < <(awk -F, 'NR>1 {v=$1; sub(/^"/,"",v); sub(/"$/,"",v); print v}' "$RESULTS_CSV")
}
write_progress() {
    local count
    count="$(awk 'END {if (NR > 0) print NR-1; else print 0}' "$RESULTS_CSV")"
    printf 'Completed: %s/%s\nUpdated: %s\nResults: %s\n' \
        "$count" "$total_images" "$(date --iso-8601=seconds)" "$RESULTS_CSV" > "$PROGRESS"
}

record_batch_results() {
    local batch_id="$1" metadata="$2" metrics="$3" batch_inference_seconds="$4"
    local strict="${5:-1}" batch_count amortized_inference_seconds
    local local_index relative class_name encrypted_input encrypted_result encrypt_seconds
    local suffix decrypt_log decrypt_start_ns decrypt_output decrypt_exit decrypt_end_ns decrypt_seconds
    local metric_line circuit_seconds layer1_seconds layer2_seconds layer3_seconds final_seconds
    local handgun_logit knife_logit prediction correct status error_dir

    batch_count="$(awk 'END {print NR}' "$metadata")"
    (( batch_count > 0 )) || return 0
    amortized_inference_seconds="$(awk -v total="$batch_inference_seconds" \
        -v count="$batch_count" 'BEGIN {printf "%.3f", total/count}')"
    load_completed

    while IFS=$'\t' read -r local_index relative class_name encrypted_input encrypted_result encrypt_seconds; do
        [[ -z "${COMPLETED[$relative]+yes}" ]] || continue
        if [[ ! -s "$encrypted_result" ]]; then
            (( strict == 0 )) && continue
            die "Missing encrypted result for $relative: $encrypted_result"
        fi

        suffix="$(printf '%02d' "$local_index")"
        decrypt_log="$RUN_DIR/logs/batch-$batch_id-decrypt-$suffix.log"
        decrypt_start_ns="$(date +%s%N)"; set +e
        decrypt_output="$(cd "$CLIENT_ROOT/build"; ./FHEClient decrypt "$KEYSET" "$encrypted_result" 2>&1)"
        decrypt_exit=$?; set -e
        decrypt_end_ns="$(date +%s%N)"; decrypt_seconds="$(elapsed_seconds "$decrypt_start_ns" "$decrypt_end_ns")"
        printf '%s\n' "$decrypt_output" > "$decrypt_log"

        metric_line="$(awk -F'\t' -v wanted="$local_index" 'NR>1 && $1==wanted {print; exit}' "$metrics")"
        [[ -n "$metric_line" ]] || die "Missing server metrics for batch image $local_index"
        IFS=$'\t' read -r _ _ _ circuit_seconds layer1_seconds layer2_seconds layer3_seconds final_seconds <<< "$metric_line"

        handgun_logit=""; knife_logit=""; prediction="DECRYPT_ERROR"; correct=""; status="decrypt_error"
        if (( decrypt_exit == 0 )); then
            handgun_logit="$(awk -F': ' '/^Handgun:/ {print $2; exit}' <<< "$decrypt_output")"
            knife_logit="$(awk -F': ' '/^Knife:/ {print $2; exit}' <<< "$decrypt_output")"
            prediction="$(awk -F': ' '/^Prediction:/ {print $2; exit}' <<< "$decrypt_output")"
            if [[ -n "$handgun_logit" && -n "$knife_logit" && ( "$prediction" == Handgun || "$prediction" == Knife ) ]]; then
                correct=0; [[ "$prediction" != "$class_name" ]] || correct=1; status="ok"
            else
                prediction="DECRYPT_ERROR"
            fi
        fi

        if [[ "$status" == decrypt_error ]]; then
            error_dir="$RUN_DIR/decrypt_errors/${relative%/*}"; mkdir -p "$error_dir"
            [[ ! -s "$encrypted_input" ]] || cp -- "$encrypted_input" "$error_dir/$(basename -- "$relative")-input.bin"
            cp -- "$encrypted_result" "$error_dir/$(basename -- "$relative")-result.bin"
            echo "[DECRYPT ERROR] $relative; encrypted artifacts preserved."
        else
            echo "[RESULT] $relative -> $prediction (expected $class_name)"
        fi

        printf '"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$relative" "$class_name" "$handgun_logit" "$knife_logit" "$prediction" "$correct" \
            "$batch_id" "$encrypt_seconds" "$batch_inference_seconds" "$amortized_inference_seconds" \
            "$decrypt_seconds" "$circuit_seconds" "$layer1_seconds" "$layer2_seconds" \
            "$layer3_seconds" "$final_seconds" "$status" >> "$RESULTS_CSV"
        rm -f -- "$encrypted_input" "$encrypted_result"
        COMPLETED["$relative"]=1
        write_progress
    done < "$metadata"
}

# Recover encrypted outputs from a batch whose inference completed before the
# wrapper stopped. This avoids repeating an hour-long staged inference merely
# because reporting or decryption was interrupted.
if [[ "$MODE" == "resume" ]]; then
    shopt -s nullglob
    for old_metadata in "$RUN_DIR"/runtime/batch-*/metadata.tsv; do
        old_batch_dir="$(dirname -- "$old_metadata")"
        old_batch_id="${old_batch_dir##*/batch-}"
        old_metrics="$old_batch_dir/server-metrics.tsv"
        [[ -s "$old_metrics" ]] || continue
        old_batch_seconds="$(awk -F, -v id="$old_batch_id" 'NR>1 && $7==id {print $9; exit}' "$RESULTS_CSV")"
        if [[ -z "$old_batch_seconds" ]]; then
            old_server_log="$RUN_DIR/logs/batch-$old_batch_id-server.log"
            old_batch_seconds="$(awk '/^Staged batch wall time:/ {value=$5; sub(/s$/, "", value); print value; exit}' "$old_server_log" 2>/dev/null || true)"
        fi
        [[ "$old_batch_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        echo "Recovering completed encrypted outputs from batch $old_batch_id"
        record_batch_results "$old_batch_id" "$old_metadata" "$old_metrics" "$old_batch_seconds" 0
        rmdir "$old_batch_dir/checkpoints" 2>/dev/null || true
    done
    shopt -u nullglob
fi

batch_sequence=0
while :; do
    load_completed
    PENDING_REL=(); PENDING_CLASS=(); PENDING_PATH=()
    while IFS=$'\t' read -r relative class_name image; do
        if [[ -z "${COMPLETED[$relative]+yes}" ]]; then
            PENDING_REL+=("$relative"); PENDING_CLASS+=("$class_name"); PENDING_PATH+=("$image")
            (( ${#PENDING_REL[@]} >= BATCH_SIZE )) && break
        fi
    done < "$IMAGES_TSV"
    (( ${#PENDING_REL[@]} > 0 )) || break

    batch_sequence=$((batch_sequence + 1))
    batch_id="$(date +%Y%m%d_%H%M%S)-$(printf '%03d' "$batch_sequence")"
    batch_dir="$RUN_DIR/runtime/batch-$batch_id"
    checkpoint_dir="$batch_dir/checkpoints"
    manifest="$batch_dir/server-jobs.tsv"
    metadata="$batch_dir/metadata.tsv"
    metrics="$batch_dir/server-metrics.tsv"
    server_log="$RUN_DIR/logs/batch-$batch_id-server.log"
    mkdir -p "$batch_dir/ciphertexts" "$batch_dir/results" "$checkpoint_dir"
    : > "$manifest"; : > "$metadata"

    echo; echo "===== Batch $batch_id: ${#PENDING_REL[@]} images ====="
    for ((i=0; i<${#PENDING_REL[@]}; i++)); do
        local_index=$((i + 1)); suffix="$(printf '%02d' "$local_index")"
        relative="${PENDING_REL[$i]}"; class_name="${PENDING_CLASS[$i]}"; image="${PENDING_PATH[$i]}"
        encrypted_input="$batch_dir/ciphertexts/${suffix}-input.bin"
        encrypted_result="$batch_dir/results/${suffix}-result.bin"
        encrypt_log="$RUN_DIR/logs/batch-$batch_id-encrypt-$suffix.log"
        start_ns="$(date +%s%N)"
        (cd "$CLIENT_ROOT/build"; ./FHEClient encrypt "$KEYSET" "$image" "$encrypted_input") \
            > "$encrypt_log" 2>&1
        end_ns="$(date +%s%N)"; encrypt_seconds="$(elapsed_seconds "$start_ns" "$end_ns")"
        echo "[$local_index/${#PENDING_REL[@]}] encrypted $relative (${encrypt_seconds}s)"
        printf '%s\t%s\n' "$encrypted_input" "$encrypted_result" >> "$manifest"
        printf '%d\t%s\t%s\t%s\t%s\t%s\n' "$local_index" "$relative" "$class_name" \
            "$encrypted_input" "$encrypted_result" "$encrypt_seconds" >> "$metadata"
    done

    inference_start_ns="$(date +%s%N)"
    (cd "$SERVER_ROOT/build"; FHE_BINARY_WEIGHTS=1 ./FHEServer infer_batch "$KEYSET" \
        "$manifest" "$checkpoint_dir" "$metrics" 1) 2>&1 | tee "$server_log"
    inference_end_ns="$(date +%s%N)"
    batch_inference_seconds="$(elapsed_seconds "$inference_start_ns" "$inference_end_ns")"
    record_batch_results "$batch_id" "$metadata" "$metrics" "$batch_inference_seconds" 1
    rmdir "$checkpoint_dir" 2>/dev/null || true
done

attempted="$(awk 'END {if (NR > 0) print NR-1; else print 0}' "$RESULTS_CSV")"
valid="$(awk -F, 'NR>1 && $17=="ok" {n++} END {print n+0}' "$RESULTS_CSV")"
correct="$(awk -F, 'NR>1 && $17=="ok" && $6==1 {n++} END {print n+0}' "$RESULTS_CSV")"
decrypt_errors="$(awk -F, 'NR>1 && $17=="decrypt_error" {n++} END {print n+0}' "$RESULTS_CSV")"
read -r handgun_correct handgun_valid <<< "$(awk -F, 'NR>1 && $2=="Handgun" && $17=="ok" {n++; c+=$6} END {print c+0,n+0}' "$RESULTS_CSV")"
read -r knife_correct knife_valid <<< "$(awk -F, 'NR>1 && $2=="Knife" && $17=="ok" {n++; c+=$6} END {print c+0,n+0}' "$RESULTS_CSV")"
accuracy="$(awk -v c="$correct" -v n="$valid" 'BEGIN {printf "%.2f", n?100*c/n:0}')"
handgun_accuracy="$(awk -v c="$handgun_correct" -v n="$handgun_valid" 'BEGIN {printf "%.2f", n?100*c/n:0}')"
knife_accuracy="$(awk -v c="$knife_correct" -v n="$knife_valid" 'BEGIN {printf "%.2f", n?100*c/n:0}')"
average_amortized="$(awk -F, 'NR>1 {sum+=$10; n++} END {printf "%.3f", n?sum/n:0}' "$RESULTS_CSV")"
{
    echo "========== STAGED FULL-VAL SUMMARY =========="
    echo "Attempted:       $attempted/$total_images"
    echo "Valid decrypted: $valid"
    echo "Decrypt errors:  $decrypt_errors"
    echo "Accuracy:        $correct/$valid ($accuracy%)"
    echo "Handgun:         $handgun_correct/$handgun_valid ($handgun_accuracy%)"
    echo "Knife:           $knife_correct/$knife_valid ($knife_accuracy%)"
    echo "Avg amortized inference/image: ${average_amortized}s"
    echo "Results CSV:     $RESULTS_CSV"
} | tee "$SUMMARY"
write_progress
