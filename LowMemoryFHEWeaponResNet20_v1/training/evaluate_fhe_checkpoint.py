#!/usr/bin/env python3
"""Measure plaintext accuracy and FHE-relevant ReLU ranges for one checkpoint.

The program prints exactly one JSON object, so sweep_fhe_finetune.sh can append
the result to a CSV report without retaining another checkpoint copy.
"""

import argparse
import json
import math
from pathlib import Path

import torch
from torch.utils.data import DataLoader
from torchvision import datasets, transforms

from resnet20 import ResNet20


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--num-workers", type=int, default=2)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    class_to_idx = checkpoint["class_to_idx"]
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = ResNet20(num_classes=len(class_to_idx)).to(device)
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()

    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.5, 0.5, 0.5), (0.5, 0.5, 0.5)),
    ])
    dataset = datasets.ImageFolder(args.data_dir / "val", transform=transform)
    loader = DataLoader(
        dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
        pin_memory=torch.cuda.is_available(),
    )

    correct = total = outside_count = activation_count = 0
    max_abs = 0.0
    # torch.quantile cannot process tensors above its internal element limit.
    # Keep a deterministic, evenly spaced sample for q99.9 while max/outside
    # counts below are still computed exactly over every activation.
    quantile_samples = []
    max_samples_per_tensor = 200_000
    with torch.inference_mode():
        for images, labels in loader:
            logits, preactivations = model(images.to(device), return_preactivations=True)
            correct += (logits.argmax(dim=1).cpu() == labels).sum().item()
            total += labels.numel()
            for activation in preactivations:
                absolute = activation.detach().abs().flatten().cpu()
                max_abs = max(max_abs, absolute.max().item())
                outside_count += (absolute > 1.0).sum().item()
                activation_count += absolute.numel()
                stride = max(1, math.ceil(absolute.numel() / max_samples_per_tensor))
                quantile_samples.append(absolute[::stride])

    sampled_abs = torch.cat(quantile_samples)
    result = {
        "checkpoint": str(args.checkpoint),
        "checkpoint_val_accuracy": float(checkpoint.get("val_accuracy", -1.0)),
        "plaintext_accuracy": correct / total,
        "correct": correct,
        "total": total,
        "max_abs_preactivation": max_abs,
        "abs_q999": torch.quantile(sampled_abs, 0.999).item(),
        "abs_q999_sample_count": sampled_abs.numel(),
        "outside_minus1_1": outside_count,
        "activation_count": activation_count,
        "outside_minus1_1_percent": 100.0 * outside_count / activation_count,
        "checkpoint_bytes": args.checkpoint.stat().st_size,
    }
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
