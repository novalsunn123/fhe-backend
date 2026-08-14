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
MANIFEST_RELATIVE="${FHE_BATCH_MANIFEST:-CICD/benchmark10-images.tsv}"
MANIFEST="$REPO_ROOT/$MANIFEST_RELATIVE"
EXPECTED_COUNT="${FHE_BATCH_EXPECTED_COUNT:-10}"
WEIGHTS_DIR="${CICD_WEIGHTS_DIR:?CICD_WEIGHTS_DIR is required}"
REPORT_DIR="${CICD_REPORT_DIR:?CICD_REPORT_DIR is required}"
BUILD_JOBS="${CICD_BUILD_JOBS:-2}"
RESOURCE_SAMPLE_INTERVAL="${CICD_RESOURCE_SAMPLE_INTERVAL:-1}"

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
SERVER_BATCH_MANIFEST="$REPORT_DIR/batch10-server-jobs.tsv"
SERVER_BATCH_METRICS="$REPORT_DIR/batch10-server-metrics.tsv"
BATCH_JOB_METADATA="$REPORT_DIR/batch10-job-metadata.tsv"
LOG_DIR="$REPORT_DIR/logs"
PROFILE_DIR="$REPORT_DIR/profiles"
PHASE_METRICS="$REPORT_DIR/batch10-phase-metrics.csv"
RESULTS_CSV="$REPORT_DIR/batch10-results.csv"
SUMMARY_MD="$REPORT_DIR/batch10-summary.md"
BENCHMARK_JSON="$REPORT_DIR/batch10-benchmark.json"

mkdir -p "$LOG_DIR" "$PROFILE_DIR"
: > "$SERVER_BATCH_MANIFEST"
: > "$BATCH_JOB_METADATA"
printf 'phase,status,exit_code,wall_seconds,user_seconds,system_seconds,gnu_average_cpu_percent,sampled_average_cpu_percent,sampled_peak_cpu_percent,average_rss_kb,sampled_peak_rss_kb,time_peak_rss_kb,resource_samples,peak_swap_kb,fs_inputs,fs_outputs\n' > "$PHASE_METRICS"
printf 'index,image,true_class,handgun_logit,knife_logit,prediction,correct,encrypt_seconds,inference_seconds,decrypt_seconds,total_seconds,circuit_seconds,layer1_seconds,layer2_seconds,layer3_seconds,inference_average_cpu_percent,inference_peak_cpu_percent,inference_average_rss_kb,inference_peak_rss_kb,inference_peak_swap_kb,status\n' > "$RESULTS_CSV"

PIPELINE_START_NS="$(date +%s%N)"
OVERALL_STATUS="failed"
FAILURE_PHASE=""
LAST_PHASE_EXIT=0
RESOURCE_SAMPLER_PID=""

metric_value() {
    local file="$1" label="$2"
    awk -F': ' -v label="$label" '
        { line=$0; sub(/^[[:space:]]+/, "", line) }
        index(line, label ": ") == 1 {
            value=line; sub(/^[^:]*: /, "", value); print value; exit
        }
    ' "$file"
}

start_resource_sampler() {
    local timed_pid="$1" sample_log="$2"
    : > "$sample_log"
    printf 'timestamp_ns,cpu_percent,rss_kb,swap_kb\n' > "$sample_log"
    (
        local workload_pid="" attempt stat_line stat_rest now_ns ticks rss_kb swap_kb
        local previous_ns="" previous_ticks="" cpu_percent="0" clock_ticks
        clock_ticks="$(getconf CLK_TCK)"
        for attempt in $(seq 1 100); do
            workload_pid="$(pgrep -P "$timed_pid" | head -1 || true)"
            [[ -n "$workload_pid" ]] && break
            kill -0 "$timed_pid" 2>/dev/null || exit 0
            sleep 0.05
        done
        [[ -n "$workload_pid" ]] || exit 0

        while kill -0 "$workload_pid" 2>/dev/null; do
            [[ -r "/proc/$workload_pid/stat" ]] || break
            stat_line="$(<"/proc/$workload_pid/stat")" || break
            stat_rest="${stat_line#*) }"
            read -r -a stat_fields <<< "$stat_rest"
            ticks=$(( ${stat_fields[11]:-0} + ${stat_fields[12]:-0} ))
            now_ns="$(date +%s%N)"
            rss_kb="$(awk '/^VmRSS:/ {print $2; found=1} END {if (!found) print 0}' "/proc/$workload_pid/status" 2>/dev/null || printf '0')"
            swap_kb="$(awk '/^VmSwap:/ {print $2; found=1} END {if (!found) print 0}' "/proc/$workload_pid/status" 2>/dev/null || printf '0')"
            if [[ -n "$previous_ns" && "$now_ns" -gt "$previous_ns" ]]; then
                cpu_percent="$(awk -v current="$ticks" -v previous="$previous_ticks" \
                    -v elapsed="$((now_ns - previous_ns))" -v hz="$clock_ticks" \
                    'BEGIN {printf "%.2f", 100000000000 * (current-previous) / (hz*elapsed)}')"
            fi
            printf '%s,%s,%s,%s\n' "$now_ns" "$cpu_percent" "${rss_kb:-0}" "${swap_kb:-0}" >> "$sample_log"
            previous_ns="$now_ns"
            previous_ticks="$ticks"
            sleep "$RESOURCE_SAMPLE_INTERVAL"
        done
    ) &
    RESOURCE_SAMPLER_PID=$!
}

resource_sample_stats() {
    local sample_log="$1"
    awk -F, 'NR > 1 && $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
        cpu_sum += $2; rss_sum += $3; samples++
        if ($2 > cpu_peak) cpu_peak=$2
        if ($3 > rss_peak) rss_peak=$3
        if ($4 > swap_peak) swap_peak=$4
    } END {
        if (samples) printf "%.2f,%.2f,%.0f,%.0f,%d,%.0f", cpu_sum/samples, cpu_peak, rss_sum/samples, rss_peak, samples, swap_peak
        else printf "0,0,0,0,0,0"
    }' "$sample_log"
}

measure_phase() {
    local phase="$1"
    shift
    local phase_log="$LOG_DIR/${phase}.log" time_log="$LOG_DIR/${phase}.time"
    local sample_log="$LOG_DIR/${phase}.samples.csv"
    local start_ns end_ns wall_seconds exit_code status timed_pid tail_pid sampler_pid=""
    local user_seconds system_seconds gnu_cpu time_peak_rss fs_inputs fs_outputs
    local stats sampled_avg_cpu sampled_peak_cpu sampled_avg_rss sampled_peak_rss samples peak_swap

    echo "===== $phase ====="
    : > "$phase_log"
    start_ns="$(date +%s%N)"
    set +e
    /usr/bin/time -v -o "$time_log" -- "$@" > "$phase_log" 2>&1 &
    timed_pid=$!
    tail --pid="$timed_pid" -n +1 -f "$phase_log" &
    tail_pid=$!
    if [[ "$phase" == "key_generation" || "$phase" == inference_* ]]; then
        start_resource_sampler "$timed_pid" "$sample_log"
        sampler_pid="$RESOURCE_SAMPLER_PID"
    else
        printf 'timestamp_ns,cpu_percent,rss_kb,swap_kb\n' > "$sample_log"
    fi
    wait "$timed_pid"
    exit_code=$?
    end_ns="$(date +%s%N)"
    wait "$tail_pid" 2>/dev/null || true
    [[ -z "$sampler_pid" ]] || wait "$sampler_pid" 2>/dev/null || true
    set -e

    wall_seconds="$(awk -v start="$start_ns" -v end="$end_ns" 'BEGIN {printf "%.3f", (end-start)/1000000000}')"
    if (( exit_code == 0 )); then status="passed"; else status="failed"; FAILURE_PHASE="$phase"; fi
    user_seconds="$(metric_value "$time_log" 'User time (seconds)' || true)"
    system_seconds="$(metric_value "$time_log" 'System time (seconds)' || true)"
    gnu_cpu="$(metric_value "$time_log" 'Percent of CPU this job got' || true)"
    gnu_cpu="${gnu_cpu%%%}"
    time_peak_rss="$(metric_value "$time_log" 'Maximum resident set size (kbytes)' || true)"
    fs_inputs="$(metric_value "$time_log" 'File system inputs' || true)"
    fs_outputs="$(metric_value "$time_log" 'File system outputs' || true)"
    stats="$(resource_sample_stats "$sample_log")"
    IFS=, read -r sampled_avg_cpu sampled_peak_cpu sampled_avg_rss sampled_peak_rss samples peak_swap <<< "$stats"

    printf '%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$phase" "$status" "$exit_code" "$wall_seconds" \
        "${user_seconds:-0}" "${system_seconds:-0}" "${gnu_cpu:-0}" \
        "$sampled_avg_cpu" "$sampled_peak_cpu" "$sampled_avg_rss" \
        "$sampled_peak_rss" "${time_peak_rss:-0}" "$samples" "$peak_swap" \
        "${fs_inputs:-0}" "${fs_outputs:-0}" >> "$PHASE_METRICS"
    LAST_PHASE_EXIT=$exit_code
    return "$exit_code"
}

phase_metric() {
    local phase="$1" column="$2"
    awk -F, -v phase="$phase" -v column="$column" '$1 == phase {print $column; exit}' "$PHASE_METRICS"
}

number_or_zero() {
    local value="${1:-0}"
    value="${value%%%}"
    [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$value" || printf '0'
}

max_number() {
    awk -v first="$(number_or_zero "${1:-0}")" -v second="$(number_or_zero "${2:-0}")" \
        'BEGIN {print (first > second ? first : second)}'
}

circuit_seconds() {
    local value="${1:-}"
    if [[ "$value" =~ ^([0-9]+)\.([0-9]+):([0-9]+)$ ]]; then
        awk -v minutes="${BASH_REMATCH[1]}" -v seconds="${BASH_REMATCH[2]}" -v ms="${BASH_REMATCH[3]}" \
            'BEGIN {printf "%.3f", minutes*60+seconds+ms/1000}'
    elif [[ "$value" =~ ^([0-9]+):([0-9]+)s?$ ]]; then
        awk -v seconds="${BASH_REMATCH[1]}" -v ms="${BASH_REMATCH[2]}" \
            'BEGIN {printf "%.3f", seconds+ms/1000}'
    else
        printf '0'
    fi
}

directory_size_or_zero() {
    [[ -d "$1" ]] && du -sb "$1" | awk '{print $1}' || printf '0\n'
}

format_seconds() {
    awk -v seconds="$(number_or_zero "${1:-0}")" 'BEGIN {
        if (seconds >= 60) printf "%dm %.3fs", int(seconds/60), seconds-int(seconds/60)*60
        else printf "%.3fs", seconds
    }'
}

format_kib() {
    awk -v kib="$(number_or_zero "${1:-0}")" 'BEGIN {
        if (kib >= 1048576) printf "%.2f GiB", kib/1048576
        else printf "%.2f MiB", kib/1024
    }'
}

cleanup_generated() {
    rm -rf -- "$CLIENT_KEYS" "$CLIENT_SERVER_KEYS" "$SERVER_KEYS" \
        "$CLIENT_CIPHERTEXTS" "$SERVER_CIPHERTEXTS" "$SERVER_RESULTS" "$SERVER_CHECKPOINTS"
    [[ ! -L "$SERVER_ROOT/weights" ]] || rm -f -- "$SERVER_ROOT/weights"
}

render_report() {
    local exit_code="$1" end_ns pipeline_wall commit_sha commit_branch commit_subject
    local attempted successful correct accuracy prediction_digest manifest_sha test_set_sha weights_sha
    local batch_total inference_total inference_avg inference_min inference_max circuit_total circuit_avg
    local encryption_total encryption_avg decryption_total decryption_avg
    local avg_cpu peak_cpu avg_rss peak_rss peak_swap keygen_wall keygen_avg_cpu keygen_peak_cpu
    local keygen_avg_rss keygen_peak_rss keygen_peak_swap client_key_bytes server_key_bytes
    local total_key_loading average_key_loading total_bootstrap average_bootstrap bootstrap_count

    end_ns="$(date +%s%N)"
    pipeline_wall="$(awk -v start="$PIPELINE_START_NS" -v end="$end_ns" 'BEGIN {printf "%.3f", (end-start)/1000000000}')"
    commit_sha="${FHE_BENCHMARK_COMMIT:-${GITHUB_SHA:-unknown}}"
    commit_branch="${FHE_BENCHMARK_BRANCH:-${GITHUB_REF_NAME:-unknown}}"
    commit_subject="$(git -C "$REPO_ROOT" log -1 --pretty=%s 2>/dev/null || printf 'unknown')"
    attempted="$(awk 'END {print (NR > 0 ? NR-1 : 0)}' "$RESULTS_CSV")"
    successful="$(awk -F, 'NR>1 && $21=="passed" {count++} END {print count+0}' "$RESULTS_CSV")"
    correct="$(awk -F, 'NR>1 && $21=="passed" {sum+=$7} END {print sum+0}' "$RESULTS_CSV")"
    accuracy="$(awk -v correct="$correct" -v total="$successful" 'BEGIN {printf "%.2f", total ? 100*correct/total : 0}')"
    prediction_digest="$(awk -F, 'NR>1 {print $1 "," $2 "," $3 "," $6 "," $7}' "$RESULTS_CSV" | sha256sum | awk '{print $1}')"
    manifest_sha="$(sha256sum "$MANIFEST" | awk '{print $1}')"
    test_set_sha="$({ while IFS=$'\t' read -r path _; do
        if [[ -n "$path" && "$path" != \#* ]]; then
            printf '%s:%s\n' "$path" "$(sha256sum "$REPO_ROOT/$path" | awk '{print $1}')"
        fi
    done < "$MANIFEST"; } | sha256sum | awk '{print $1}')"
    weights_sha="$(cd "$WEIGHTS_DIR" && find . -type f -printf '%P:%s\n' | sort | sha256sum | awk '{print $1}')"

    read -r batch_total encryption_total inference_total decryption_total circuit_total <<< "$(awk -F, 'NR>1 && $21=="passed" {total+=$11; enc+=$8; inf+=$9; dec+=$10; circuit+=$12} END {printf "%.3f %.3f %.3f %.3f %.3f", total,enc,inf,dec,circuit}' "$RESULTS_CSV")"
    read -r inference_avg inference_min inference_max encryption_avg decryption_avg circuit_avg avg_cpu peak_cpu avg_rss peak_rss peak_swap <<< "$(awk -F, 'NR>1 && $21=="passed" {
        n++; inf+=$9; enc+=$8; dec+=$10; circuit+=$12; weighted_cpu+=$16*$9; weighted_rss+=$18*$9
        if (n==1 || $9<min_inf) min_inf=$9; if (n==1 || $9>max_inf) max_inf=$9
        if ($17>peak_cpu) peak_cpu=$17; if ($19>peak_rss) peak_rss=$19; if ($20>peak_swap) peak_swap=$20
    } END {if (n) printf "%.3f %.3f %.3f %.3f %.3f %.3f %.2f %.2f %.0f %.0f %.0f", inf/n,min_inf,max_inf,enc/n,dec/n,circuit/n,weighted_cpu/inf,peak_cpu,weighted_rss/inf,peak_rss,peak_swap; else print "0 0 0 0 0 0 0 0 0 0 0"}' "$RESULTS_CSV")"

    keygen_wall="$(phase_metric key_generation 4 || true)"
    keygen_avg_cpu="$(phase_metric key_generation 8 || true)"
    keygen_peak_cpu="$(phase_metric key_generation 9 || true)"
    keygen_avg_rss="$(phase_metric key_generation 10 || true)"
    keygen_peak_rss="$(max_number "$(phase_metric key_generation 11 || true)" "$(phase_metric key_generation 12 || true)")"
    keygen_peak_swap="$(phase_metric key_generation 14 || true)"
    client_key_bytes="$(directory_size_or_zero "$CLIENT_KEYS")"
    server_key_bytes="$(directory_size_or_zero "$SERVER_KEYS")"

    if compgen -G "$PROFILE_DIR/*/fhe-operation-profile.json" >/dev/null; then
        read -r total_key_loading total_bootstrap bootstrap_count <<< "$(jq -s -r \
            '([.[].duration_summary.context_and_key_loading_seconds] | add // 0),
             ([.[].bootstrap_summary.total_seconds] | add // 0),
             ([.[].bootstrap_summary.count] | add // 0)' \
            "$PROFILE_DIR"/*/fhe-operation-profile.json | xargs)"
    else
        total_key_loading=0; total_bootstrap=0; bootstrap_count=0
    fi
    average_key_loading="$(awk -v total="$(number_or_zero "$total_key_loading")" -v n="$successful" 'BEGIN {printf "%.3f", n ? total/n : 0}')"
    average_bootstrap="$(awk -v total="$(number_or_zero "$total_bootstrap")" -v n="$successful" 'BEGIN {printf "%.3f", n ? total/n : 0}')"

    if (( exit_code == 0 && successful == EXPECTED_COUNT )); then OVERALL_STATUS="passed"; fi
    {
        echo '# FHE staged 10-image benchmark'
        echo
        echo '## Key results'
        echo
        echo '| Metric | Result |'
        echo '|---|---:|'
        echo "| Status | $OVERALL_STATUS |"
        echo "| Images successful | $successful/$EXPECTED_COUNT |"
        echo "| Classification accuracy | $correct/$successful ($accuracy%) |"
        echo '| Execution strategy | Layer-major, disk-backed checkpoints |'
        echo "| Total pipeline | $(format_seconds "$pipeline_wall") |"
        echo "| Key generation | $(format_seconds "$keygen_wall") |"
        echo "| Staged image workload | $(format_seconds "$batch_total") |"
        echo "| Batch inference wall time | $(format_seconds "$inference_total") |"
        echo "| Amortized inference/image | $(format_seconds "$inference_avg") |"
        echo "| Average FHE circuit/image | $(format_seconds "$circuit_avg") |"
        echo "| Average key loading/image | $(format_seconds "$average_key_loading") |"
        echo "| Average inference CPU | ${avg_cpu}% |"
        echo "| Peak inference CPU | ${peak_cpu}% |"
        echo "| Average inference RAM | $(format_kib "$avg_rss") |"
        echo "| Peak inference RAM | $(format_kib "$peak_rss") |"
        echo "| Peak inference swap | ${peak_swap} KiB |"
        echo
        echo '## Per-image results'
        echo
        echo '| # | Image | True | Prediction | Correct | Infer (s) | Circuit (s) | Peak RAM (KiB) |'
        echo '|---:|---|---|---|---:|---:|---:|---:|'
        awk -F, 'NR>1 {printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$6,$7,$9,$12,$19}' "$RESULTS_CSV"
        echo
        echo '## Reproducibility'
        echo
        echo "- Commit: \`$commit_sha\`"
        echo "- Branch: $commit_branch"
        echo "- Commit note: $commit_subject"
        echo "- Manifest: \`$MANIFEST_RELATIVE\`"
        echo "- Manifest SHA-256: \`$manifest_sha\`"
        echo "- Test-set SHA-256: \`$test_set_sha\`"
        echo "- Prediction digest: \`$prediction_digest\`"
        echo "- Failed phase: ${FAILURE_PHASE:-none}"
    } > "$SUMMARY_MD"

    jq -n \
        --arg status "$OVERALL_STATUS" --arg commit "$commit_sha" --arg branch "$commit_branch" \
        --arg commit_subject "$commit_subject" --arg manifest "$MANIFEST_RELATIVE" \
        --arg manifest_sha256 "$manifest_sha" --arg test_set_sha256 "$test_set_sha" \
        --arg weights_sha256 "$weights_sha" --arg prediction_digest "$prediction_digest" \
        --arg failed_phase "$FAILURE_PHASE" \
        --argjson image_count "$(number_or_zero "$EXPECTED_COUNT")" \
        --argjson attempted_count "$(number_or_zero "$attempted")" \
        --argjson successful_count "$(number_or_zero "$successful")" \
        --argjson correct_count "$(number_or_zero "$correct")" \
        --argjson accuracy_pct "$(number_or_zero "$accuracy")" \
        --argjson pipeline_wall "$(number_or_zero "$pipeline_wall")" \
        --argjson keygen_wall "$(number_or_zero "$keygen_wall")" \
        --argjson keygen_avg_cpu "$(number_or_zero "$keygen_avg_cpu")" \
        --argjson keygen_peak_cpu "$(number_or_zero "$keygen_peak_cpu")" \
        --argjson keygen_avg_rss "$(number_or_zero "$keygen_avg_rss")" \
        --argjson keygen_peak_rss "$(number_or_zero "$keygen_peak_rss")" \
        --argjson keygen_peak_swap "$(number_or_zero "$keygen_peak_swap")" \
        --argjson batch_total "$(number_or_zero "$batch_total")" \
        --argjson encryption_total "$(number_or_zero "$encryption_total")" \
        --argjson encryption_avg "$(number_or_zero "$encryption_avg")" \
        --argjson inference_total "$(number_or_zero "$inference_total")" \
        --argjson inference_avg "$(number_or_zero "$inference_avg")" \
        --argjson inference_min "$(number_or_zero "$inference_min")" \
        --argjson inference_max "$(number_or_zero "$inference_max")" \
        --argjson inference_avg_cpu "$(number_or_zero "$avg_cpu")" \
        --argjson inference_peak_cpu "$(number_or_zero "$peak_cpu")" \
        --argjson inference_avg_rss "$(number_or_zero "$avg_rss")" \
        --argjson inference_peak_rss "$(number_or_zero "$peak_rss")" \
        --argjson inference_peak_swap "$(number_or_zero "$peak_swap")" \
        --argjson circuit_total "$(number_or_zero "$circuit_total")" \
        --argjson circuit_avg "$(number_or_zero "$circuit_avg")" \
        --argjson key_loading_total "$(number_or_zero "$total_key_loading")" \
        --argjson key_loading_avg "$(number_or_zero "$average_key_loading")" \
        --argjson bootstrap_total "$(number_or_zero "$total_bootstrap")" \
        --argjson bootstrap_avg "$(number_or_zero "$average_bootstrap")" \
        --argjson bootstrap_count "$(number_or_zero "$bootstrap_count")" \
        --argjson decryption_total "$(number_or_zero "$decryption_total")" \
        --argjson decryption_avg "$(number_or_zero "$decryption_avg")" \
        --argjson client_key_bytes "$(number_or_zero "$client_key_bytes")" \
        --argjson server_key_bytes "$(number_or_zero "$server_key_bytes")" \
        '{schema_version:1, benchmark_type:"staged_batch10", execution_strategy:"layer_major_disk_backed", status:$status,
          commit:$commit, branch:$branch, commit_subject:$commit_subject,
          failed_phase:($failed_phase | if length==0 then null else . end),
          environment:{manifest:$manifest,manifest_sha256:$manifest_sha256,test_set_sha256:$test_set_sha256,weights_manifest_sha256:$weights_sha256},
          result:{image_count:$image_count,attempted_count:$attempted_count,successful_count:$successful_count,correct_count:$correct_count,accuracy_pct:$accuracy_pct,predictions_sha256:$prediction_digest},
          artifacts:{client_keyset_bytes:$client_key_bytes,server_keyset_bytes:$server_key_bytes},
          metrics:{pipeline_wall_seconds:$pipeline_wall,key_generation:{wall_seconds:$keygen_wall,average_cpu_percent:$keygen_avg_cpu,peak_cpu_percent:$keygen_peak_cpu,average_rss_kb:$keygen_avg_rss,peak_rss_kb:$keygen_peak_rss,peak_swap_kb:$keygen_peak_swap},
            batch:{wall_seconds:$batch_total},encryption:{total_seconds:$encryption_total,average_seconds:$encryption_avg},
            inference:{total_seconds:$inference_total,average_seconds:$inference_avg,min_seconds:$inference_min,max_seconds:$inference_max,average_cpu_percent:$inference_avg_cpu,peak_cpu_percent:$inference_peak_cpu,average_rss_kb:$inference_avg_rss,peak_rss_kb:$inference_peak_rss,peak_swap_kb:$inference_peak_swap},
            circuit:{total_seconds:$circuit_total,average_seconds:$circuit_avg},
            key_loading:{total_seconds:$key_loading_total,average_seconds:$key_loading_avg},
            bootstrap:{total_seconds:$bootstrap_total,average_seconds:$bootstrap_avg,count:$bootstrap_count},
            decryption:{total_seconds:$decryption_total,average_seconds:$decryption_avg}}}' > "$BENCHMARK_JSON"
}

finish() {
    local exit_code=$?
    trap - EXIT
    set +e
    render_report "$exit_code"
    cleanup_generated
    exit "$exit_code"
}
trap finish EXIT

if [[ "$EXPERIMENT" != "1" ]]; then echo 'Only experiment 1 is supported.' >&2; FAILURE_PHASE=preflight; exit 2; fi
for command in /usr/bin/time cmake jq sha256sum pgrep awk; do
    if ! command -v "$command" >/dev/null 2>&1; then echo "Missing command: $command" >&2; FAILURE_PHASE=preflight; exit 2; fi
done
"$REPO_ROOT/CICD/validate_batch_manifest.sh" "$REPO_ROOT" "$MANIFEST" "$EXPECTED_COUNT"
if [[ ! -d "$WEIGHTS_DIR" || ! -f "$WEIGHTS_DIR/fc.bin" ]]; then echo "Missing weights: $WEIGHTS_DIR" >&2; FAILURE_PHASE=preflight; exit 2; fi
if pgrep -f '(^|/)FHEServer infer(_batch)? ' >/dev/null; then echo 'Another FHEServer inference is running.' >&2; FAILURE_PHASE=preflight; exit 75; fi
available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
free_disk_kb="$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print $4}')"
if (( available_kb < 18*1024*1024 )); then echo "At least 18 GiB available RAM is required." >&2; FAILURE_PHASE=preflight; exit 75; fi
if (( free_disk_kb < 60*1024*1024 )); then echo "At least 60 GiB free disk is required." >&2; FAILURE_PHASE=preflight; exit 75; fi

cleanup_generated
mkdir -p "$CLIENT_CIPHERTEXTS" "$SERVER_CIPHERTEXTS" "$SERVER_RESULTS" "$SERVER_CHECKPOINTS"
ln -s "$WEIGHTS_DIR" "$SERVER_ROOT/weights"

measure_phase build_client cmake -S "$CLIENT_ROOT" -B "$CLIENT_ROOT/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local || exit "$LAST_PHASE_EXIT"
measure_phase compile_client cmake --build "$CLIENT_ROOT/build" --parallel "$BUILD_JOBS" || exit "$LAST_PHASE_EXIT"
measure_phase build_server cmake -S "$SERVER_ROOT" -B "$SERVER_ROOT/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local || exit "$LAST_PHASE_EXIT"
measure_phase compile_server cmake --build "$SERVER_ROOT/build" --parallel "$BUILD_JOBS" || exit "$LAST_PHASE_EXIT"
measure_phase key_generation bash -c 'cd "$1" && exec ./FHEClient generate_keys "$2"' _ "$CLIENT_ROOT/build" "$EXPERIMENT" || exit "$LAST_PHASE_EXIT"
measure_phase key_transfer bash -c 'mkdir -p "$2" && cp -al "$1"/. "$2"/' _ "$CLIENT_SERVER_KEYS" "$SERVER_KEYS" || exit "$LAST_PHASE_EXIT"
if [[ -f "$SERVER_KEYS/secret-key.txt" ]]; then echo 'Secret key reached server directory.' >&2; FAILURE_PHASE=key_transfer; exit 1; fi

index=0
while IFS=$'\t' read -r image_relative expected_class; do
    [[ -z "$image_relative" || "$image_relative" == \#* ]] && continue
    index=$((index + 1))
    suffix="$(printf '%02d' "$index")"
    image="$REPO_ROOT/$image_relative"
    client_input="$CLIENT_CIPHERTEXTS/batch10-${suffix}-input.bin"
    server_input="$SERVER_CIPHERTEXTS/batch10-${suffix}-input.bin"
    server_result="$SERVER_RESULTS/batch10-${suffix}-result.bin"
    client_result="$CLIENT_CIPHERTEXTS/batch10-${suffix}-result.bin"
    measure_phase "encryption_${suffix}" bash -c 'cd "$1" && exec ./FHEClient encrypt "$2" "$3" "$4"' \
        _ "$CLIENT_ROOT/build" "$EXPERIMENT" "$image" "$client_input" || exit "$LAST_PHASE_EXIT"
    cp -- "$client_input" "$server_input"

    printf '%s\t%s\n' "$server_input" "$server_result" >> "$SERVER_BATCH_MANIFEST"
    printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$index" "$image_relative" "$expected_class" "$client_input" "$server_input" \
        "$server_result" "$client_result" >> "$BATCH_JOB_METADATA"
done < "$MANIFEST"

mkdir -p "$PROFILE_DIR/batch"
measure_phase inference_batch bash -c \
    'cd "$1" && export FHE_PROFILE=1 FHE_PROFILE_DIR="$6"; exec ./FHEServer infer_batch "$2" "$3" "$4" "$5" 1' \
    _ "$SERVER_ROOT/build" "$EXPERIMENT" "$SERVER_BATCH_MANIFEST" "$SERVER_CHECKPOINTS" \
    "$SERVER_BATCH_METRICS" "$PROFILE_DIR/batch" || exit "$LAST_PHASE_EXIT"

batch_inference_seconds="$(phase_metric inference_batch 4)"
amortized_inference_seconds="$(awk -v total="$(number_or_zero "$batch_inference_seconds")" \
    -v count="$EXPECTED_COUNT" 'BEGIN {printf "%.3f", count ? total/count : 0}')"
inference_avg_cpu="$(phase_metric inference_batch 8)"
inference_peak_cpu="$(phase_metric inference_batch 9)"
inference_avg_rss="$(phase_metric inference_batch 10)"
inference_peak_rss="$(max_number "$(phase_metric inference_batch 11)" "$(phase_metric inference_batch 12)")"
inference_peak_swap="$(phase_metric inference_batch 14)"

while IFS=$'\t' read -r index image_relative expected_class client_input server_input server_result client_result; do
    suffix="$(printf '%02d' "$index")"
    cp -- "$server_result" "$client_result"
    measure_phase "decryption_${suffix}" bash -c 'cd "$1" && exec ./FHEClient decrypt "$2" "$3"' \
        _ "$CLIENT_ROOT/build" "$EXPERIMENT" "$client_result" || exit "$LAST_PHASE_EXIT"

    FAILURE_PHASE="result_processing_${suffix}"
    decrypt_log="$LOG_DIR/decryption_${suffix}.log"
    handgun_logit="$(awk -F': ' '/^Handgun:/ {print $2; exit}' "$decrypt_log")"
    knife_logit="$(awk -F': ' '/^Knife:/ {print $2; exit}' "$decrypt_log")"
    prediction="$(awk -F': ' '/^Prediction:/ {print $2; exit}' "$decrypt_log")"
    if [[ -z "$handgun_logit" || -z "$knife_logit" || ( "$prediction" != Handgun && "$prediction" != Knife ) ]]; then
        echo "Invalid decryption output for $image_relative" >&2; FAILURE_PHASE="decryption_validation_${suffix}"; exit 1
    fi
    correct=0; [[ "$prediction" != "$expected_class" ]] || correct=1
    metric_line="$(awk -F'\t' -v image_index="$index" 'NR>1 && $1==image_index {print; exit}' "$SERVER_BATCH_METRICS")"
    if [[ -z "$metric_line" ]]; then
        echo "Missing staged batch metrics for image $index" >&2
        FAILURE_PHASE="batch_metrics_${suffix}"
        exit 1
    fi
    IFS=$'\t' read -r _ _ _ circuit_value layer1_value layer2_value layer3_value final_value <<< "$metric_line"
    encrypt_seconds="$(phase_metric "encryption_${suffix}" 4)"
    decrypt_seconds="$(phase_metric "decryption_${suffix}" 4)"
    total_seconds="$(awk -v enc="$(number_or_zero "$encrypt_seconds")" \
        -v inf="$amortized_inference_seconds" -v dec="$(number_or_zero "$decrypt_seconds")" \
        'BEGIN {printf "%.3f", enc+inf+dec}')"
    printf '%d,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,passed\n' \
        "$index" "$image_relative" "$expected_class" "$handgun_logit" "$knife_logit" "$prediction" "$correct" \
        "$encrypt_seconds" "$amortized_inference_seconds" "$decrypt_seconds" "$total_seconds" \
        "$circuit_value" "$layer1_value" "$layer2_value" "$layer3_value" \
        "$inference_avg_cpu" "$inference_peak_cpu" "$inference_avg_rss" "$inference_peak_rss" "$inference_peak_swap" >> "$RESULTS_CSV"
    rm -f -- "$client_input" "$server_input" "$server_result" "$client_result"
    FAILURE_PHASE=""
done < "$BATCH_JOB_METADATA"

OVERALL_STATUS="passed"
