#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" || -z "${GITHUB_WORKSPACE:-}" ]]; then
    echo "This benchmark is CI-only and must run inside GitHub Actions." >&2
    exit 2
fi

REPO_ROOT="$(cd -- "$GITHUB_WORKSPACE" && pwd -P)"
if [[ "$REPO_ROOT" != "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" ]]; then
    echo "GITHUB_WORKSPACE does not match the checked-out repository." >&2
    exit 2
fi

EXPERIMENT="${FHE_EXPERIMENT:-1}"
TEST_IMAGE="${FHE_TEST_IMAGE:-FHEClient/inputs/2041_0.png}"
WEIGHTS_DIR="${CICD_WEIGHTS_DIR:?CICD_WEIGHTS_DIR is required}"
REPORT_DIR="${CICD_REPORT_DIR:?CICD_REPORT_DIR is required}"
BUILD_JOBS="${CICD_BUILD_JOBS:-2}"

CLIENT_ROOT="$REPO_ROOT/FHEClient"
SERVER_ROOT="$REPO_ROOT/FHEServer"
CLIENT_BIN="$CLIENT_ROOT/build/FHEClient"
SERVER_BIN="$SERVER_ROOT/build/FHEServer"
CLIENT_KEYS="$CLIENT_ROOT/keys_exp${EXPERIMENT}"
CLIENT_SERVER_KEYS="$CLIENT_ROOT/server_keys_exp${EXPERIMENT}"
SERVER_KEYS="$SERVER_ROOT/keys_exp${EXPERIMENT}"
CLIENT_CIPHERTEXTS="$CLIENT_ROOT/ciphertexts"
SERVER_CIPHERTEXTS="$SERVER_ROOT/ciphertexts"
SERVER_RESULTS="$SERVER_ROOT/results"
SERVER_CHECKPOINTS="$SERVER_ROOT/checkpoints"
INPUT_CIPHERTEXT="$CLIENT_CIPHERTEXTS/ci-encrypted-input.bin"
SERVER_INPUT="$SERVER_CIPHERTEXTS/ci-encrypted-input.bin"
SERVER_RESULT="$SERVER_RESULTS/ci-encrypted-result.bin"
CLIENT_RESULT="$CLIENT_CIPHERTEXTS/ci-encrypted-result.bin"
METRICS_CSV="$REPORT_DIR/metrics.csv"
SUMMARY_MD="$REPORT_DIR/summary.md"
LOG_DIR="$REPORT_DIR/logs"

mkdir -p "$LOG_DIR"
printf 'phase,status,exit_code,wall_seconds,user_seconds,system_seconds,cpu_percent,peak_rss_kb,fs_inputs,fs_outputs,minor_faults,major_faults,voluntary_context_switches,involuntary_context_switches\n' > "$METRICS_CSV"

PIPELINE_START_NS="$(date +%s%N)"
OVERALL_STATUS="failed"
FAILURE_PHASE=""
LAST_PHASE_EXIT=0

metric_value() {
    local file="$1"
    local label="$2"
    awk -F': ' -v label="$label" '
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
        }
        index(line, label ": ") == 1 {
            value=line
            sub(/^[^:]*: /, "", value)
            print value
            exit
        }
    ' "$file"
}

measure_phase() {
    local phase="$1"
    shift
    local phase_log="$LOG_DIR/${phase}.log"
    local time_log="$LOG_DIR/${phase}.time"
    local start_ns end_ns wall_seconds exit_code status
    local user_seconds system_seconds cpu_percent peak_rss fs_inputs fs_outputs
    local minor_faults major_faults voluntary_context involuntary_context

    echo "===== $phase ====="
    start_ns="$(date +%s%N)"
    set +e
    /usr/bin/time -v -o "$time_log" -- "$@" > >(tee "$phase_log") 2>&1
    exit_code=$?
    set -e
    end_ns="$(date +%s%N)"
    wall_seconds="$(awk -v start="$start_ns" -v end="$end_ns" 'BEGIN {printf "%.3f", (end-start)/1000000000}')"

    if (( exit_code == 0 )); then
        status="passed"
    else
        status="failed"
        FAILURE_PHASE="$phase"
    fi

    user_seconds="$(metric_value "$time_log" "User time (seconds)" || true)"
    system_seconds="$(metric_value "$time_log" "System time (seconds)" || true)"
    cpu_percent="$(metric_value "$time_log" "Percent of CPU this job got" || true)"
    peak_rss="$(metric_value "$time_log" "Maximum resident set size (kbytes)" || true)"
    fs_inputs="$(metric_value "$time_log" "File system inputs" || true)"
    fs_outputs="$(metric_value "$time_log" "File system outputs" || true)"
    minor_faults="$(metric_value "$time_log" "Minor (reclaiming a frame) page faults" || true)"
    major_faults="$(metric_value "$time_log" "Major (requiring I/O) page faults" || true)"
    voluntary_context="$(metric_value "$time_log" "Voluntary context switches" || true)"
    involuntary_context="$(metric_value "$time_log" "Involuntary context switches" || true)"

    printf '%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$phase" "$status" "$exit_code" "$wall_seconds" \
        "${user_seconds:-0}" "${system_seconds:-0}" "${cpu_percent:-0%}" \
        "${peak_rss:-0}" "${fs_inputs:-0}" "${fs_outputs:-0}" \
        "${minor_faults:-0}" "${major_faults:-0}" \
        "${voluntary_context:-0}" "${involuntary_context:-0}" >> "$METRICS_CSV"

    LAST_PHASE_EXIT=$exit_code
    return "$exit_code"
}

file_size_or_zero() {
    if [[ -f "$1" ]]; then
        stat -c '%s' "$1"
    else
        printf '0\n'
    fi
}

directory_size_or_zero() {
    if [[ -d "$1" ]]; then
        du -sb "$1" | awk '{print $1}'
    else
        printf '0\n'
    fi
}

render_summary() {
    local exit_code="$1"
    local pipeline_end_ns total_seconds commit_subject commit_sha commit_branch commit_actor
    local handgun_logit knife_logit prediction client_key_bytes server_key_bytes
    local input_bytes result_bytes circuit_time layer1_time layer2_time layer3_time
    local cpu_model logical_cpus memory_total_kb memory_available_kb swap_total_kb
    local disk_available_kb openfhe_version compiler_version cmake_version

    pipeline_end_ns="$(date +%s%N)"
    total_seconds="$(awk -v start="$PIPELINE_START_NS" -v end="$pipeline_end_ns" 'BEGIN {printf "%.3f", (end-start)/1000000000}')"
    commit_subject="$(git -C "$REPO_ROOT" log -1 --pretty=%s 2>/dev/null || printf 'unknown')"
    commit_subject="${commit_subject//|/\\|}"
    commit_sha="${GITHUB_SHA:-unknown}"
    commit_branch="${GITHUB_REF_NAME:-unknown}"
    commit_actor="${GITHUB_ACTOR:-unknown}"

    handgun_logit="$(awk -F': ' '/^Handgun:/ {print $2; exit}' "$LOG_DIR/decryption.log" 2>/dev/null || true)"
    knife_logit="$(awk -F': ' '/^Knife:/ {print $2; exit}' "$LOG_DIR/decryption.log" 2>/dev/null || true)"
    prediction="$(awk -F': ' '/^Prediction:/ {print $2; exit}' "$LOG_DIR/decryption.log" 2>/dev/null || true)"
    client_key_bytes="$(directory_size_or_zero "$CLIENT_KEYS")"
    server_key_bytes="$(directory_size_or_zero "$SERVER_KEYS")"
    input_bytes="$(file_size_or_zero "$INPUT_CIPHERTEXT")"
    result_bytes="$(file_size_or_zero "$SERVER_RESULT")"
    layer1_time="$(sed -n 's/.*(Layer 1 took:):[^0-9]*\([^[:space:]]*\).*/\1/p' "$LOG_DIR/inference.log" 2>/dev/null | tail -1 || true)"
    layer2_time="$(sed -n 's/.*(Layer 2 took:):[^0-9]*\([^[:space:]]*\).*/\1/p' "$LOG_DIR/inference.log" 2>/dev/null | tail -1 || true)"
    layer3_time="$(sed -n 's/.*(Layer 3 took:):[^0-9]*\([^[:space:]]*\).*/\1/p' "$LOG_DIR/inference.log" 2>/dev/null | tail -1 || true)"
    circuit_time="$(sed -n 's/.*whole circuit took: ):.*\x1b\[[0-9;]*m\([^[:space:]]*\).*/\1/p' "$LOG_DIR/inference.log" 2>/dev/null | tail -1 || true)"
    cpu_model="$(awk -F': ' '/^model name[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo)"
    logical_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')"
    memory_total_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    memory_available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
    disk_available_kb="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print $4}')"
    openfhe_version="$(sed -n 's/^set(PACKAGE_VERSION "\([^"]*\)").*/\1/p' /usr/local/lib/OpenFHE/OpenFHEConfigVersion.cmake 2>/dev/null | head -1 || true)"
    compiler_version="$(c++ -dumpfullversion -dumpversion 2>/dev/null || printf 'unknown')"
    cmake_version="$(cmake --version 2>/dev/null | awk 'NR==1 {print $3}')"

    {
        echo "# FHE CI benchmark"
        echo
        echo "| Field | Value |"
        echo "|---|---|"
        echo "| Status | $OVERALL_STATUS |"
        echo "| Failed phase | ${FAILURE_PHASE:-none} |"
        echo "| Commit | \`$commit_sha\` |"
        echo "| Commit note | $commit_subject |"
        echo "| Branch | $commit_branch |"
        echo "| Actor | $commit_actor |"
        echo "| Test image | $TEST_IMAGE |"
        echo "| Pipeline wall time | ${total_seconds}s |"
        echo "| Exit code | $exit_code |"
        echo
        echo "## Runner environment"
        echo
        echo "| Resource | Value |"
        echo "|---|---|"
        echo "| CPU | ${cpu_model:-unknown} |"
        echo "| Logical CPUs | $logical_cpus |"
        echo "| Total RAM | ${memory_total_kb:-0} KiB |"
        echo "| Available RAM after run | ${memory_available_kb:-0} KiB |"
        echo "| Total swap | ${swap_total_kb:-0} KiB |"
        echo "| Available disk after run | ${disk_available_kb:-0} KiB |"
        echo "| OpenFHE | ${openfhe_version:-unknown} |"
        echo "| C++ compiler | ${compiler_version:-unknown} |"
        echo "| CMake | ${cmake_version:-unknown} |"
        echo
        echo "## Classification result"
        echo
        echo "| Output | Value |"
        echo "|---|---|"
        echo "| Handgun logit | ${handgun_logit:-unavailable} |"
        echo "| Knife logit | ${knife_logit:-unavailable} |"
        echo "| Prediction | ${prediction:-unavailable} |"
        echo
        echo "## FHE artifacts"
        echo
        echo "| Artifact | Bytes |"
        echo "|---|---:|"
        echo "| Client keyset | $client_key_bytes |"
        echo "| Server evaluation keyset | $server_key_bytes |"
        echo "| Encrypted input | $input_bytes |"
        echo "| Encrypted result | $result_bytes |"
        echo
        echo "## Circuit detail"
        echo
        echo "| Section | Reported time |"
        echo "|---|---:|"
        echo "| Layer 1 | ${layer1_time:-unavailable} |"
        echo "| Layer 2 | ${layer2_time:-unavailable} |"
        echo "| Layer 3 | ${layer3_time:-unavailable} |"
        echo "| Whole circuit | ${circuit_time:-unavailable} |"
        echo
        echo "## Phase resources"
        echo
        echo "| Phase | Status | Wall (s) | CPU | Peak RSS (KiB) | FS input | FS output |"
        echo "|---|---|---:|---:|---:|---:|---:|"
        tail -n +2 "$METRICS_CSV" | while IFS=, read -r phase status _ wall _ _ cpu rss fs_in fs_out _; do
            echo "| $phase | $status | $wall | $cpu | $rss | $fs_in | $fs_out |"
        done
        echo
        echo "Detailed metrics and logs are attached as the GitHub Actions artifact for this run."
    } > "$SUMMARY_MD"
}

cleanup_generated() {
    # These paths are allowed only because REPO_ROOT was verified against
    # GITHUB_WORKSPACE above. Never run this cleanup against a live deployment.
    rm -rf -- \
        "$CLIENT_KEYS" \
        "$CLIENT_SERVER_KEYS" \
        "$SERVER_KEYS" \
        "$CLIENT_CIPHERTEXTS" \
        "$SERVER_CIPHERTEXTS" \
        "$SERVER_RESULTS" \
        "$SERVER_CHECKPOINTS"
    if [[ -L "$SERVER_ROOT/weights" ]]; then
        rm -f -- "$SERVER_ROOT/weights"
    fi
}

finish() {
    local exit_code=$?
    trap - EXIT
    set +e
    if (( exit_code == 0 )); then
        OVERALL_STATUS="passed"
    fi
    render_summary "$exit_code"
    cleanup_generated
    exit "$exit_code"
}
trap finish EXIT

if [[ "$EXPERIMENT" != "1" ]]; then
    echo "This CI benchmark currently supports experiment 1 only." >&2
    FAILURE_PHASE="preflight"
    exit 2
fi
if [[ ! -x /usr/bin/time ]]; then
    echo "GNU time is required at /usr/bin/time." >&2
    FAILURE_PHASE="preflight"
    exit 2
fi
if [[ ! -f "$REPO_ROOT/$TEST_IMAGE" ]]; then
    echo "Missing test image: $TEST_IMAGE" >&2
    FAILURE_PHASE="preflight"
    exit 2
fi
if [[ ! -d "$WEIGHTS_DIR" || ! -f "$WEIGHTS_DIR/fc.bin" ]]; then
    echo "Missing model weights: $WEIGHTS_DIR" >&2
    FAILURE_PHASE="preflight"
    exit 2
fi
if pgrep -f '(^|/)FHEServer infer ' >/dev/null; then
    echo "Another FHEServer inference is running; refusing to benchmark concurrently." >&2
    FAILURE_PHASE="preflight"
    exit 75
fi

available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
free_disk_kb="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print $4}')"
if (( available_kb < 18 * 1024 * 1024 )); then
    echo "At least 18 GiB available RAM is required; found ${available_kb} KiB." >&2
    FAILURE_PHASE="preflight"
    exit 75
fi
if (( free_disk_kb < 60 * 1024 * 1024 )); then
    echo "At least 60 GiB free disk is required; found ${free_disk_kb} KiB." >&2
    FAILURE_PHASE="preflight"
    exit 75
fi

cleanup_generated
mkdir -p "$CLIENT_CIPHERTEXTS" "$SERVER_CIPHERTEXTS" "$SERVER_RESULTS" "$SERVER_CHECKPOINTS"
ln -s "$WEIGHTS_DIR" "$SERVER_ROOT/weights"

if ! measure_phase build_client \
    cmake -S "$CLIENT_ROOT" -B "$CLIENT_ROOT/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase compile_client \
    cmake --build "$CLIENT_ROOT/build" --parallel "$BUILD_JOBS"; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase build_server \
    cmake -S "$SERVER_ROOT" -B "$SERVER_ROOT/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase compile_server \
    cmake --build "$SERVER_ROOT/build" --parallel "$BUILD_JOBS"; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase key_generation \
    bash -c 'cd "$1" && ./FHEClient generate_keys "$2"' \
        _ "$CLIENT_ROOT/build" "$EXPERIMENT"; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase key_transfer \
    bash -c 'mkdir -p "$2" && cp -al "$1"/. "$2"/' \
        _ "$CLIENT_SERVER_KEYS" "$SERVER_KEYS"; then
    exit "$LAST_PHASE_EXIT"
fi
if [[ -f "$SERVER_KEYS/secret-key.txt" ]]; then
    echo "Security failure: secret key reached the server key directory." >&2
    FAILURE_PHASE="key_transfer"
    exit 1
fi
if ! measure_phase encryption \
    bash -c 'cd "$1" && ./FHEClient encrypt "$2" "$3" "$4"' \
        _ "$CLIENT_ROOT/build" "$EXPERIMENT" "$REPO_ROOT/$TEST_IMAGE" "$INPUT_CIPHERTEXT"; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase ciphertext_transfer \
    cp -- "$INPUT_CIPHERTEXT" "$SERVER_INPUT"; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase inference \
    bash -c 'cd "$1" && ./FHEServer infer "$2" "$3" "$4" 2' \
        _ "$SERVER_ROOT/build" "$EXPERIMENT" "$SERVER_INPUT" "$SERVER_RESULT"; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase result_transfer \
    cp -- "$SERVER_RESULT" "$CLIENT_RESULT"; then
    exit "$LAST_PHASE_EXIT"
fi
if ! measure_phase decryption \
    bash -c 'cd "$1" && ./FHEClient decrypt "$2" "$3"' \
        _ "$CLIENT_ROOT/build" "$EXPERIMENT" "$CLIENT_RESULT"; then
    exit "$LAST_PHASE_EXIT"
fi

if ! grep -q '^Handgun:' "$LOG_DIR/decryption.log" \
        || ! grep -q '^Knife:' "$LOG_DIR/decryption.log" \
        || ! grep -Eq '^Prediction: (Handgun|Knife)$' "$LOG_DIR/decryption.log"; then
    echo "Decryption output is incomplete or invalid." >&2
    FAILURE_PHASE="decryption_validation"
    exit 1
fi

OVERALL_STATUS="passed"
