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

COMPARISON_JSON="$OUTPUT_DIR/comparison.json"
COMPARISON_MD="$OUTPUT_DIR/comparison.md"

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

greater_than() {
    awk -v first="$1" -v second="$2" 'BEGIN {exit !(first > second)}'
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
swap_difference="$(difference "$baseline_peak_swap" "$candidate_peak_swap")"

# Performance decisions are deliberately manual. This script only establishes
# that two successful runs are comparable and renders their measured deltas.
verdict="manual_review"
classification="Manual review required"
declare -a reasons=("Automatic performance decisions and promotion are disabled; review the measured deltas manually")

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
    mark_not_comparable "Both baseline and candidate benchmarks must pass before manual comparison"
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
reasons_json="$(printf '%s\n' "${reasons[@]:-}" | jq -R 'select(length > 0)' | jq -s .)"
jq -n \
    --arg verdict "$verdict" \
    --arg classification "$classification" \
    --arg baseline_commit "$baseline_commit" \
    --arg candidate_commit "$candidate_commit" \
    --arg prediction "$candidate_prediction" \
    --argjson reasons "$reasons_json" \
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
    if (( ${#reasons[@]} > 0 )); then
        echo
        echo "## Gate notes"
        printf -- '- %s\n' "${reasons[@]}"
    fi
} > "$COMPARISON_MD"

case "$verdict" in
    manual_review) exit 0 ;;
    not_comparable) exit 4 ;;
    *) exit 5 ;;
esac
