"""ResNet-20 for 32x32 RGB image classification."""

import torch
from torch import nn


class BasicBlock(nn.Module):
    expansion = 1

    def __init__(self, in_channels: int, channels: int, stride: int = 1) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, channels, 3, stride, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(channels)
        self.conv2 = nn.Conv2d(channels, channels, 3, 1, 1, bias=False)
        self.bn2 = nn.BatchNorm2d(channels)
        self.shortcut = nn.Identity()
        if stride != 1 or in_channels != channels:
            self.shortcut = nn.Sequential(
                nn.Conv2d(in_channels, channels, 1, stride, bias=False),
                nn.BatchNorm2d(channels),
            )

    def forward(self, x: torch.Tensor, return_preactivations: bool = False):
        residual = self.shortcut(x)
        pre_activation_1 = self.bn1(self.conv1(x))
        x = torch.relu(pre_activation_1)
        pre_activation_2 = self.bn2(self.conv2(x)) + residual
        x = torch.relu(pre_activation_2)
        if return_preactivations:
            return x, (pre_activation_1, pre_activation_2)
        return x


class ResNet20(nn.Module):
    """CIFAR-style ResNet-20: 3 residual blocks in each of 3 stages."""

    def __init__(self, num_classes: int = 2) -> None:
        super().__init__()
        self.in_channels = 16
        self.stem = nn.Sequential(
            nn.Conv2d(3, 16, 3, 1, 1, bias=False),
            nn.BatchNorm2d(16),
            nn.ReLU(inplace=True),
        )
        self.layer1 = self._make_layer(16, blocks=3, stride=1)
        self.layer2 = self._make_layer(32, blocks=3, stride=2)
        self.layer3 = self._make_layer(64, blocks=3, stride=2)
        self.pool = nn.AdaptiveAvgPool2d((1, 1))
        self.fc = nn.Linear(64, num_classes)
        self._initialize_weights()

    def _make_layer(self, channels: int, blocks: int, stride: int) -> nn.Sequential:
        layers = [BasicBlock(self.in_channels, channels, stride)]
        self.in_channels = channels
        layers.extend(BasicBlock(channels, channels) for _ in range(blocks - 1))
        return nn.Sequential(*layers)

    def _initialize_weights(self) -> None:
        for module in self.modules():
            if isinstance(module, nn.Conv2d):
                nn.init.kaiming_normal_(module.weight, mode="fan_out", nonlinearity="relu")
            elif isinstance(module, nn.BatchNorm2d):
                nn.init.ones_(module.weight)
                nn.init.zeros_(module.bias)
            elif isinstance(module, nn.Linear):
                nn.init.normal_(module.weight, 0, 0.01)
                nn.init.zeros_(module.bias)

    def forward(self, x: torch.Tensor, return_preactivations: bool = False):
        preactivations = []
        pre_activation = self.stem[1](self.stem[0](x))
        if return_preactivations:
            preactivations.append(pre_activation)
        x = self.stem[2](pre_activation)
        for layer in (self.layer1, self.layer2, self.layer3):
            for block in layer:
                if return_preactivations:
                    x, block_preactivations = block(x, return_preactivations=True)
                    preactivations.extend(block_preactivations)
                else:
                    x = block(x)
        x = self.pool(x).flatten(1)
        logits = self.fc(x)
        if return_preactivations:
            return logits, preactivations
        return logits
