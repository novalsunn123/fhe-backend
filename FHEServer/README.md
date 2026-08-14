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
