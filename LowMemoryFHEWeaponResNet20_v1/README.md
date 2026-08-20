# LowMemory FHE Weapon ResNet-20

Isolated workspace for adapting the encrypted CIFAR-style ResNet-20 to the
trained two-class weapon model.

## Included

- `src/` and `CMakeLists.txt`: independent copy of the original FHE code.
- `training/`: symlink to the trained weapon project. Its checkpoint is
  `training/outputs/best.pt`.
- `inputs/knife.png`: one 32x32 validation image for later end-to-end tests.
- `weights/`: intentionally empty. It will receive only weights exported from
  the weapon checkpoint, not the original CIFAR-10 weights.

## Adaptation status

Completed:

- `export_weapon_weights.py` loads `training/outputs/best.pt`, folds batch
  normalization, and reuses the reference packing algorithm to generate FHE
  `.bin` weights.
- The C++ final layer, class mapping, and FC weight packing use two classes:
  `0 = Handgun`, `1 = Knife`.
- The FC bias is exported and added after the FHE FC layer.
- Input handling rejects anything but 32x32 RGB and uses the training
  normalization `(x - 0.5) / 0.5`.

## Next commands

## FHE-aware retraining

The original checkpoint exceeds the FHE ReLU domain and cannot be used for a
reliable encrypted evaluation. Retrain with the range penalty enabled, keeping
the new checkpoint separate from the original one:

```bash
cd /root/HE/LowMemoryFHEResNet20/weapon-resnet20-training
/root/HE/LowMemoryFHEWeaponResNet20/.venv/bin/python train_weapon.py \
  --epochs 150 \
  --batch-size 128 \
  --activation-bound 0.8 \
  --range-penalty 5.0 \
  --output-dir outputs_fhe
```

After training, inspect its activation ranges. The reported absolute maxima
must be brought close to the FHE approximation interval before export:

```bash
/root/HE/LowMemoryFHEWeaponResNet20/.venv/bin/python \
  /root/HE/LowMemoryFHEWeaponResNet20/calibrate_activation_ranges.py \
  --checkpoint training/outputs_fhe/best.pt
```

## Export and FHE execution

Install the Python export requirements, then generate weights from the
FHE-aware checkpoint:

```bash
cd /root/HE/LowMemoryFHEWeaponResNet20
./.venv/bin/python export_weapon_weights.py \
  --checkpoint training/outputs_fhe/best.pt
```

Build the FHE executable and generate its independent keys:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local
cmake --build build -j2
cd build
./LowMemoryFHEWeaponResNet20 generate_keys 1
```

Finally, run encrypted inference on the included validation image:

```bash
./LowMemoryFHEWeaponResNet20 load_keys 1 input inputs/knife.png verbose 1 plain
```

The plaintext and encrypted result should be compared before relying on the
encrypted prediction.

The original `LowMemoryFHEResNet20` project remains unchanged.
