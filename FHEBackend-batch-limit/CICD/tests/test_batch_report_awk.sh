#!/usr/bin/env bash
set -Eeuo pipefail

maximum="$(awk -v first=19567528 -v second=19567000 \
    'BEGIN {print (first > second ? first : second)}')"
[[ "$maximum" == "19567528" ]]

fixture="$(mktemp)"
staged_metrics="$(mktemp)"
trap 'rm -f "$fixture" "$staged_metrics"' EXIT
printf '%s\n' \
    'index,image,true_class,handgun_logit,knife_logit,prediction,correct,encrypt_seconds,inference_seconds,decrypt_seconds,total_seconds,circuit_seconds,layer1_seconds,layer2_seconds,layer3_seconds,inference_average_cpu_percent,inference_peak_cpu_percent,inference_average_rss_kb,inference_peak_rss_kb,inference_peak_swap_kb,status' \
    '1,FHEClient/inputs/test.png,Handgun,4.4,-4.4,Handgun,1,0.688,753.618,2.744,757.100,617.726,100.231,216.139,261.434,424.05,1128.41,15037404,19546500,92160,passed' \
    > "$fixture"
attempted="$(awk 'END {print (NR > 0 ? NR-1 : 0)}' "$fixture")"
[[ "$attempted" == "1" ]]

accuracy="$(awk -v correct=9 -v total=10 \
    'BEGIN {printf "%.2f", (total ? 100*correct/total : 0)}')"
[[ "$accuracy" == "90.00" ]]

read -r inference_average inference_min inference_max peak_cpu peak_rss <<< "$(
    awk -F, 'NR>1 && $21=="passed" {
        n++; sum+=$9
        if (n==1 || $9<minimum) minimum=$9
        if (n==1 || $9>maximum) maximum=$9
        if ($17>cpu_peak) cpu_peak=$17
        if ($19>rss_peak) rss_peak=$19
    } END {printf "%.3f %.3f %.3f %.2f %.0f",sum/n,minimum,maximum,cpu_peak,rss_peak}' \
        "$fixture"
)"
[[ "$inference_average" == "753.618" ]]
[[ "$inference_min" == "753.618" && "$inference_max" == "753.618" ]]
[[ "$peak_cpu" == "1128.41" && "$peak_rss" == "19546500" ]]

printf '%s\n' \
    $'index\tinput\toutput\tcircuit_seconds\tlayer1_seconds\tlayer2_seconds\tlayer3_seconds\tfinal_seconds' \
    $'1\tinput-01.bin\tresult-01.bin\t410.250000\t81.000000\t145.000000\t170.000000\t14.250000' \
    > "$staged_metrics"
metric_line="$(awk -F'\t' -v image_index=1 'NR>1 && $1==image_index {print; exit}' "$staged_metrics")"
IFS=$'\t' read -r metric_index _ _ circuit layer1 layer2 layer3 final <<< "$metric_line"
[[ "$metric_index" == "1" && "$circuit" == "410.250000" ]]
[[ "$layer1" == "81.000000" && "$layer2" == "145.000000" ]]
[[ "$layer3" == "170.000000" && "$final" == "14.250000" ]]

amortized="$(awk -v total=4200 -v count=10 'BEGIN {printf "%.3f", total/count}')"
[[ "$amortized" == "420.000" ]]

echo "Batch report awk portability test passed."
