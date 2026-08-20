import sys
from pathlib import Path

if len(sys.argv) == 1:
    print('Launch this script followed by a filename (e.g. \'plain.py "../inputs/luis.png"\')')
    exit(0)

import torch
from torchvision import transforms
from PIL import Image
import numpy as np

project_root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(project_root / "training"))
from resnet20 import ResNet20

checkpoint = torch.load(
    project_root / "training" / "outputs_fhe_stem" / "best.pt",
    map_location="cpu",
    weights_only=False,
)
model = ResNet20(num_classes=2)
model.load_state_dict(checkpoint["model_state_dict"])
model.eval()

img = Image.open(sys.argv[1])
convert_tensor = transforms.ToTensor()
img = convert_tensor(img)
img = transforms.Normalize((0.5, 0.5, 0.5), (0.5, 0.5, 0.5))(img)
img = img.unsqueeze(0)

np.set_printoptions(precision=3)

result = model(img)

result_list = my_formatted_list = list(np.around(result[0].detach().numpy(),3))

print("Plain:  " + str(result_list))
