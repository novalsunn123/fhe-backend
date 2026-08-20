"""Export the trained two-class checkpoint to LowMemory FHE packed weights.

The original project supplies the packing algorithm as a notebook.  This
adapter reuses that algorithm while loading the local weapon checkpoint and
mapping its equivalent module names (stem/shortcut) to the notebook's names.
Run this script from any directory; packed weights are written to weights/.
"""

import json
import re
import sys
import argparse
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent
TRAINING_ROOT = PROJECT_ROOT / "training"
CHECKPOINT = TRAINING_ROOT / "outputs" / "best.pt"
ORIGINAL_NOTEBOOK = Path("/root/HE/LowMemoryFHEWeaponResNet20_v1/notebooks/Algorithm 2 - Exporting Weights.ipynb")


def notebook_code(path: Path) -> str:
    notebook = json.loads(path.read_text())
    return "\n".join(
        "".join(cell["source"])
        for cell in notebook["cells"]
        if cell.get("cell_type") == "code"
    )


def load_weapon_model_source() -> str:
    return f'''\
import os
import sys
from pathlib import Path
import torch
import numpy as np
import numpy

PROJECT_ROOT = Path({str(PROJECT_ROOT)!r})
TRAINING_ROOT = PROJECT_ROOT / "training"
sys.path.insert(0, str(TRAINING_ROOT))
from resnet20 import ResNet20

def save_weight(filename, values, **kwargs):
    """Atomically persist one packed weight and preserve completed files."""
    destination = Path(filename)
    if destination.exists():
        return
    temporary = destination.with_name(f".{{destination.name}}.tmp")
    numpy.savetxt(temporary, values, **kwargs)
    temporary.replace(destination)

checkpoint = torch.load(Path({str(CHECKPOINT)!r}), map_location="cpu", weights_only=False)
class_to_idx = checkpoint["class_to_idx"]
if class_to_idx != {{"Handgun": 0, "Knife": 1}}:
    raise ValueError(f"Unexpected class map: {{class_to_idx}}")
model = ResNet20(num_classes=2)
model.load_state_dict(checkpoint["model_state_dict"])
model.eval()
os.chdir(PROJECT_ROOT)
(PROJECT_ROOT / "weights").mkdir(exist_ok=True)
'''


def transformed_export_source() -> str:
    source = notebook_code(ORIGINAL_NOTEBOOK)
    source = re.sub(
        r'model = torch\.hub\.load\("chenyaofo/pytorch-cifar-models", "cifar10_resnet20", pretrained=True\)',
        load_weapon_model_source(),
        source,
    )
    for unused_import in (
        "from torchvision import transforms",
        "import torchvision",
        "from PIL import Image",
        "import matplotlib.pyplot as plt",
    ):
        source = source.replace(unused_import, "")

    # The two implementations have identical operations but different names.
    source = source.replace("model.conv1", "model.stem[0]")
    source = source.replace("model.bn1", "model.stem[1]")
    source = source.replace(".downsample", ".shortcut")

    # The original notebook drops the fully connected bias.  The FHE project
    # now reads this separate two-element file and adds it after the FC layer.
    source = source.replace("np.savetxt(", "save_weight(")
    source += "\nsave_weight('weights/fc_bias.bin', model.fc.bias.detach().numpy())\n"
    return source


def main() -> None:
    global CHECKPOINT
    parser = argparse.ArgumentParser(description="Export a two-class ResNet-20 checkpoint for LowMemory FHE.")
    parser.add_argument("--checkpoint", type=Path, default=CHECKPOINT)
    args = parser.parse_args()
    CHECKPOINT = args.checkpoint.resolve()
    if not CHECKPOINT.is_file():
        raise FileNotFoundError(f"Missing checkpoint: {CHECKPOINT}")
    if not ORIGINAL_NOTEBOOK.is_file():
        raise FileNotFoundError(f"Missing original exporter notebook: {ORIGINAL_NOTEBOOK}")
    exec(compile(transformed_export_source(), str(ORIGINAL_NOTEBOOK), "exec"), {"__name__": "__main__"})
    print("Export complete: packed FHE weights are in", PROJECT_ROOT / "weights")


if __name__ == "__main__":
    main()
