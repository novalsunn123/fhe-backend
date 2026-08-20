tạo môi trường: 

python3 -m venv .venv
./.venv/bin/python -m pip install --upgrade pip
./.venv/bin/pip install -r training/requirements.txt

chạy lệnh để export : 

PYTHONWARNINGS=ignore ./.venv/bin/python \
  export_weapon_weights.py \
  --checkpoint training/outputs_fhe_stem/best.pt



  lệnh kiểm tra: 

  find weights -type f | wc -l
du -sh weights
test -f weights/fc.bin && echo "fc.bin OK"
test -f weights/fc_bias.bin && echo "fc_bias.bin OK"



build mã nguồn:
cd /root/HE/LowMemoryFHEWeaponResNet20_v1

cmake -S . -B build
cmake --build build -j"$(nproc)"



cd build

/usr/bin/time -v ./LowMemoryFHEWeaponResNet20 \
  generate_keys 1


/usr/bin/time -v ./LowMemoryFHEWeaponResNet20 \
  load_keys 1 \
  input inputs/2041_0.png \
  verbose 1  