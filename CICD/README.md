# Development CI benchmark

Every push to `dev` runs a clean end-to-end FHE benchmark on the registered
self-hosted runner:

1. configure and compile `FHEClient` and `FHEServer` in Release mode;
2. generate a fresh experiment-1 client keyset and server evaluation package;
3. verify that the server package contains no secret key;
4. encrypt the tracked 32x32 RGB test image;
5. transfer the ciphertext and run one encrypted ResNet-20 inference;
6. return and decrypt the encrypted logits;
7. publish per-phase timing and resource metrics.

The report starts with a compact source-code benchmark table covering key
generation time, encryption/decryption time, inference and FHE circuit time,
per-layer time, prediction, and average/peak CPU and RAM for key generation
and inference. `pidstat` samples those two compute-heavy phases once per
second; GNU `time -v` remains the source for wall time, average CPU, and peak
RSS.

The GitHub Actions job summary associates the benchmark with the commit SHA,
branch, actor, and commit subject. Detailed CSV metrics and text logs are
uploaded as a workflow artifact and retained in the runner's external report
directory.

Keys, ciphertexts, encrypted results, and checkpoints are generated only in
the Actions checkout and removed on every exit path. The report never includes
key material. Model weights are provisioned once on the runner outside the Git
repository.

The benchmark intentionally fails when another `FHEServer infer` process is
already running, when available RAM or disk is below the safety threshold, or
when decryption fails. Jobs are serialized and are not automatically canceled
so key-generation cleanup can finish.

## Staged 10-image benchmark

`dev-fhe-batch10-baseline.yml` measures layer-major, disk-backed multi-image
inference against the tracked deterministic `CICD/benchmark10-images.tsv` set:
five Handgun and five Knife validation images. The workflow builds once,
generates and transfers one keyset, encrypts all ten images, invokes one
`FHEServer infer_batch` process, and then decrypts all ten results. The server
loads each layer's rotation-key set once and stores only encrypted intermediate
checkpoints between stages.

The report directory contains:

- `batch10-summary.md`: compact aggregate and per-image table;
- `batch10-benchmark.json`: machine-readable baseline for later comparison;
- `batch10-results.csv`: logits, prediction, timing, CPU/RAM/swap per image;
- `batch10-phase-metrics.csv`: GNU time and one-second `/proc` samples;
- `profiles/batch`: aggregate operation-level FHEServer profile;
- `batch10-server-metrics.tsv`: per-image circuit and layer compute time.

A successful `dev` run writes the external baseline to
`/home/fhe-runner/CICD/state/dev-batch10-baseline.json`. Generated keys and
ciphertexts and intermediate checkpoints are removed on exit. The workflow has
a separate 240-minute timeout and its own `fhe-benchmark-batch10` concurrency
group. The machine has
one self-hosted runner, so batch and single-image jobs remain sequential, while
new pull-request events can no longer replace a pending batch run.

Before the initial baseline is merged, the workflow also accepts pushes from
the exact bootstrap branch `agent/rotation-key-audit`. That branch run uploads
the same report but cannot update `dev-batch10-baseline.json`; only a successful
run whose ref is exactly `refs/heads/dev` installs the comparison baseline.

## Agent performance review

Ordinary agent work uses an `agent/<task-slug>` branch and a pull request into
`dev`. `agent-performance-gate.yml` executes the candidate with benchmark tools
from the trusted base commit, compares its machine-readable `benchmark.json`
against `/home/fhe-runner/CICD/state/dev-baseline.json`, and keeps write access
out of the benchmark job.

The comparison has two outcomes:

- `manual_review`: both runs completed and the environment is comparable;
- `not_comparable`: the baseline SHA, benchmark environment, or required metric
  does not match.

The report shows prediction, timing, CPU, RAM, and swap deltas but applies no
performance rejection threshold, improvement threshold, or trade-off policy.
It never labels a candidate as improved or regressed. Automatic promotion is
disabled: CI never merges the pull request or writes to `dev`. The user reviews
the report and decides manually whether and how to merge the PR.

### Bootstrap

After installing or changing benchmark policy, manually commit and push the
trusted maintenance files to `dev`. The existing dev workflow runs once and
creates the schema-1 baseline used for subsequent manual comparisons.

### Agent commands

Start from a clean worktree:

```bash
./CICD/agent_start.sh reduce-rotation-memory
```

After the agent finishes the requested source change, export a fine-grained
token with pull-request write access without saving it in the repository, then
submit:

```bash
cp CICD/change-note-template.md .agent-change-note.md
# Edit .agent-change-note.md before submitting.
export GITHUB_AGENT_TOKEN='...'
./CICD/agent_submit.sh \
  'perf: reduce rotation key memory' \
  .agent-change-note.md \
  'perf: reduce rotation key memory'
unset GITHUB_AGENT_TOKEN
```

The change-note file is used as the pull-request body and must contain these
exact headings (the text below them may be written in Vietnamese):

```markdown
## Đã sửa gì

...

## Cơ chế

...

## Cách hoạt động

...

## Lợi ích

...
```

The submit script rejects generated/heavy files and trusted-policy changes,
builds both binaries, commits, pushes, and opens the PR. The full FHE benchmark
then runs on the self-hosted runner.

Run the comparison policy tests with:

```bash
./CICD/tests/test_compare_benchmark.sh
./CICD/tests/test_readme_history.sh
```
