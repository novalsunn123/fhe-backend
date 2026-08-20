# Weapon ResNet-20 training

This standalone project trains a two-class CIFAR-style ResNet-20 on 32x32 RGB weapon crops.

Classes are determined alphabetically by the data folders:

```text
0 = Handgun
1 = Knife
```

The dataset has already been prepared from YOLO bounding boxes. Each weapon was cropped as a square with side `max(box_width, box_height) * 1.30`, then resized to 32x32.

```text
data/
  train/
    Handgun/  # 2,283 images
    Knife/    # 2,178 images
  val/
    Handgun/  # 100 images
    Knife/    # 90 images
```

## Run locally

Install the dependencies appropriate for your CPU/GPU, then run:

```bash
pip install -r requirements.txt
python train_weapon.py --epochs 100 --batch-size 128
```

The best checkpoint is saved to `outputs/best.pt`; the final checkpoint is `outputs/last.pt`. `outputs/class_to_idx.json` preserves the output-class mapping.

## Google Colab

1. Zip the whole `weapon-resnet20-training` folder and upload the ZIP to Google Drive. Do not move individual class folders after zipping.
2. Open [Google Colab](https://colab.research.google.com/), then choose **Runtime → Change runtime type → T4 GPU**.
3. Run this setup cell, replacing the ZIP path if necessary:

```python
from google.colab import drive
drive.mount('/content/drive')

!unzip -q "/content/drive/MyDrive/weapon-resnet20-training.zip" -d /content
%cd /content/weapon-resnet20-training
!pip -q install -r requirements.txt
```

4. Train the model:

```python
!python train_weapon.py --epochs 100 --batch-size 128 --num-workers 2 --output-dir outputs
```

5. Copy the best model back to Drive:

```python
!cp outputs/best.pt /content/drive/MyDrive/weapon-resnet20-best.pt
!cp outputs/class_to_idx.json /content/drive/MyDrive/weapon-class-to-idx.json
```

The data currently contains only `Handgun` and `Knife`. It cannot classify images with no weapon until a `non_weapon` class is added and the model is retrained.
