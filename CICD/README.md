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
