#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d /tmp/fhe-compare-test.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

make_benchmark() {
    local output="$1"
    local commit="$2"
    local inference="$3"
    local circuit="$4"
    local peak_ram="$5"
    local average_ram="$6"
    local cpu_time="$7"
    local keygen="$8"
    local prediction="$9"
    local swap="${10}"

    jq -n \
        --arg commit "$commit" \
        --arg prediction "$prediction" \
        --argjson inference "$inference" \
        --argjson circuit "$circuit" \
        --argjson peak_ram "$peak_ram" \
        --argjson average_ram "$average_ram" \
        --argjson cpu_time "$cpu_time" \
        --argjson keygen "$keygen" \
        --argjson swap "$swap" \
        '{
            schema_version: 1,
            status: "passed",
            commit: $commit,
            branch: "dev",
            commit_subject: "test",
            environment: {
                experiment: "1",
                test_image: "FHEClient/inputs/2041_0.png",
                test_image_sha256: "image-sha",
                weights_manifest_sha256: "weights-sha",
                cpu_model: "test-cpu",
                logical_cpus: 12,
                total_ram_kb: 24606276,
                openfhe_version: "1.0.4"
            },
            result: {prediction: $prediction, handgun_logit: 3.0, knife_logit: -3.0},
            metrics: {
                pipeline_wall_seconds: 900,
                key_generation: {wall_seconds: $keygen, cpu_time_seconds: 200, average_cpu_percent: 140, peak_cpu_percent: 200, average_rss_kb: 10000000, peak_rss_kb: 12000000, peak_swap_kb: 0},
                encryption: {wall_seconds: 1},
                inference: {wall_seconds: $inference, cpu_time_seconds: $cpu_time, average_cpu_percent: 400, peak_cpu_percent: 700, average_rss_kb: $average_ram, peak_rss_kb: $peak_ram, peak_swap_kb: $swap},
                decryption: {wall_seconds: 2},
                circuit: {wall_seconds: $circuit, layer1_seconds: 100, layer2_seconds: 200, layer3_seconds: 300}
            }
        }' > "$output"
}

BASE_SHA="base-sha"
HEAD_SHA="head-sha"
BASELINE="$TMP_ROOT/baseline.json"
make_benchmark "$BASELINE" "$BASE_SHA" 745 624 19500000 17000000 3080 165 Handgun 0
CHANGE_NOTE="$TMP_ROOT/change-note.md"
cat > "$CHANGE_NOTE" <<'EOF'
## Đã sửa gì

Reduced test work.

## Cơ chế

Reuses precomputation.

## Cách hoạt động

Avoids a duplicate operation.

## Lợi ích

Reduces inference time.
EOF

run_case() {
    local name="$1"
    local expected_verdict="$2"
    shift 2
    local case_dir="$TMP_ROOT/$name"
    local candidate="$case_dir/candidate.json"
    mkdir -p "$case_dir"
    make_benchmark "$candidate" "$HEAD_SHA" "$@"

    set +e
    "$SCRIPT_DIR/compare_benchmark.sh" \
        "$BASELINE" "$candidate" "$case_dir" "$name" "$BASE_SHA" "$HEAD_SHA" "$CHANGE_NOTE"
    status=$?
    set -e
    actual_verdict="$(jq -r '.verdict' "$case_dir/comparison.json")"
    if [[ "$actual_verdict" != "$expected_verdict" ]]; then
        echo "$name: expected $expected_verdict, got $actual_verdict (exit $status)" >&2
        exit 1
    fi
    echo "$name: $actual_verdict"
}

# inference, circuit, peak RAM, average RAM, CPU time, keygen, prediction, swap
run_case speed_memory_tradeoff auto_merge 670 570 20085000 17400000 3000 165 Handgun 0
run_case borderline_tradeoff manual_review 715 600 20475000 17800000 3050 165 Handgun 0
run_case excessive_ram rejected 650 550 21700000 18500000 3000 165 Handgun 0
run_case no_improvement rejected 745 624 19500000 17000000 3080 165 Handgun 0
run_case wrong_prediction rejected 680 580 19000000 16500000 2900 165 Knife 0
run_case memory_speed_tradeoff auto_merge 775 640 18330000 16000000 3000 165 Handgun 0

grep -Fq '#### Đã sửa gì' "$TMP_ROOT/speed_memory_tradeoff/readme-entry.md"
grep -Fq '#### Benchmark so với phiên bản dev trước' "$TMP_ROOT/speed_memory_tradeoff/readme-entry.md"

echo "All benchmark comparison tests passed."
