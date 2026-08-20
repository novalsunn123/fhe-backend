# FHE Server

Copy the client's `server_keys_exp1` directory here as `keys_exp1`. The server
directory must not contain `secret-key.txt`.

Run from `FHEServer/build`:

```bash
cmake -S .. -B . -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local
cmake --build . -j2

./FHEServer infer 1 \
  ../ciphertexts/encrypted-input.bin \
  ../results/encrypted-result.bin
```

Return `encrypted-result.bin` to the client. The server does not decrypt it.

## Staged multi-image inference

For multiple ciphertexts, `infer_batch` processes the workload layer by layer so
each rotation-key set is deserialized once. The tab-separated manifest has no
header and contains one input/output pair per line:

```text
../ciphertexts/01-input.bin\t../results/01-result.bin
../ciphertexts/02-input.bin\t../results/02-result.bin
```

Run from `FHEServer/build` with an empty checkpoint directory:

```bash
./FHEServer infer_batch 1 \
  ../batch-jobs.tsv \
  ../checkpoints/batch \
  ../results/batch-metrics.tsv 1
```

Intermediate ciphertexts are serialized per image between key stages and
deleted immediately after the next stage consumes them. The metrics TSV reports
per-image circuit and layer time. This mode does not receive a secret key and
does not change CKKS parameters, model weights, data layout, bootstrapping
placement, or the order of homomorphic operations within an image.

The default safety limit is 20 images per batch. A larger manifest is rejected
before any rotation-key file is loaded. Operators may deliberately override the
limit, up to the hard maximum of 1000, for a controlled environment:

```bash
FHE_BATCH_MAX_IMAGES=40 ./FHEServer infer_batch 1 \
  ../batch-jobs.tsv ../checkpoints/batch ../results/batch-metrics.tsv 1
```

For the current 24 GB host, batches of 10 are recommended for CI and batches of
10–20 for full-validation jobs. Splitting a large dataset limits checkpoint and
profiler growth and reduces the amount of work lost if a long process fails.

`weights` currently points to the original project's exported weights to avoid
duplicating about 1.3 GB. Replace the symlink with a copied `weights/` directory
when deploying the server to another machine.

## Packed binary weights

The Release build packs all text files under `weights/` into
`build/packed-weights.bin`. FHEServer reads that indexed binary archive by
default, avoiding thousands of text-file opens and numeric conversions during
the FHE circuit. The generated archive is build output and is not committed.

Use `FHE_BINARY_WEIGHTS=0` to retain the legacy text reader for comparison.
Use `FHE_BINARY_WEIGHTS=1` to require the archive and fail instead of falling
back. `FHE_PACKED_WEIGHTS=/path/to/archive.bin` overrides the default archive.

## Operation profiler

FHEServer can emit context/key-loading, layer, residual-block, convolution,
activation, downsample, and bootstrap timings without changing the FHE circuit.
The convolution breakdown separately measures weight-file open/read/text parse,
plaintext encoding, rotation precomputation, every fast/regular rotation,
plaintext multiplication, ciphertext addition, and `EvalAddMany`. JSON schema 3
contains aggregate count/total/average/maximum values while CSV retains every
individual event and its layer/block context.

It also records the active rotation-key file and signed rotation
index for every application-level rotation. The Markdown report compares the
observed indices with the shared key-generation schedule in
`Common/RotationKeySchedule.h`. Missing indices are reported only as candidates
for a later pruning experiment; inference never removes keys automatically.

The shared schedule omits rotation index `2` from the layer 2 and layer 3
downsample key sets. A complete profiled inference observed no application use
of those two keys, while the downsample sets contain no bootstrapping keys.
Regenerate the client/server evaluation keys after changing this schedule.

Profiling is disabled by default. Enable it with:

```bash
FHE_PROFILE=1 FHE_PROFILE_DIR=/tmp/fhe-profile \
  ./FHEServer infer 1 ../ciphertexts/encrypted-input.bin \
  ../results/encrypted-result.bin 2
```

When `CICD_REPORT_DIR` is present, profiling is enabled automatically unless
`FHE_PROFILE=0` is set. The output directory receives
`fhe-operation-profile.md`, `fhe-operation-profile.json`, and
`fhe-operation-events.csv`. Process CPU/RAM/swap and decrypted prediction data
remain in the trusted CI reports because FHEServer has no secret key.
