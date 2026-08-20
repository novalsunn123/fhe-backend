#!/usr/bin/env bash
# Run a small, deliberate FHE fine-tuning sweep.  Each candidate starts from
# the same high-accuracy checkpoint; only one candidate checkpoint is kept.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

BASE_CHECKPOINT="${BASE_CHECKPOINT:-outputs_fhe/best.pt}"
DATA_DIR="${DATA_DIR:-data}"
CURRENT_DIR="${CURRENT_DIR:-outputs_fhe_sweep_current}"
REPORT_DIR="${REPORT_DIR:-fhe_sweep_results}"
PYTHON_BIN="${PYTHON_BIN:-$ROOT/../.venv/bin/python}"
BATCH_SIZE="${BATCH_SIZE:-128}"
NUM_WORKERS="${NUM_WORKERS:-0}"
SEED="${SEED:-42}"

[[ -f "$BASE_CHECKPOINT" ]] || { echo "Missing base checkpoint: $BASE_CHECKPOINT" >&2; exit 1; }
[[ -x "$PYTHON_BIN" ]] || { echo "Missing training Python: $PYTHON_BIN" >&2; exit 1; }
"$PYTHON_BIN" -c 'import numpy, torch, torchvision' || {
  echo "Training Python is missing numpy/torch/torchvision: $PYTHON_BIN" >&2
  exit 1
}
mkdir -p "$CURRENT_DIR" "$REPORT_DIR"

CSV="$REPORT_DIR/results.csv"
MD="$REPORT_DIR/results.md"
if [[ "${RESUME:-0}" != "1" ]]; then
  echo 'id,epochs,batch_size,lr,activation_bound,range_penalty,stem_range_penalty,checkpoint_val_accuracy,plaintext_accuracy,correct,total,max_abs_preactivation,abs_q999,outside_minus1_1,outside_minus1_1_percent,checkpoint_bytes,status' > "$CSV"
elif [[ ! -s "$CSV" ]]; then
  echo 'id,epochs,batch_size,lr,activation_bound,range_penalty,stem_range_penalty,checkpoint_val_accuracy,plaintext_accuracy,correct,total,max_abs_preactivation,abs_q999,outside_minus1_1,outside_minus1_1_percent,checkpoint_bytes,status' > "$CSV"
fi

# id | epochs | lr | activation bound | global range penalty | stem penalty
# The sweep moves from accuracy-preserving settings to very strict FHE-range
# settings. It also contains a few controlled variants to reveal whether LR,
# global penalty, or the stem penalty is responsible for a result.
CONFIGS=(
  # Control and light pressure: prioritize retaining plaintext accuracy.
  'control-060-p20-s40       20 0.0010 0.60  20  40'
  'light-070-p15-s60         25 0.0010 0.70  15  60'
  'light-065-p20-s60         25 0.0010 0.65  20  60'
  'light-065-p30-s100        30 0.0010 0.65  30 100'
  'light-060-p25-s80         30 0.0010 0.60  25  80'
  'light-060-p40-s120        30 0.0010 0.60  40 120'

  # Balanced pressure: likely accuracy/range trade-off candidates.
  'balanced-055-p30-s80      30 0.0010 0.55  30  80'
  'balanced-055-p45-s120     30 0.0010 0.55  45 120'
  'balanced-055-p60-s160     30 0.0010 0.55  60 160'
  'balanced-050-p30-s80      30 0.0010 0.50  30  80'
  'balanced-050-p45-s120     30 0.0010 0.50  45 120'
  'balanced-050-p60-s160     30 0.0010 0.50  60 160'

  # Learning-rate variants at the central setting.
  'balanced-050-lr0020       25 0.0020 0.50  45 120'
  'balanced-050-lr0008       35 0.0008 0.50  45 120'
  'balanced-050-lr0005       40 0.0005 0.50  45 120'

  # Strict pressure: target a much lower out-of-range rate.
  'strict-045-p45-s120       30 0.0010 0.45  45 120'
  'strict-045-p60-s120       30 0.0010 0.45  60 120'
  'strict-045-p60-s160       35 0.0008 0.45  60 160'
  'strict-045-p80-s160       35 0.0008 0.45  80 160'
  'strict-045-p100-s200      40 0.0005 0.45 100 200'

  # Stem ablation: determine how much first-layer pressure is useful.
  'stem-045-p60-s80          35 0.0008 0.45  60  80'
  'stem-045-p60-s200         35 0.0008 0.45  60 200'
  'stem-040-p80-s120         40 0.0005 0.40  80 120'
  'stem-040-p80-s240         40 0.0005 0.40  80 240'

  # Tight and ultra-tight: higher risk of accuracy loss, strongest FHE fit.
  'tight-040-p80-s160        40 0.0005 0.40  80 160'
  'tight-040-p100-s200       40 0.0005 0.40 100 200'
  'tight-040-p140-s240       45 0.0004 0.40 140 240'
  'tight-035-p100-s200       45 0.0005 0.35 100 200'
  'tight-035-p140-s240       45 0.0004 0.35 140 240'
  'ultra-035-p180-s300       50 0.0003 0.35 180 300'

  # Targeted follow-up around the most useful accuracy/range frontier.
  'target-0575-p35-s100      30 0.0015 0.575 35 100'
  'target-0575-p45-s140      30 0.0015 0.575 45 140'
  'target-0525-p35-s100      30 0.0015 0.525 35 100'
  'target-0525-p50-s140      30 0.0015 0.525 50 140'
  'target-0475-p45-s120      30 0.0015 0.475 45 120'
  'target-0475-p65-s160      35 0.0010 0.475 65 160'
  'target-0425-p65-s160      35 0.0010 0.425 65 160'
  'target-0425-p90-s200      40 0.0007 0.425 90 200'

  # Higher-LR variants: previous trials indicate they can reduce range faster.
  'fast-060-lr0020-p30-s100  25 0.0020 0.60  30 100'
  'fast-055-lr0020-p35-s120  25 0.0020 0.55  35 120'
  'fast-055-lr0030-p35-s120  30 0.0030 0.55  35 120'
  'fast-050-lr0025-p45-s120  30 0.0025 0.50  45 120'
  'fast-050-lr0030-p60-s160  30 0.0030 0.50  60 160'
  'fast-045-lr0020-p60-s160  35 0.0020 0.45  60 160'

  # Longer, low-LR consolidation variants.
  'long-055-lr0005-p60-s160  50 0.0005 0.55  60 160'
  'long-050-lr0004-p80-s180  50 0.0004 0.50  80 180'
  'long-045-lr0003-p100-s220 60 0.0003 0.45 100 220'
  'long-040-lr0003-p140-s280 60 0.0003 0.40 140 280'
)

# Dense follow-up matrix. These settings fill the gaps between the hand-picked
# candidates above. Penalty/stem pairs increase together, while three learning
# rates test slow consolidation, a balanced update, and faster range pressure.
DENSE_BOUNDS=(0.60 0.55 0.50 0.45 0.40 0.35)
DENSE_LRS=(0.0005 0.0015 0.0025)
DENSE_PENALTY_STEM=(
  '25 50'
  '50 100'
  '75 150'
  '100 200'
)

for dense_bound in "${DENSE_BOUNDS[@]}"; do
  bound_id="${dense_bound/./}"
  for dense_lr in "${DENSE_LRS[@]}"; do
    lr_id="${dense_lr/./}"
    for penalty_stem in "${DENSE_PENALTY_STEM[@]}"; do
      read -r dense_penalty dense_stem <<< "$penalty_stem"
      CONFIGS+=(
        "grid-b${bound_id}-lr${lr_id}-p${dense_penalty}-s${dense_stem} 35 ${dense_lr} ${dense_bound} ${dense_penalty} ${dense_stem}"
      )
    done
  done
done

# Boundary-focused cases test whether very small targets can eliminate the
# remaining out-of-range tail without completely destroying accuracy.
CONFIGS+=(
  'boundary-0325-p100-s200    50 0.0005 0.325 100 200'
  'boundary-0325-p140-s260    50 0.0004 0.325 140 260'
  'boundary-0325-p180-s320    60 0.0003 0.325 180 320'
  'boundary-0300-p120-s240    50 0.0005 0.300 120 240'
  'boundary-0300-p160-s300    60 0.0004 0.300 160 300'
  'boundary-0300-p220-s360    60 0.0003 0.300 220 360'
)

write_markdown() {
  {
    echo '# FHE fine-tuning sweep'
    echo
    echo "Base checkpoint: \`$BASE_CHECKPOINT\`"
    echo
    echo 'Only `outputs_fhe_sweep_current/best.pt` is retained. It is overwritten before each candidate; no per-candidate checkpoints are stored.'
    echo
    echo '| Candidate | Epochs | LR | Bound | Range penalty | Stem penalty | Plaintext accuracy | Max \|pre-ReLU\| | Outside [-1,1] | Status |'
    echo '|---|---:|---:|---:|---:|---:|---:|---:|---:|---|'
    tail -n +2 "$CSV" | while IFS=, read -r id epochs batch lr bound range stem ckpt_acc acc correct total max q999 outside outside_pct bytes status; do
      if [[ "$status" == "ok" && -n "$acc" ]]; then
        printf '| %s | %s | %s | %s | %s | %s | %.2f%% | %.6f | %.6f%% | %s |\n' \
          "$id" "$epochs" "$lr" "$bound" "$range" "$stem" \
          "$(awk "BEGIN {print $acc * 100}")" "$max" "$outside_pct" "$status"
      else
        printf '| %s | %s | %s | %s | %s | %s | — | — | — | %s |\n' \
          "$id" "$epochs" "$lr" "$bound" "$range" "$stem" "$status"
      fi
    done
  } > "$MD"
}

for config in "${CONFIGS[@]}"; do
  read -r id epochs lr bound range_penalty stem_penalty <<< "$config"

  # A resumed sweep appends only missing/failed candidates. Successful IDs
  # already present in results.csv are never trained or recorded twice.
  if [[ "${RESUME:-0}" == "1" ]] && awk -F, -v candidate="$id" \
      '$1 == candidate { status=$17; sub(/\r$/, "", status); if (status == "ok") found=1 }
       END { exit !found }' "$CSV"; then
    echo "Skipping completed candidate: $id"
    continue
  fi

  echo
  echo "===== $id | bound=$bound range=$range_penalty stem=$stem_penalty lr=$lr ====="

  # train_weapon.py itself writes best.pt and last.pt. Remove only these known
  # files so storage remains bounded at one retained checkpoint.
  rm -f "$CURRENT_DIR/best.pt" "$CURRENT_DIR/last.pt" "$CURRENT_DIR/class_to_idx.json"

  if ! "$PYTHON_BIN" train_weapon.py \
    --data-dir "$DATA_DIR" \
    --output-dir "$CURRENT_DIR" \
    --init-checkpoint "$BASE_CHECKPOINT" \
    --epochs "$epochs" \
    --batch-size "$BATCH_SIZE" \
    --lr "$lr" \
    --num-workers "$NUM_WORKERS" \
    --seed "$SEED" \
    --activation-bound "$bound" \
    --range-penalty "$range_penalty" \
    --stem-range-penalty "$stem_penalty"; then
    echo "$id,$epochs,$BATCH_SIZE,$lr,$bound,$range_penalty,$stem_penalty,,,,,,,,,,train_failed" >> "$CSV"
    write_markdown
    continue
  fi

  metrics="$("$PYTHON_BIN" evaluate_fhe_checkpoint.py \
    --checkpoint "$CURRENT_DIR/best.pt" \
    --data-dir "$DATA_DIR" \
    --batch-size "$BATCH_SIZE" \
    --num-workers "$NUM_WORKERS")"

  "$PYTHON_BIN" - "$CSV" "$id" "$epochs" "$BATCH_SIZE" "$lr" "$bound" "$range_penalty" "$stem_penalty" "$metrics" <<'PY'
import csv
import json
import sys

csv_path, candidate, epochs, batch_size, lr, bound, penalty, stem_penalty, metrics = sys.argv[1:]
m = json.loads(metrics)
with open(csv_path, "a", newline="", encoding="utf-8") as handle:
    csv.writer(handle).writerow([
        candidate, epochs, batch_size, lr, bound, penalty, stem_penalty,
        m["checkpoint_val_accuracy"], m["plaintext_accuracy"], m["correct"], m["total"],
        m["max_abs_preactivation"], m["abs_q999"], m["outside_minus1_1"],
        m["outside_minus1_1_percent"], m["checkpoint_bytes"], "ok",
    ])
PY
  rm -f "$CURRENT_DIR/last.pt"
  write_markdown
  echo "Recorded: $REPORT_DIR/results.csv"
done

write_markdown
echo
echo "Finished. Reports: $CSV and $MD"
echo "Retained checkpoint only: $CURRENT_DIR/best.pt (the final candidate)."
echo "Use the report to select a configuration, then rerun that one configuration to produce the final selected checkpoint."
