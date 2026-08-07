#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 3 || $# > 7 )); then
    echo "Usage: compare_benchmark.sh <baseline.json> <candidate.json> <output-dir> [pr-title] [expected-base-sha] [expected-head-sha] [change-note.md]" >&2
    exit 2
fi

BASELINE_JSON="$1"
CANDIDATE_JSON="$2"
OUTPUT_DIR="$3"
PR_TITLE="${4:-Performance update}"
EXPECTED_BASE_SHA="${5:-}"
EXPECTED_HEAD_SHA="${6:-}"
CHANGE_NOTE_FILE="${7:-}"

STABLE_PERCENT="${FHE_STABLE_PERCENT:-3}"
MAX_PRIMARY_REGRESSION_PERCENT="${FHE_MAX_PRIMARY_REGRESSION_PERCENT:-5}"
REJECT_TIME_PERCENT="${FHE_REJECT_TIME_PERCENT:-10}"
REJECT_RAM_PERCENT="${FHE_REJECT_RAM_PERCENT:-10}"
REJECT_KEYGEN_PERCENT="${FHE_REJECT_KEYGEN_PERCENT:-30}"
MAX_CPU_TIME_REGRESSION_PERCENT="${FHE_MAX_CPU_TIME_REGRESSION_PERCENT:-25}"
RAM_HARD_CAP_KB="${FHE_RAM_HARD_CAP_KB:-21495808}"
KEYGEN_RAM_HARD_CAP_KB="${FHE_KEYGEN_RAM_HARD_CAP_KB:-18874368}"
RAM_AUTO_INCREASE_KB="${FHE_RAM_AUTO_INCREASE_KB:-1048576}"
TRADEOFF_RATIO="${FHE_TRADEOFF_RATIO:-2}"

COMPARISON_JSON="$OUTPUT_DIR/comparison.json"
COMPARISON_MD="$OUTPUT_DIR/comparison.md"
COMMIT_TITLE_FILE="$OUTPUT_DIR/commit-title.txt"
COMMIT_BODY_FILE="$OUTPUT_DIR/commit-body.md"
README_ENTRY_FILE="$OUTPUT_DIR/readme-entry.md"

mkdir -p "$OUTPUT_DIR"

for file in "$BASELINE_JSON" "$CANDIDATE_JSON"; do
    if [[ ! -s "$file" ]] || ! jq -e . "$file" >/dev/null; then
        echo "Missing or invalid benchmark JSON: $file" >&2
        exit 2
    fi
done

if [[ -n "$CHANGE_NOTE_FILE" ]]; then
    "$(dirname -- "$0")/validate_change_note.sh" "$CHANGE_NOTE_FILE"
fi

json_number() {
    local file="$1"
    local path="$2"
    jq -er "$path | numbers" "$file"
}

json_string() {
    local file="$1"
    local path="$2"
    jq -er "$path | strings" "$file"
}

percent_change() {
    local baseline="$1"
    local candidate="$2"
    awk -v baseline="$baseline" -v candidate="$candidate" 'BEGIN {
        if (baseline == 0) {print "0.000"; exit}
        printf "%.3f", (candidate - baseline) * 100 / baseline
    }'
}

difference() {
    awk -v baseline="$1" -v candidate="$2" 'BEGIN {printf "%.3f", candidate - baseline}'
}

less_than() {
    awk -v first="$1" -v second="$2" 'BEGIN {exit !(first < second)}'
}

less_equal() {
    awk -v first="$1" -v second="$2" 'BEGIN {exit !(first <= second)}'
}

greater_than() {
    awk -v first="$1" -v second="$2" 'BEGIN {exit !(first > second)}'
}

greater_equal() {
    awk -v first="$1" -v second="$2" 'BEGIN {exit !(first >= second)}'
}

absolute_value() {
    awk -v value="$1" 'BEGIN {if (value < 0) value=-value; printf "%.3f", value}'
}

format_delta() {
    awk -v value="$1" 'BEGIN {printf "%+.2f%%", value}'
}

format_seconds_value() {
    awk -v seconds="$1" 'BEGIN {
        if (seconds >= 60) printf "%dm %.3fs", int(seconds/60), seconds-int(seconds/60)*60
        else printf "%.3fs", seconds
    }'
}

format_gib() {
    awk -v kib="$1" 'BEGIN {printf "%.2f GiB", kib/1048576}'
}

baseline_status="$(json_string "$BASELINE_JSON" '.status')"
candidate_status="$(json_string "$CANDIDATE_JSON" '.status')"
baseline_commit="$(json_string "$BASELINE_JSON" '.commit')"
candidate_commit="$(json_string "$CANDIDATE_JSON" '.commit')"
baseline_prediction="$(json_string "$BASELINE_JSON" '.result.prediction')"
candidate_prediction="$(json_string "$CANDIDATE_JSON" '.result.prediction')"

baseline_inference="$(json_number "$BASELINE_JSON" '.metrics.inference.wall_seconds')"
candidate_inference="$(json_number "$CANDIDATE_JSON" '.metrics.inference.wall_seconds')"
baseline_circuit="$(json_number "$BASELINE_JSON" '.metrics.circuit.wall_seconds')"
candidate_circuit="$(json_number "$CANDIDATE_JSON" '.metrics.circuit.wall_seconds')"
baseline_peak_ram="$(json_number "$BASELINE_JSON" '.metrics.inference.peak_rss_kb')"
candidate_peak_ram="$(json_number "$CANDIDATE_JSON" '.metrics.inference.peak_rss_kb')"
baseline_average_ram="$(json_number "$BASELINE_JSON" '.metrics.inference.average_rss_kb')"
candidate_average_ram="$(json_number "$CANDIDATE_JSON" '.metrics.inference.average_rss_kb')"
baseline_cpu_time="$(json_number "$BASELINE_JSON" '.metrics.inference.cpu_time_seconds')"
candidate_cpu_time="$(json_number "$CANDIDATE_JSON" '.metrics.inference.cpu_time_seconds')"
baseline_average_cpu="$(json_number "$BASELINE_JSON" '.metrics.inference.average_cpu_percent')"
candidate_average_cpu="$(json_number "$CANDIDATE_JSON" '.metrics.inference.average_cpu_percent')"
baseline_peak_cpu="$(json_number "$BASELINE_JSON" '.metrics.inference.peak_cpu_percent')"
candidate_peak_cpu="$(json_number "$CANDIDATE_JSON" '.metrics.inference.peak_cpu_percent')"
baseline_keygen="$(json_number "$BASELINE_JSON" '.metrics.key_generation.wall_seconds')"
candidate_keygen="$(json_number "$CANDIDATE_JSON" '.metrics.key_generation.wall_seconds')"
baseline_keygen_peak_ram="$(json_number "$BASELINE_JSON" '.metrics.key_generation.peak_rss_kb')"
candidate_keygen_peak_ram="$(json_number "$CANDIDATE_JSON" '.metrics.key_generation.peak_rss_kb')"
baseline_peak_swap="$(json_number "$BASELINE_JSON" '.metrics.inference.peak_swap_kb')"
candidate_peak_swap="$(json_number "$CANDIDATE_JSON" '.metrics.inference.peak_swap_kb')"

inference_delta="$(percent_change "$baseline_inference" "$candidate_inference")"
circuit_delta="$(percent_change "$baseline_circuit" "$candidate_circuit")"
peak_ram_delta="$(percent_change "$baseline_peak_ram" "$candidate_peak_ram")"
average_ram_delta="$(percent_change "$baseline_average_ram" "$candidate_average_ram")"
cpu_time_delta="$(percent_change "$baseline_cpu_time" "$candidate_cpu_time")"
average_cpu_delta="$(percent_change "$baseline_average_cpu" "$candidate_average_cpu")"
peak_cpu_delta="$(percent_change "$baseline_peak_cpu" "$candidate_peak_cpu")"
keygen_delta="$(percent_change "$baseline_keygen" "$candidate_keygen")"
keygen_peak_ram_delta="$(percent_change "$baseline_keygen_peak_ram" "$candidate_keygen_peak_ram")"
inference_difference="$(difference "$baseline_inference" "$candidate_inference")"
circuit_difference="$(difference "$baseline_circuit" "$candidate_circuit")"
ram_difference="$(difference "$baseline_peak_ram" "$candidate_peak_ram")"
swap_difference="$(difference "$baseline_peak_swap" "$candidate_peak_swap")"

verdict="auto_merge"
classification="Improved"
declare -a reasons=()
declare -a improvements=()

mark_rejected() {
    if [[ "$verdict" != "not_comparable" ]]; then
        verdict="rejected"
        classification="Regressed"
    fi
    reasons+=("$1")
}

mark_manual_review() {
    if [[ "$verdict" == "auto_merge" ]]; then
        verdict="manual_review"
        classification="Manual review required"
    fi
    reasons+=("$1")
}

mark_not_comparable() {
    verdict="not_comparable"
    classification="Not comparable"
    reasons+=("$1")
}

for path in \
    '.schema_version' \
    '.environment.experiment' \
    '.environment.test_image_sha256' \
    '.environment.weights_manifest_sha256' \
    '.environment.cpu_model' \
    '.environment.logical_cpus' \
    '.environment.total_ram_kb' \
    '.environment.openfhe_version'; do
    baseline_value="$(jq -c "$path" "$BASELINE_JSON")"
    candidate_value="$(jq -c "$path" "$CANDIDATE_JSON")"
    if [[ "$baseline_value" != "$candidate_value" ]]; then
        mark_not_comparable "Environment mismatch at $path: $baseline_value -> $candidate_value"
    fi
done

if [[ -n "$EXPECTED_BASE_SHA" && "$baseline_commit" != "$EXPECTED_BASE_SHA" ]]; then
    mark_not_comparable "Baseline SHA $baseline_commit does not match PR base $EXPECTED_BASE_SHA"
fi
if [[ -n "$EXPECTED_HEAD_SHA" && "$candidate_commit" != "$EXPECTED_HEAD_SHA" ]]; then
    mark_not_comparable "Candidate SHA $candidate_commit does not match PR head $EXPECTED_HEAD_SHA"
fi
if [[ "$baseline_status" != "passed" || "$candidate_status" != "passed" ]]; then
    mark_rejected "Both baseline and candidate benchmarks must pass"
fi
for metric_pair in \
    "$baseline_inference:$candidate_inference:inference_time" \
    "$baseline_circuit:$candidate_circuit:circuit_time" \
    "$baseline_peak_ram:$candidate_peak_ram:peak_ram" \
    "$baseline_average_ram:$candidate_average_ram:average_ram" \
    "$baseline_cpu_time:$candidate_cpu_time:cpu_time" \
    "$baseline_average_cpu:$candidate_average_cpu:average_cpu" \
    "$baseline_peak_cpu:$candidate_peak_cpu:peak_cpu" \
    "$baseline_keygen:$candidate_keygen:key_generation" \
    "$baseline_keygen_peak_ram:$candidate_keygen_peak_ram:key_generation_peak_ram"; do
    IFS=: read -r baseline_metric candidate_metric metric_name <<< "$metric_pair"
    if ! greater_than "$baseline_metric" 0 || ! greater_than "$candidate_metric" 0; then
        mark_not_comparable "Required metric $metric_name is missing or zero"
    fi
done
if [[ "$candidate_prediction" != "$baseline_prediction" ]]; then
    mark_rejected "Prediction changed: $baseline_prediction -> $candidate_prediction"
fi
if greater_than "$candidate_peak_ram" "$RAM_HARD_CAP_KB"; then
    mark_rejected "Inference peak RAM exceeds the hard cap of $(format_gib "$RAM_HARD_CAP_KB")"
fi
if greater_than "$candidate_keygen_peak_ram" "$KEYGEN_RAM_HARD_CAP_KB"; then
    mark_rejected "Key generation peak RAM exceeds the hard cap of $(format_gib "$KEYGEN_RAM_HARD_CAP_KB")"
fi
if greater_than "$peak_ram_delta" "$REJECT_RAM_PERCENT"; then
    mark_rejected "Inference peak RAM regressed by $(format_delta "$peak_ram_delta")"
fi
if greater_than "$inference_delta" "$REJECT_TIME_PERCENT" \
        && greater_than "$inference_difference" 30; then
    mark_rejected "Inference time regressed by $(format_delta "$inference_delta")"
fi
if greater_than "$circuit_delta" "$REJECT_TIME_PERCENT" \
        && greater_than "$circuit_difference" 30; then
    mark_rejected "FHE circuit time regressed by $(format_delta "$circuit_delta")"
fi
if greater_than "$keygen_delta" "$REJECT_KEYGEN_PERCENT"; then
    mark_rejected "Key generation time regressed by $(format_delta "$keygen_delta")"
fi
if greater_than "$cpu_time_delta" "$MAX_CPU_TIME_REGRESSION_PERCENT" \
        && greater_than "$inference_delta" -5; then
    mark_rejected "CPU time increased by $(format_delta "$cpu_time_delta") without enough speed gain"
fi

if less_equal "$inference_delta" "-$STABLE_PERCENT"; then
    improvements+=("Inference time $(format_delta "$inference_delta")")
fi
if less_equal "$circuit_delta" "-$STABLE_PERCENT"; then
    improvements+=("FHE circuit time $(format_delta "$circuit_delta")")
fi
if less_equal "$peak_ram_delta" "-$STABLE_PERCENT"; then
    improvements+=("Inference peak RAM $(format_delta "$peak_ram_delta")")
fi
if less_equal "$cpu_time_delta" -5; then
    improvements+=("Inference CPU time $(format_delta "$cpu_time_delta")")
fi
if less_equal "$keygen_delta" -5; then
    improvements+=("Key generation time $(format_delta "$keygen_delta")")
fi
if less_equal "$keygen_peak_ram_delta" -5; then
    improvements+=("Key generation peak RAM $(format_delta "$keygen_peak_ram_delta")")
fi

if [[ "$verdict" != "rejected" && "$verdict" != "not_comparable" \
        && ${#improvements[@]} -eq 0 ]]; then
    mark_manual_review "No primary metric improved beyond the stability threshold"
fi

if [[ "$verdict" == "auto_merge" ]]; then
    standard_ok=true
    for delta in "$inference_delta" "$circuit_delta" "$peak_ram_delta" \
            "$keygen_delta" "$keygen_peak_ram_delta"; do
        if greater_than "$delta" "$STABLE_PERCENT"; then
            standard_ok=false
        fi
    done

    speed_gain="$(awk -v value="$inference_delta" 'BEGIN {printf "%.3f", -value}')"
    ram_gain="$(awk -v value="$peak_ram_delta" 'BEGIN {printf "%.3f", -value}')"
    speed_ram_ratio="0"
    if greater_than "$peak_ram_delta" 0; then
        speed_ram_ratio="$(awk -v speed="$speed_gain" -v ram="$peak_ram_delta" 'BEGIN {printf "%.3f", speed/ram}')"
    fi

    speed_memory_tradeoff=false
    if greater_equal "$speed_gain" 5 \
            && greater_than "$peak_ram_delta" "$STABLE_PERCENT" \
            && less_equal "$peak_ram_delta" 5 \
            && less_equal "$ram_difference" "$RAM_AUTO_INCREASE_KB" \
            && less_equal "$circuit_delta" "$MAX_PRIMARY_REGRESSION_PERCENT" \
            && less_equal "$cpu_time_delta" "$MAX_CPU_TIME_REGRESSION_PERCENT" \
            && greater_equal "$speed_ram_ratio" "$TRADEOFF_RATIO"; then
        speed_memory_tradeoff=true
        classification="Improved with acceptable memory trade-off"
    fi

    memory_speed_tradeoff=false
    if greater_equal "$ram_gain" 5 \
            && greater_than "$inference_delta" "$STABLE_PERCENT" \
            && less_equal "$inference_delta" 5 \
            && less_equal "$circuit_delta" "$MAX_PRIMARY_REGRESSION_PERCENT" \
            && less_equal "$cpu_time_delta" 10; then
        memory_speed_tradeoff=true
        classification="Improved with acceptable speed trade-off"
    fi

    if [[ "$standard_ok" != true && "$speed_memory_tradeoff" != true \
            && "$memory_speed_tradeoff" != true ]]; then
        verdict="manual_review"
        classification="Manual review required"
        reasons+=("The candidate has a mixed trade-off outside automatic promotion limits")
    fi
fi

reasons_json="$(printf '%s\n' "${reasons[@]:-}" | jq -R 'select(length > 0)' | jq -s .)"
improvements_json="$(printf '%s\n' "${improvements[@]:-}" | jq -R 'select(length > 0)' | jq -s .)"

jq -n \
    --arg verdict "$verdict" \
    --arg classification "$classification" \
    --arg baseline_commit "$baseline_commit" \
    --arg candidate_commit "$candidate_commit" \
    --arg prediction "$candidate_prediction" \
    --argjson reasons "$reasons_json" \
    --argjson improvements "$improvements_json" \
    --argjson inference_delta "$inference_delta" \
    --argjson circuit_delta "$circuit_delta" \
    --argjson peak_ram_delta "$peak_ram_delta" \
    --argjson average_ram_delta "$average_ram_delta" \
    --argjson cpu_time_delta "$cpu_time_delta" \
    --argjson average_cpu_delta "$average_cpu_delta" \
    --argjson peak_cpu_delta "$peak_cpu_delta" \
    --argjson keygen_delta "$keygen_delta" \
    --argjson keygen_peak_ram_delta "$keygen_peak_ram_delta" \
    --argjson baseline_peak_swap_kb "$baseline_peak_swap" \
    --argjson candidate_peak_swap_kb "$candidate_peak_swap" \
    --argjson swap_difference_kb "$swap_difference" \
    '{
        verdict: $verdict,
        classification: $classification,
        baseline_commit: $baseline_commit,
        candidate_commit: $candidate_commit,
        prediction: $prediction,
        improvements: $improvements,
        reasons: $reasons,
        deltas_percent: {
            inference: $inference_delta,
            circuit: $circuit_delta,
            peak_ram: $peak_ram_delta,
            average_ram: $average_ram_delta,
            cpu_time: $cpu_time_delta,
            average_cpu: $average_cpu_delta,
            peak_cpu: $peak_cpu_delta,
            key_generation: $keygen_delta,
            key_generation_peak_ram: $keygen_peak_ram_delta
        },
        swap: {
            baseline_peak_kb: $baseline_peak_swap_kb,
            candidate_peak_kb: $candidate_peak_swap_kb,
            difference_kb: $swap_difference_kb
        }
    }' > "$COMPARISON_JSON"

{
    echo "# FHE benchmark comparison"
    echo
    echo "**Verdict: $classification**"
    echo
    echo "| Metric | Baseline dev | Candidate | Change |"
    echo "|---|---:|---:|---:|"
    echo "| Inference time | $(format_seconds_value "$baseline_inference") | $(format_seconds_value "$candidate_inference") | $(format_delta "$inference_delta") |"
    echo "| FHE circuit time | $(format_seconds_value "$baseline_circuit") | $(format_seconds_value "$candidate_circuit") | $(format_delta "$circuit_delta") |"
    echo "| Peak RAM | $(format_gib "$baseline_peak_ram") | $(format_gib "$candidate_peak_ram") | $(format_delta "$peak_ram_delta") |"
    echo "| Average RAM | $(format_gib "$baseline_average_ram") | $(format_gib "$candidate_average_ram") | $(format_delta "$average_ram_delta") |"
    echo "| CPU time | $(format_seconds_value "$baseline_cpu_time") | $(format_seconds_value "$candidate_cpu_time") | $(format_delta "$cpu_time_delta") |"
    echo "| Average CPU | ${baseline_average_cpu}% | ${candidate_average_cpu}% | $(format_delta "$average_cpu_delta") |"
    echo "| Peak CPU | ${baseline_peak_cpu}% | ${candidate_peak_cpu}% | $(format_delta "$peak_cpu_delta") |"
    echo "| Key generation | $(format_seconds_value "$baseline_keygen") | $(format_seconds_value "$candidate_keygen") | $(format_delta "$keygen_delta") |"
    echo "| Keygen peak RAM | $(format_gib "$baseline_keygen_peak_ram") | $(format_gib "$candidate_keygen_peak_ram") | $(format_delta "$keygen_peak_ram_delta") |"
    echo "| Peak swap | ${baseline_peak_swap} KiB | ${candidate_peak_swap} KiB | ${swap_difference} KiB |"
    echo "| Prediction | $baseline_prediction | $candidate_prediction | — |"
    if (( ${#improvements[@]} > 0 )); then
        echo
        echo "## Improvements"
        printf -- '- %s\n' "${improvements[@]}"
    fi
    if (( ${#reasons[@]} > 0 )); then
        echo
        echo "## Gate notes"
        printf -- '- %s\n' "${reasons[@]}"
    fi
} > "$COMPARISON_MD"

clean_title="$(printf '%s' "$PR_TITLE" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]*$//')"
title_suffix="infer $(format_delta "$inference_delta"), RAM $(format_delta "$peak_ram_delta")"
printf '%.90s (%s)\n' "$clean_title" "$title_suffix" > "$COMMIT_TITLE_FILE"

{
    echo "Benchmark promotion: $classification"
    echo
    echo "Baseline: $baseline_commit"
    echo "Candidate: $candidate_commit"
    echo
    echo "| Metric | Baseline | Candidate | Change |"
    echo "|---|---:|---:|---:|"
    echo "| Inference | $(format_seconds_value "$baseline_inference") | $(format_seconds_value "$candidate_inference") | $(format_delta "$inference_delta") |"
    echo "| FHE circuit | $(format_seconds_value "$baseline_circuit") | $(format_seconds_value "$candidate_circuit") | $(format_delta "$circuit_delta") |"
    echo "| Peak RAM | $(format_gib "$baseline_peak_ram") | $(format_gib "$candidate_peak_ram") | $(format_delta "$peak_ram_delta") |"
    echo "| Average RAM | $(format_gib "$baseline_average_ram") | $(format_gib "$candidate_average_ram") | $(format_delta "$average_ram_delta") |"
    echo "| CPU time | $(format_seconds_value "$baseline_cpu_time") | $(format_seconds_value "$candidate_cpu_time") | $(format_delta "$cpu_time_delta") |"
    echo "| Average CPU | ${baseline_average_cpu}% | ${candidate_average_cpu}% | $(format_delta "$average_cpu_delta") |"
    echo "| Peak CPU | ${baseline_peak_cpu}% | ${candidate_peak_cpu}% | $(format_delta "$peak_cpu_delta") |"
    echo "| Key generation | $(format_seconds_value "$baseline_keygen") | $(format_seconds_value "$candidate_keygen") | $(format_delta "$keygen_delta") |"
    echo "| Keygen peak RAM | $(format_gib "$baseline_keygen_peak_ram") | $(format_gib "$candidate_keygen_peak_ram") | $(format_delta "$keygen_peak_ram_delta") |"
    echo
    echo "Prediction: $candidate_prediction"
    echo "Inference peak swap: ${candidate_peak_swap} KiB"
    if (( ${#improvements[@]} > 0 )); then
        echo
        echo "Improvements:"
        printf -- '- %s\n' "${improvements[@]}"
    fi
} > "$COMMIT_BODY_FILE"

{
    if [[ -n "$CHANGE_NOTE_FILE" ]]; then
        sed 's/^## /#### /' "$CHANGE_NOTE_FILE"
        echo
    fi
    echo "#### Benchmark so với phiên bản dev trước"
    echo
    echo "| Chỉ số | Trước | Sau | Thay đổi |"
    echo "|---|---:|---:|---:|"
    echo "| Sinh khóa | $(format_seconds_value "$baseline_keygen") | $(format_seconds_value "$candidate_keygen") | $(format_delta "$keygen_delta") |"
    echo "| Suy luận | $(format_seconds_value "$baseline_inference") | $(format_seconds_value "$candidate_inference") | $(format_delta "$inference_delta") |"
    echo "| Tính toán FHE | $(format_seconds_value "$baseline_circuit") | $(format_seconds_value "$candidate_circuit") | $(format_delta "$circuit_delta") |"
    echo "| RAM trung bình | $(format_gib "$baseline_average_ram") | $(format_gib "$candidate_average_ram") | $(format_delta "$average_ram_delta") |"
    echo "| RAM đỉnh | $(format_gib "$baseline_peak_ram") | $(format_gib "$candidate_peak_ram") | $(format_delta "$peak_ram_delta") |"
    echo "| CPU time | $(format_seconds_value "$baseline_cpu_time") | $(format_seconds_value "$candidate_cpu_time") | $(format_delta "$cpu_time_delta") |"
    echo "| CPU trung bình | ${baseline_average_cpu}% | ${candidate_average_cpu}% | $(format_delta "$average_cpu_delta") |"
    echo "| CPU đỉnh | ${baseline_peak_cpu}% | ${candidate_peak_cpu}% | $(format_delta "$peak_cpu_delta") |"
    echo
    echo "**Đánh giá:** $classification  "
    echo "**Prediction:** $candidate_prediction  "
    echo "**Swap khi suy luận:** ${candidate_peak_swap} KiB"
} > "$README_ENTRY_FILE"

case "$verdict" in
    auto_merge) exit 0 ;;
    manual_review) exit 0 ;;
    rejected) exit 3 ;;
    not_comparable) exit 4 ;;
    *) exit 5 ;;
esac
