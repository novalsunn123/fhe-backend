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

## Agent performance promotion

Ordinary agent work uses an `agent/<task-slug>` branch and a pull request into
`dev`. `agent-performance-gate.yml` executes the candidate with benchmark tools
from the trusted base commit, compares its machine-readable `benchmark.json`
against `/home/fhe-runner/CICD/state/dev-baseline.json`, and keeps write access
out of the benchmark job.

The gate has four outcomes:

- `auto_merge`: at least one primary metric improved and all regressions or
  speed/memory trade-offs are within policy;
- `manual_review`: correctness passed, but the change is stable without a
  primary improvement or has a trade-off outside automatic promotion limits;
- `rejected`: correctness, safety, or regression limits failed;
- `not_comparable`: the baseline SHA or benchmark environment changed.

Peak swap is recorded in the benchmark comparison for observability, but it
does not affect the promotion verdict. RAM safety continues to be enforced by
the inference and key-generation peak-RSS limits. A manual-review verdict keeps
the benchmark check successful but never triggers the automatic promotion job.

An eligible candidate is squash-merged by a separate promotion job. The new
code commit title includes inference and peak-RAM deltas, while its body holds
the full baseline/candidate table. Promotion then creates one documentation-only
commit that inserts a version entry at the top of the root README history. That
entry records what changed, the mechanism, how it works, its benefit, prediction,
and the benchmark delta. The runner baseline advances to this documentation
commit, which becomes the exact base of the next candidate. A stale baseline
can never be promoted.

The README update uses the workflow token and therefore does not start another
push workflow. It is intentionally performed only after a successful benchmark;
rejected candidates never appear in the dev history.

### Bootstrap

After installing or changing benchmark policy, manually commit and push the
trusted maintenance files to `dev`. The existing dev workflow runs once and
creates the first schema-1 baseline. Candidate PRs remain blocked until that
successful bootstrap exists.

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
