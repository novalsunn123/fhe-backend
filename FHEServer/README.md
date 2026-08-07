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

## Operation profiler

FHEServer can emit context/key-loading, layer, residual-block, convolution,
activation, downsample, and bootstrap timings without changing the FHE circuit.
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
