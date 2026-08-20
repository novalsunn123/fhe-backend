# FHE batch test

Run six random, previously untested training images (three per class):

```bash
cd "/root/HE copy/FHEBatchTest"
./run_test.sh
```

Optional arguments are Handgun count, keyset, dataset split, and Knife count:

```bash
./run_test.sh 3 1 train
./run_test.sh 10 1 val 20
```

For a meaningful 40-image validation run (20 images per class):

```bash
./run_test.sh 20 1 val
```

Every attempted image is appended to `tested_images_<split>.txt`, so later runs
do not select it again. Results are written to `results/run_<timestamp>.csv`.
Each CSV row includes encryption, server inference, decryption, and total wall
time in seconds. If CKKS decryption fails because its approximation error is
too high, the row is marked `decrypt_error`, excluded from accuracy, and a new
untested image from the same class is queued as its replacement. The run ends
only after the requested number of decryptable samples has been collected. The
final summary reports valid-sample accuracy, all-attempt accuracy, replacement
count, and min/average/max inference time.

The test is sequential because the server reuses its checkpoint files and FHE
inference consumes significant RAM.

## Full validation using staged batches

`run_full_val_staged.sh` uses `FHEBackend-batch-limit` and processes all 190
validation images with `FHEServer infer_batch`. The default is 19 batches of 10
images. Results are committed to `results.csv` after every decrypted image, so
an interrupted run can continue without repeating completed images.

Check binaries, packed weights, keys, dataset, RAM, and disk without inference:

```bash
./run_full_val_staged.sh --check 10 1
```

Start a new run or resume an interrupted one:

```bash
./run_full_val_staged.sh 10 1
./run_full_val_staged.sh --resume "/absolute/path/to/staged_full_val_run"
```

The runner requires 18 GiB available RAM by default because measured inference
peak RSS is about 18.7 GiB. `FHE_ALLOW_LOW_MEMORY=1` bypasses this guard but can
cause heavy swapping, an OOM failure, or loss of the current batch.
