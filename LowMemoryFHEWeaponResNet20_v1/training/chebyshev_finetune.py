#!/usr/bin/env python3
"""Fine-tune ResNet-20 with a differentiable Chebyshev ReLU surrogate.

The surrogate uses the same target interval as the OpenFHE activation.  It is
only a plaintext training/evaluation program: it never creates keys or runs
encrypted inference.
"""

import argparse
import json
import math
import random
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms

from resnet20 import ResNet20


MEAN = (0.5, 0.5, 0.5)
STD = (0.5, 0.5, 0.5)


class ChebyshevRelu(nn.Module):
    def __init__(self, degree: int) -> None:
        super().__init__()
        if degree < 1 or degree % 2 == 0:
            raise ValueError("degree must be a positive odd integer")
        samples = np.linspace(-1.0, 1.0, 4097)
        coefficients = np.polynomial.chebyshev.chebfit(samples, np.maximum(samples, 0.0), degree)
        self.register_buffer("coefficients", torch.tensor(coefficients, dtype=torch.float32))

    def forward(self, values: torch.Tensor) -> torch.Tensor:
        # A high-degree Chebyshev polynomial diverges rapidly beyond [-1, 1].
        # The straight-through clamp keeps training finite while the separate
        # range loss teaches the real pre-activations to stay in that interval.
        # OpenFHE still evaluates the unclamped ciphertext, hence range metrics
        # remain a release gate rather than being hidden by this surrogate.
        bounded = values + (values.clamp(-1.0, 1.0) - values).detach()
        result = self.coefficients[0] + self.coefficients[1] * bounded
        previous, current = torch.ones_like(bounded), bounded
        for coefficient in self.coefficients[2:]:
            following = 2.0 * bounded * current - previous
            result = result + coefficient * following
            previous, current = current, following
        return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=15)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--activation-bound", type=float, default=0.55)
    parser.add_argument("--range-penalty", type=float, default=35.0)
    parser.add_argument("--stem-range-penalty", type=float, default=120.0)
    parser.add_argument("--degree", type=int, default=59)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--num-workers", type=int, default=2)
    return parser.parse_args()


def make_loader(root: Path, split: str, batch_size: int, workers: int, training: bool) -> DataLoader:
    transforms_list = []
    if training:
        transforms_list.extend([
            transforms.RandomHorizontalFlip(),
            transforms.RandomAffine(degrees=10, translate=(0.05, 0.05), scale=(0.9, 1.1)),
            transforms.ColorJitter(brightness=0.15, contrast=0.15, saturation=0.1),
        ])
    transforms_list.extend([transforms.ToTensor(), transforms.Normalize(MEAN, STD)])
    return DataLoader(datasets.ImageFolder(root / split, transform=transforms.Compose(transforms_list)),
                      batch_size=batch_size, shuffle=training, num_workers=workers,
                      pin_memory=torch.cuda.is_available())


def forward_metrics(model: nn.Module, loader: DataLoader, device: torch.device, bound: float,
                    optimizer: torch.optim.Optimizer | None = None,
                    range_penalty: float = 0.0, stem_range_penalty: float = 0.0):
    training = optimizer is not None
    model.train(training)
    correct = total = 0
    loss_sum = range_sum = stem_sum = 0.0
    with torch.set_grad_enabled(training):
        for images, labels in loader:
            images, labels = images.to(device), labels.to(device)
            logits, preactivations = model(images, return_preactivations=True)
            penalties = [torch.relu(value.abs() - bound).square().mean() for value in preactivations]
            range_loss = torch.stack(penalties).mean()
            stem_loss = penalties[0]
            loss = nn.functional.cross_entropy(logits, labels) + range_penalty * range_loss + stem_range_penalty * stem_loss
            if training:
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                optimizer.step()
            correct += (logits.argmax(dim=1) == labels).sum().item()
            total += labels.numel()
            loss_sum += loss.detach().item() * labels.numel()
            range_sum += range_loss.detach().item() * labels.numel()
            stem_sum += stem_loss.detach().item() * labels.numel()
    return {"accuracy": correct / total, "loss": loss_sum / total,
            "range_penalty": range_sum / total, "stem_penalty": stem_sum / total,
            "correct": correct, "total": total}


def portable_state_dict(model: nn.Module) -> dict:
    """Drop fixed surrogate coefficients so outputs load in the deployed ReLU model."""
    return {name: value for name, value in model.state_dict().items()
            if not name.endswith(".coefficients")}


def main() -> None:
    args = parse_args()
    random.seed(args.seed); np.random.seed(args.seed); torch.manual_seed(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    checkpoint = torch.load(args.checkpoint, map_location=device, weights_only=False)
    classes = checkpoint["class_to_idx"]
    factory = lambda: ChebyshevRelu(args.degree)
    model = ResNet20(len(classes), activation_factory=factory).to(device)
    missing, unexpected = model.load_state_dict(checkpoint["model_state_dict"], strict=False)
    if unexpected or any(not name.endswith(".coefficients") for name in missing):
        raise RuntimeError(f"Checkpoint is incompatible; missing={missing}, unexpected={unexpected}")
    train_loader = make_loader(args.data_dir, "train", args.batch_size, args.num_workers, True)
    val_loader = make_loader(args.data_dir, "val", args.batch_size, args.num_workers, False)
    optimizer = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=5e-4, nesterov=True)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    best = {"accuracy": -1.0}
    history = []
    for epoch in range(1, args.epochs + 1):
        train = forward_metrics(model, train_loader, device, args.activation_bound, optimizer,
                                args.range_penalty, args.stem_range_penalty)
        val = forward_metrics(model, val_loader, device, args.activation_bound)
        scheduler.step()
        record = {"epoch": epoch, "train": train, "surrogate_validation": val}
        history.append(record)
        if val["accuracy"] > best["accuracy"]:
            best = val | {"epoch": epoch}
            torch.save({"model_state_dict": portable_state_dict(model), "class_to_idx": classes,
                        "val_accuracy": val["accuracy"], "surrogate_degree": args.degree,
                        "activation_bound": args.activation_bound, "range_penalty": args.range_penalty,
                        "stem_range_penalty": args.stem_range_penalty}, args.output_dir / "best.pt")
        print(json.dumps(record, separators=(",", ":")), flush=True)
    exact = ResNet20(len(classes)).to(device)
    exact.load_state_dict(torch.load(args.output_dir / "best.pt", map_location=device, weights_only=False)["model_state_dict"])
    exact_metrics = forward_metrics(exact, val_loader, device, args.activation_bound)
    report = {"status": "passed", "device": str(device), "source_checkpoint": str(args.checkpoint),
              "settings": vars(args), "best_surrogate_validation": best,
              "exact_relu_validation": exact_metrics, "history": history}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
    print(json.dumps(report, separators=(",", ":"), default=str))


if __name__ == "__main__":
    main()
