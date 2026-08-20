"""Report pre-ReLU activation ranges for a trained weapon ResNet-20.

Run from this portable training directory, for example:
    python calibrate_activation_ranges.py --checkpoint outputs/best.pt
"""

import argparse
from collections import defaultdict
from pathlib import Path

import torch
from PIL import Image
from torchvision import transforms

from resnet20 import ResNet20


ROOT = Path(__file__).resolve().parent


def record(stats, name, value):
    stats[name].append(value.detach().flatten().cpu())


def relu_inputs(model, x, stats):
    pre = model.stem[1](model.stem[0](x))
    record(stats, "stem", pre)
    x = torch.relu(pre)
    for stage_name, stage in (("layer1", model.layer1), ("layer2", model.layer2), ("layer3", model.layer3)):
        for block_index, block in enumerate(stage):
            pre1 = block.bn1(block.conv1(x))
            record(stats, f"{stage_name}.{block_index}.conv1", pre1)
            middle = torch.relu(pre1)
            pre2 = block.bn2(block.conv2(middle)) + block.shortcut(x)
            record(stats, f"{stage_name}.{block_index}.residual", pre2)
            x = torch.relu(pre2)
    return model.fc(model.pool(x).flatten(1))


def main():
    parser = argparse.ArgumentParser(description="Report pre-ReLU activation ranges.")
    parser.add_argument("--checkpoint", type=Path, default=ROOT / "outputs" / "best.pt")
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = ResNet20(num_classes=len(checkpoint["class_to_idx"]))
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.5, 0.5, 0.5), (0.5, 0.5, 0.5)),
    ])
    image_paths = sorted((args.data_dir / "val").glob("*/*"))
    stats = defaultdict(list)
    with torch.no_grad():
        for image_path in image_paths:
            image = Image.open(image_path).convert("RGB")
            relu_inputs(model, transform(image).unsqueeze(0), stats)

    print(f"Calibrated on {len(image_paths)} validation images")
    print("layer\tmin\tmax\tabs-q99.9\tabs-max")
    for name, tensors in stats.items():
        values = torch.cat(tensors)
        absolute = values.abs()
        print(f"{name}\t{values.min().item():.4f}\t{values.max().item():.4f}\t"
              f"{torch.quantile(absolute, 0.999).item():.4f}\t{absolute.max().item():.4f}")


if __name__ == "__main__":
    main()
