"""Train a two-class ResNet-20 model on the prepared weapon crops."""

import argparse
import json
import random
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms
from tqdm.auto import tqdm

from resnet20 import ResNet20


MEAN = (0.5, 0.5, 0.5)
STD = (0.5, 0.5, 0.5)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train ResNet-20 for Handgun vs Knife classification.")
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--output-dir", type=Path, default=Path("outputs"))
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=0.1)
    parser.add_argument("--num-workers", type=int, default=2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--activation-bound", type=float, default=0.8,
                        help="Target absolute bound for inputs to every ReLU.")
    parser.add_argument("--range-penalty", type=float, default=0.0,
                        help="FHE-aware penalty strength; set above zero to train a bounded model.")
    parser.add_argument("--stem-range-penalty", type=float, default=0.0,
                        help="Extra range penalty for the first (stem) ReLU input.")
    parser.add_argument("--init-checkpoint", type=Path,
                        help="Optional checkpoint whose model weights are used to start fine-tuning.")
    return parser.parse_args()


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def make_loaders(data_dir: Path, batch_size: int, num_workers: int):
    train_transform = transforms.Compose([
        transforms.RandomHorizontalFlip(),
        transforms.RandomAffine(degrees=10, translate=(0.05, 0.05), scale=(0.9, 1.1)),
        transforms.ColorJitter(brightness=0.15, contrast=0.15, saturation=0.1),
        transforms.ToTensor(),
        transforms.Normalize(MEAN, STD),
    ])
    validation_transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize(MEAN, STD),
    ])
    train_set = datasets.ImageFolder(data_dir / "train", transform=train_transform)
    val_set = datasets.ImageFolder(data_dir / "val", transform=validation_transform)
    if train_set.classes != val_set.classes:
        raise ValueError(f"Train/validation classes differ: {train_set.classes} != {val_set.classes}")
    loader_options = {"num_workers": num_workers, "pin_memory": torch.cuda.is_available()}
    if num_workers > 0:
        loader_options["persistent_workers"] = True
    return (
        DataLoader(train_set, batch_size=batch_size, shuffle=True, **loader_options),
        DataLoader(val_set, batch_size=batch_size, shuffle=False, **loader_options),
        train_set.class_to_idx,
    )


def activation_range_penalty(preactivations, bound: float) -> tuple[torch.Tensor, torch.Tensor]:
    penalties = [torch.relu(value.abs() - bound).square().mean() for value in preactivations]
    return torch.stack(penalties).mean(), penalties[0]


def run_epoch(model, loader, criterion, device, optimizer=None, activation_bound=0.8,
              range_penalty=0.0, stem_range_penalty=0.0) -> tuple[float, float, float, float]:
    training = optimizer is not None
    model.train(training)
    total_loss = total_correct = total_examples = 0
    total_range_penalty = 0.0
    total_stem_penalty = 0.0
    iterator = tqdm(loader, leave=False, desc="train" if training else "validation")
    for images, labels in iterator:
        images, labels = images.to(device), labels.to(device)
        if training:
            optimizer.zero_grad(set_to_none=True)
        logits, preactivations = model(images, return_preactivations=True)
        penalty, stem_penalty = activation_range_penalty(preactivations, activation_bound)
        loss = criterion(logits, labels) + range_penalty * penalty + stem_range_penalty * stem_penalty
        if training:
            loss.backward()
            optimizer.step()
        total_loss += loss.item() * labels.size(0)
        total_range_penalty += penalty.item() * labels.size(0)
        total_stem_penalty += stem_penalty.item() * labels.size(0)
        total_correct += (logits.argmax(dim=1) == labels).sum().item()
        total_examples += labels.size(0)
    return (total_loss / total_examples, total_correct / total_examples,
            total_range_penalty / total_examples, total_stem_penalty / total_examples)


def main() -> None:
    args = parse_args()
    set_seed(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    train_loader, val_loader, class_to_idx = make_loaders(args.data_dir, args.batch_size, args.num_workers)
    model = ResNet20(num_classes=len(class_to_idx)).to(device)
    if args.init_checkpoint:
        checkpoint = torch.load(args.init_checkpoint, map_location=device, weights_only=False)
        if checkpoint["class_to_idx"] != class_to_idx:
            raise ValueError(f"Checkpoint class map differs: {checkpoint['class_to_idx']} != {class_to_idx}")
        model.load_state_dict(checkpoint["model_state_dict"])
        print(f"Fine-tuning from: {args.init_checkpoint}")
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=5e-4, nesterov=True)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "class_to_idx.json").write_text(json.dumps(class_to_idx, indent=2), encoding="utf-8")
    best_accuracy = -1.0
    print(f"Device: {device}; classes: {class_to_idx}; train: {len(train_loader.dataset)}; val: {len(val_loader.dataset)}")

    for epoch in range(1, args.epochs + 1):
        train_loss, train_accuracy, train_penalty, train_stem_penalty = run_epoch(
            model, train_loader, criterion, device, optimizer, args.activation_bound,
            args.range_penalty, args.stem_range_penalty
        )
        with torch.inference_mode():
            val_loss, val_accuracy, val_penalty, val_stem_penalty = run_epoch(
                model, val_loader, criterion, device, activation_bound=args.activation_bound
            )
        scheduler.step()
        checkpoint = {
            "epoch": epoch,
            "model_state_dict": model.state_dict(),
            "class_to_idx": class_to_idx,
            "image_size": 32,
            "normalization": {"mean": MEAN, "std": STD},
            "val_accuracy": val_accuracy,
            "activation_bound": args.activation_bound,
            "range_penalty": args.range_penalty,
            "stem_range_penalty": args.stem_range_penalty,
            "val_range_penalty": val_penalty,
        }
        torch.save(checkpoint, args.output_dir / "last.pt")
        if val_accuracy > best_accuracy:
            best_accuracy = val_accuracy
            torch.save(checkpoint, args.output_dir / "best.pt")
        print(
            f"Epoch {epoch:03d}/{args.epochs} | train loss {train_loss:.4f}, acc {train_accuracy:.2%}, "
            f"range {train_penalty:.5f}, stem {train_stem_penalty:.5f} | val loss {val_loss:.4f}, "
            f"acc {val_accuracy:.2%}, range {val_penalty:.5f}, stem {val_stem_penalty:.5f}"
        )
    print(f"Done. Best validation accuracy: {best_accuracy:.2%}. Checkpoint: {args.output_dir / 'best.pt'}")


if __name__ == "__main__":
    main()
