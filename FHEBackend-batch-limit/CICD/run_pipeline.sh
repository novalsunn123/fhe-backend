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
BENCHMARK_JSON="$REPORT_DIR/benchmark.json"
LOG_DIR="$REPORT_DIR/logs"
RESOURCE_SAMPLE_INTERVAL="${CICD_RESOURCE_SAMPLE_INTERVAL:-1}"

mkdir -p "$LOG_DIR"
printf 'phase,status,exit_code,wall_seconds,user_seconds,system_seconds,average_cpu_percent,peak_cpu_percent,average_rss_kb,peak_rss_kb,resource_samples,peak_swap_kb,fs_inputs,fs_outputs,minor_faults,major_faults,voluntary_context_switches,involuntary_context_switches\n' > "$METRICS_CSV"

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

start_resource_sampler() {
    local timed_pid="$1"
    local sample_log="$2"
    local swap_log="$3"
    : > "$sample_log"
    : > "$swap_log"

    (
        local workload_pid=""
        local attempt pidstat_pid swap_kb
        for attempt in $(seq 1 50); do
            workload_pid="$(pgrep -P "$timed_pid" | head -1 || true)"
            if [[ -n "$workload_pid" ]]; then
                break
            fi
            if ! kill -0 "$timed_pid" 2>/dev/null; then
                exit 0
            fi
            sleep 0.1
        done
        if [[ -z "$workload_pid" ]]; then
            exit 0
        fi
        pidstat -h -u -r -p "$workload_pid" "$RESOURCE_SAMPLE_INTERVAL" > "$sample_log" 2>&1 &
        pidstat_pid=$!
        while kill -0 "$workload_pid" 2>/dev/null; do
            swap_kb="$(awk '/^VmSwap:/ {print $2; found=1} END {if (!found) print 0}' "/proc/$workload_pid/status" 2>/dev/null || printf '0')"
            printf '%s,%s\n' "$(date +%s)" "${swap_kb:-0}" >> "$swap_log"
            sleep "$RESOURCE_SAMPLE_INTERVAL"
        done
        wait "$pidstat_pid" 2>/dev/null || true
    ) &
    RESOURCE_SAMPLER_PID=$!
}

resource_sample_stats() {
    local sample_log="$1"
    awk '
        $3 ~ /^[0-9]+$/ && $8 ~ /^[0-9.]+$/ && $13 ~ /^[0-9]+$/ {
            cpu_sum += $8
            rss_sum += $13
            if ($8 > cpu_peak) cpu_peak = $8
            samples++
        }
        END {
            if (samples > 0) {
                printf "%.2f,%.0f,%d", cpu_peak, rss_sum / samples, samples
            } else {
                printf "0,0,0"
            }
        }
    ' "$sample_log"
}

peak_swap_kb() {
    local swap_log="$1"
    awk -F, 'BEGIN {peak=0} $2 ~ /^[0-9]+$/ && $2 > peak {peak=$2} END {print peak}' "$swap_log"
}

measure_phase() {
    local phase="$1"
    shift
    local phase_log="$LOG_DIR/${phase}.log"
    local time_log="$LOG_DIR/${phase}.time"
    local start_ns end_ns wall_seconds exit_code status
    local user_seconds system_seconds cpu_percent peak_rss fs_inputs fs_outputs
    local minor_faults major_faults voluntary_context involuntary_context
    local timed_pid log_tail_pid sampler_pid="" sample_stats peak_cpu average_rss resource_samples peak_swap
    local sample_log="$LOG_DIR/${phase}.samples"
    local swap_log="$LOG_DIR/${phase}.swap-samples.csv"

    echo "===== $phase ====="
    start_ns="$(date +%s%N)"
    set +e
    : > "$phase_log"
    /usr/bin/time -v -o "$time_log" -- "$@" > "$phase_log" 2>&1 &
    timed_pid=$!
    # Stream the file independently. A process substitution here would make
    # `tee` a child of the timed shell and could be mistaken for the FHE
    # workload by the resource sampler.
    tail --pid="$timed_pid" -n +1 -f "$phase_log" &
    log_tail_pid=$!
    if [[ "$phase" == "key_generation" || "$phase" == "inference" ]]; then
        start_resource_sampler "$timed_pid" "$sample_log" "$swap_log"
        sampler_pid="$RESOURCE_SAMPLER_PID"
    fi
    wait "$timed_pid"
    exit_code=$?
    end_ns="$(date +%s%N)"
    wait "$log_tail_pid" 2>/dev/null || true
    if [[ -n "$sampler_pid" ]]; then
        wait "$sampler_pid" 2>/dev/null || true
    fi
    set -e
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
    sample_stats="$(resource_sample_stats "$sample_log" 2>/dev/null || printf '0,0,0')"
    IFS=, read -r peak_cpu average_rss resource_samples <<< "$sample_stats"
    peak_swap="$(peak_swap_kb "$swap_log" 2>/dev/null || printf '0')"

    printf '%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$phase" "$status" "$exit_code" "$wall_seconds" \
        "${user_seconds:-0}" "${system_seconds:-0}" "${cpu_percent:-0%}" \
        "${peak_cpu:-0}" "${average_rss:-0}" "${peak_rss:-0}" \
        "${resource_samples:-0}" "${peak_swap:-0}" \
        "${fs_inputs:-0}" "${fs_outputs:-0}" \
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

phase_metric() {
    local phase="$1"
    local column="$2"
    awk -F, -v phase="$phase" -v column="$column" '$1 == phase {print $column; exit}' "$METRICS_CSV"
}

format_seconds() {
    local value="${1:-}"
    if [[ -z "$value" ]]; then
        printf 'unavailable'
        return
    fi
    awk -v seconds="$value" 'BEGIN {
        if (seconds >= 60) {
            printf "%dm %.3fs", int(seconds / 60), seconds - int(seconds / 60) * 60
        } else {
            printf "%.3fs", seconds
        }
    }'
}

format_cpu() {
    local value="${1:-}"
    value="${value%%%}"
    if [[ -z "$value" || "$value" == "0" ]]; then
        printf 'unavailable'
        return
    fi
    awk -v cpu="$value" 'BEGIN {printf "%.2f%% (~%.2f cores)", cpu, cpu / 100}'
}

format_kib() {
    local value="${1:-0}"
    if [[ -z "$value" || "$value" == "0" ]]; then
        printf 'unavailable'
        return
    fi
    awk -v kib="$value" 'BEGIN {
        if (kib >= 1048576) printf "%.2f GiB", kib / 1048576
        else printf "%.2f MiB", kib / 1024
    }'
}

format_swap_kib() {
    local value="${1:-}"
    if [[ -z "$value" ]]; then
        printf 'unavailable'
    elif [[ "$value" == "0" ]]; then
        printf '0 KiB'
    else
        format_kib "$value"
    fi
}

format_circuit_time() {
    local value="${1:-}"
    if [[ "$value" =~ ^([0-9]+)\.([0-9]+):([0-9]+)$ ]]; then
        printf '%sm %02d.%03ds' \
            "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
    elif [[ "$value" =~ ^([0-9]+):([0-9]+)s?$ ]]; then
        printf '%d.%03ds' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
    else
        printf 'unavailable'
    fi
}

circuit_seconds() {
    local value="${1:-}"
    if [[ "$value" =~ ^([0-9]+)\.([0-9]+):([0-9]+)$ ]]; then
        awk -v minutes="${BASH_REMATCH[1]}" -v seconds="${BASH_REMATCH[2]}" \
            -v milliseconds="${BASH_REMATCH[3]}" \
            'BEGIN {printf "%.3f", minutes * 60 + seconds + milliseconds / 1000}'
    elif [[ "$value" =~ ^([0-9]+):([0-9]+)s?$ ]]; then
        awk -v seconds="${BASH_REMATCH[1]}" -v milliseconds="${BASH_REMATCH[2]}" \
            'BEGIN {printf "%.3f", seconds + milliseconds / 1000}'
    else
        printf '0'
    fi
}

number_or_zero() {
    local value="${1:-0}"
    value="${value%%%}"
    if [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

sum_numbers() {
    awk -v first="$(number_or_zero "${1:-0}")" -v second="$(number_or_zero "${2:-0}")" \
        'BEGIN {printf "%.3f", first + second}'
}

render_summary() {
    local exit_code="$1"
    local pipeline_end_ns total_seconds commit_subject commit_sha commit_branch commit_actor
    local handgun_logit knife_logit prediction client_key_bytes server_key_bytes
    local input_bytes result_bytes circuit_time layer1_time layer2_time layer3_time
    local cpu_model logical_cpus memory_total_kb memory_available_kb swap_total_kb
    local disk_available_kb openfhe_version compiler_version cmake_version
    local keygen_wall keygen_avg_cpu keygen_peak_cpu keygen_avg_rss keygen_peak_rss
    local inference_wall inference_avg_cpu inference_peak_cpu inference_avg_rss inference_peak_rss
    local encryption_wall decryption_wall
    local keygen_user keygen_system keygen_cpu_time keygen_peak_swap
    local inference_user inference_system inference_cpu_time inference_peak_swap
    local test_image_sha weights_manifest_sha

    pipeline_end_ns="$(date +%s%N)"
    total_seconds="$(awk -v start="$PIPELINE_START_NS" -v end="$pipeline_end_ns" 'BEGIN {printf "%.3f", (end-start)/1000000000}')"
    commit_subject="$(git -C "$REPO_ROOT" log -1 --pretty=%s 2>/dev/null || printf 'unknown')"
    commit_subject="${commit_subject//|/\\|}"
    commit_sha="${FHE_BENCHMARK_COMMIT:-${GITHUB_SHA:-unknown}}"
    commit_branch="${FHE_BENCHMARK_BRANCH:-${GITHUB_REF_NAME:-unknown}}"
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
    circuit_time="$(sed $'s/\033\\[[0-9;]*m//g' "$LOG_DIR/inference.log" 2>/dev/null | sed -n 's/.*whole circuit took: ): *\([^[:space:]]*\).*/\1/p' | tail -1 || true)"
    keygen_wall="$(phase_metric key_generation 4 || true)"
    keygen_user="$(phase_metric key_generation 5 || true)"
    keygen_system="$(phase_metric key_generation 6 || true)"
    keygen_avg_cpu="$(phase_metric key_generation 7 || true)"
    keygen_peak_cpu="$(phase_metric key_generation 8 || true)"
    keygen_avg_rss="$(phase_metric key_generation 9 || true)"
    keygen_peak_rss="$(phase_metric key_generation 10 || true)"
    keygen_peak_swap="$(phase_metric key_generation 12 || true)"
    keygen_cpu_time="$(sum_numbers "$keygen_user" "$keygen_system")"
    inference_wall="$(phase_metric inference 4 || true)"
    inference_user="$(phase_metric inference 5 || true)"
    inference_system="$(phase_metric inference 6 || true)"
    inference_avg_cpu="$(phase_metric inference 7 || true)"
    inference_peak_cpu="$(phase_metric inference 8 || true)"
    inference_avg_rss="$(phase_metric inference 9 || true)"
    inference_peak_rss="$(phase_metric inference 10 || true)"
    inference_peak_swap="$(phase_metric inference 12 || true)"
    inference_cpu_time="$(sum_numbers "$inference_user" "$inference_system")"
    encryption_wall="$(phase_metric encryption 4 || true)"
    decryption_wall="$(phase_metric decryption 4 || true)"
    cpu_model="$(awk -F': ' '/^model name[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo)"
    logical_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')"
    memory_total_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    memory_available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
    disk_available_kb="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print $4}')"
    openfhe_version="$(sed -n 's/^set(PACKAGE_VERSION "\([^"]*\)").*/\1/p' /usr/local/lib/OpenFHE/OpenFHEConfigVersion.cmake 2>/dev/null | head -1 || true)"
    compiler_version="$(c++ -dumpfullversion -dumpversion 2>/dev/null || printf 'unknown')"
    cmake_version="$(cmake --version 2>/dev/null | awk 'NR==1 {print $3}')"
    if [[ -f "$REPO_ROOT/$TEST_IMAGE" ]]; then
        test_image_sha="$(sha256sum "$REPO_ROOT/$TEST_IMAGE" | awk '{print $1}')"
    else
        test_image_sha=""
    fi
    if [[ -d "$WEIGHTS_DIR" ]]; then
        weights_manifest_sha="$(cd "$WEIGHTS_DIR" && find . -type f -printf '%P:%s\n' | sort | sha256sum | awk '{print $1}')"
    else
        weights_manifest_sha=""
    fi

    {
        echo "# FHE CI benchmark"
        echo
        echo "## Key benchmark summary"
        echo
        echo "| Important metric | Result |"
        echo "|---|---:|"
        echo "| Status | $OVERALL_STATUS |"
        echo "| Prediction | ${prediction:-unavailable} |"
        echo "| Total pipeline | $(format_seconds "$total_seconds") |"
        echo "| Key generation time | $(format_seconds "$keygen_wall") |"
        echo "| Encryption time | $(format_seconds "$encryption_wall") |"
        echo "| Inference time | $(format_seconds "$inference_wall") |"
        echo "| FHE circuit time | $(format_circuit_time "$circuit_time") |"
        echo "| Layer 1 / Layer 2 / Layer 3 | $(format_circuit_time "$layer1_time") / $(format_circuit_time "$layer2_time") / $(format_circuit_time "$layer3_time") |"
        echo "| Decryption time | $(format_seconds "$decryption_wall") |"
        echo "| Key generation CPU average / peak | $(format_cpu "$keygen_avg_cpu") / $(format_cpu "$keygen_peak_cpu") |"
        echo "| Key generation RAM average / peak | $(format_kib "$keygen_avg_rss") / $(format_kib "$keygen_peak_rss") |"
        echo "| Inference CPU average / peak | $(format_cpu "$inference_avg_cpu") / $(format_cpu "$inference_peak_cpu") |"
        echo "| Inference RAM average / peak | $(format_kib "$inference_avg_rss") / $(format_kib "$inference_peak_rss") |"
        echo "| Inference peak swap | $(format_swap_kib "$inference_peak_swap") |"
        echo
        echo "CPU and average RAM samples are collected every ${RESOURCE_SAMPLE_INTERVAL}s for key generation and inference."
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
        echo "| Phase | Status | Wall (s) | Avg CPU | Peak CPU | Avg RSS (KiB) | Peak RSS (KiB) | Samples | Peak swap (KiB) | FS input | FS output |"
        echo "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
        tail -n +2 "$METRICS_CSV" | while IFS=, read -r phase status _ wall _ _ avg_cpu peak_cpu avg_rss peak_rss samples peak_swap fs_in fs_out _; do
            if [[ "$samples" == "0" ]]; then
                peak_cpu="unavailable"
                avg_rss="unavailable"
            else
                peak_cpu="${peak_cpu}%"
            fi
            echo "| $phase | $status | $wall | $avg_cpu | $peak_cpu | $avg_rss | $peak_rss | $samples | $peak_swap | $fs_in | $fs_out |"
        done
        echo
        echo "Detailed metrics and logs are attached as the GitHub Actions artifact for this run."
    } > "$SUMMARY_MD"

    jq -n \
        --arg status "$OVERALL_STATUS" \
        --arg commit "$commit_sha" \
        --arg branch "$commit_branch" \
        --arg commit_subject "$commit_subject" \
        --arg experiment "$EXPERIMENT" \
        --arg test_image "$TEST_IMAGE" \
        --arg test_image_sha256 "$test_image_sha" \
        --arg weights_manifest_sha256 "$weights_manifest_sha" \
        --arg cpu_model "$cpu_model" \
        --arg openfhe_version "$openfhe_version" \
        --arg prediction "$prediction" \
        --argjson logical_cpus "$(number_or_zero "$logical_cpus")" \
        --argjson total_ram_kb "$(number_or_zero "$memory_total_kb")" \
        --argjson pipeline_wall_seconds "$(number_or_zero "$total_seconds")" \
        --argjson handgun_logit "$(number_or_zero "$handgun_logit")" \
        --argjson knife_logit "$(number_or_zero "$knife_logit")" \
        --argjson keygen_wall "$(number_or_zero "$keygen_wall")" \
        --argjson keygen_cpu_time "$(number_or_zero "$keygen_cpu_time")" \
        --argjson keygen_avg_cpu "$(number_or_zero "$keygen_avg_cpu")" \
        --argjson keygen_peak_cpu "$(number_or_zero "$keygen_peak_cpu")" \
        --argjson keygen_avg_rss "$(number_or_zero "$keygen_avg_rss")" \
        --argjson keygen_peak_rss "$(number_or_zero "$keygen_peak_rss")" \
        --argjson keygen_peak_swap "$(number_or_zero "$keygen_peak_swap")" \
        --argjson encryption_wall "$(number_or_zero "$encryption_wall")" \
        --argjson inference_wall "$(number_or_zero "$inference_wall")" \
        --argjson inference_cpu_time "$(number_or_zero "$inference_cpu_time")" \
        --argjson inference_avg_cpu "$(number_or_zero "$inference_avg_cpu")" \
        --argjson inference_peak_cpu "$(number_or_zero "$inference_peak_cpu")" \
        --argjson inference_avg_rss "$(number_or_zero "$inference_avg_rss")" \
        --argjson inference_peak_rss "$(number_or_zero "$inference_peak_rss")" \
        --argjson inference_peak_swap "$(number_or_zero "$inference_peak_swap")" \
        --argjson decryption_wall "$(number_or_zero "$decryption_wall")" \
        --argjson circuit_wall "$(circuit_seconds "$circuit_time")" \
        --argjson layer1_wall "$(circuit_seconds "$layer1_time")" \
        --argjson layer2_wall "$(circuit_seconds "$layer2_time")" \
        --argjson layer3_wall "$(circuit_seconds "$layer3_time")" \
        '{
            schema_version: 1,
            status: $status,
            commit: $commit,
            branch: $branch,
            commit_subject: $commit_subject,
            environment: {
                experiment: $experiment,
                test_image: $test_image,
                test_image_sha256: $test_image_sha256,
                weights_manifest_sha256: $weights_manifest_sha256,
                cpu_model: $cpu_model,
                logical_cpus: $logical_cpus,
                total_ram_kb: $total_ram_kb,
                openfhe_version: $openfhe_version
            },
            result: {
                prediction: $prediction,
                handgun_logit: $handgun_logit,
                knife_logit: $knife_logit
            },
            metrics: {
                pipeline_wall_seconds: $pipeline_wall_seconds,
                key_generation: {
                    wall_seconds: $keygen_wall,
                    cpu_time_seconds: $keygen_cpu_time,
                    average_cpu_percent: $keygen_avg_cpu,
                    peak_cpu_percent: $keygen_peak_cpu,
                    average_rss_kb: $keygen_avg_rss,
                    peak_rss_kb: $keygen_peak_rss,
                    peak_swap_kb: $keygen_peak_swap
                },
                encryption: {wall_seconds: $encryption_wall},
                inference: {
                    wall_seconds: $inference_wall,
                    cpu_time_seconds: $inference_cpu_time,
                    average_cpu_percent: $inference_avg_cpu,
                    peak_cpu_percent: $inference_peak_cpu,
                    average_rss_kb: $inference_avg_rss,
                    peak_rss_kb: $inference_peak_rss,
                    peak_swap_kb: $inference_peak_swap
                },
                decryption: {wall_seconds: $decryption_wall},
                circuit: {
                    wall_seconds: $circuit_wall,
                    layer1_seconds: $layer1_wall,
                    layer2_seconds: $layer2_wall,
                    layer3_seconds: $layer3_wall
                }
            }
        }' > "$BENCHMARK_JSON"
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
if ! command -v pidstat >/dev/null || ! command -v pgrep >/dev/null \
        || ! command -v jq >/dev/null || ! command -v sha256sum >/dev/null; then
    echo "pidstat, pgrep, jq, and sha256sum are required for benchmarking." >&2
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
