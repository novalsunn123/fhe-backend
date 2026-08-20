# FHE Weapon Classification Workspace

Workspace này triển khai mô hình ResNet-20 phân loại ảnh vũ khí trên dữ liệu
mã hóa đồng hình CKKS. Client giữ khóa bí mật, mã hóa ảnh và giải mã logits;
server chỉ nhận public/evaluation keys và thực hiện suy luận trên ciphertext.

## Cấu trúc mã nguồn

```text
.
├── FHEBackend-batch-limit/          # FHEClient, FHEServer và batch inference
├── FHEBatchTest/                    # Script kiểm thử tuần tự/full validation
├── LowMemoryFHEWeaponResNet20_v1/   # Training, checkpoint, dataset và export weights
├── .gitignore
└── README.md
```

- `FHEBackend-batch-limit`: phiên bản backend đã bổ sung packed weights, profiler,
  tái sử dụng rotation keys, staged batch và giới hạn batch an toàn.
- `FHEBatchTest`: chạy kiểm tra một nhóm ảnh hoặc toàn bộ tập validation, lưu
  logits, prediction, thời gian và lỗi giải mã vào CSV.
- `LowMemoryFHEWeaponResNet20_v1`: ResNet-20 hai lớp `Handgun`/`Knife`, dữ liệu
  train/validation, mã nguồn fine-tune và checkpoint FHE đã chọn.

## Kết quả thử nghiệm nhiều ảnh

Kết quả dưới đây lấy từ lần chạy full validation đã lưu tại
`FHEBatchTest/results/staged_full_val_20260815_000221/summary.txt` và
`results.csv`.

| Chỉ số | Kết quả |
|---|---:|
| Tập validation | 190 ảnh |
| Cấu hình chạy | 19 batch × 10 ảnh |
| Giải mã thành công | 190/190 |
| Lỗi giải mã CKKS | 0 |
| Chính xác toàn bộ | 172/190 — **90,53%** |
| Handgun | 87/100 — 87,00% |
| Knife | 85/90 — 94,44% |
| Trung bình inference quy đổi/ảnh | 381,445 giây — khoảng 6 phút 21 giây |
| Trung bình inference/batch 10 ảnh | 3.814,450 giây — khoảng 63 phút 34 giây |
| Tổng inference của 19 batch | 72.474,549 giây — khoảng 20 giờ 08 phút |
| Trung bình mã hóa/ảnh | 0,655 giây |
| Trung bình giải mã/ảnh | 0,922 giây |
| Trung bình FHE circuit/ảnh | 345,333 giây — khoảng 5 phút 45 giây |

Đây là kết quả của đúng checkpoint/weights, CKKS parameters, OpenFHE và máy
đã dùng trong lần chạy trên. Không nên so sánh trực tiếp với lần chạy trên phần
cứng hoặc keyset khác nếu chưa kiểm soát cùng điều kiện.

## Chuẩn bị môi trường

Cấu hình đã kiểm thử:

- Ubuntu 24.04 x86-64;
- OpenFHE 1.0.4 cài tại `/usr/local`;
- GCC/G++ 13, CMake 3.28 và OpenMP;
- 12 logical CPU, 24 GB RAM và swap dự phòng;
- ít nhất 18 GB RAM available và 40 GB ổ đĩa trống khi chạy staged batch.

Hướng dẫn cài OpenFHE, export weights, build, sinh key và chạy một ảnh nằm tại
[`FHEBackend-batch-limit/build.md`](FHEBackend-batch-limit/build.md).

## Build Client và Server

Tại thư mục gốc này, sau khi đã đặt text weights vào
`FHEBackend-batch-limit/FHEServer/weights`:

```bash
cmake -S FHEBackend-batch-limit/FHEClient \
  -B FHEBackend-batch-limit/FHEClient/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/usr/local
cmake --build FHEBackend-batch-limit/FHEClient/build --parallel 2

cmake -S FHEBackend-batch-limit/FHEServer \
  -B FHEBackend-batch-limit/FHEServer/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/usr/local
cmake --build FHEBackend-batch-limit/FHEServer/build --parallel 2

ctest --test-dir FHEBackend-batch-limit/FHEServer/build --output-on-failure
```

Build server tạo lại `FHEServer/build/packed-weights.bin` từ 6.315 file text
weights. Build output và weights không được lưu trong Git.

## Sinh key

```bash
cd FHEBackend-batch-limit/FHEClient/build
./FHEClient generate_keys 1
cd ../../..

mkdir -p FHEBackend-batch-limit/FHEServer/keys_exp1
cp -al FHEBackend-batch-limit/FHEClient/server_keys_exp1/. \
  FHEBackend-batch-limit/FHEServer/keys_exp1/

test ! -e FHEBackend-batch-limit/FHEServer/keys_exp1/secret-key.txt \
  && echo "OK: server không chứa secret key"
```

`FHEClient/keys_exp1` chứa toàn bộ key, bao gồm secret key. Server chỉ được
nhận nội dung của `FHEClient/server_keys_exp1`.

## Kiểm tra và chạy toàn bộ 190 ảnh validation

Kiểm tra binary, packed weights, keys, dataset, RAM và ổ đĩa mà chưa chạy
inference:

```bash
cd FHEBatchTest
./run_full_val_staged.sh --check 10 1
```

Chạy foreground:

```bash
./run_full_val_staged.sh 10 1
```

Chạy nền để có thể ngắt SSH:

```bash
nohup ./run_full_val_staged.sh 10 1 \
  > staged_full_val.log 2>&1 < /dev/null &
echo $! > staged_full_val.pid
```

Theo dõi:

```bash
tail -f staged_full_val.log
kill -0 "$(cat staged_full_val.pid)" 2>/dev/null \
  && echo "Đang chạy" || echo "Đã kết thúc"
```

Nếu phiên chạy bị gián đoạn, lấy đường dẫn run mới nhất rồi tiếp tục:

```bash
RUN_DIR="$(cat latest_staged_full_val_run.txt)"
./run_full_val_staged.sh --resume "$RUN_DIR"
```

Kết quả mỗi lần chạy nằm trong `FHEBatchTest/results/staged_full_val_<timestamp>/`:

- `summary.txt`: tổng hợp accuracy, số lỗi và thời gian;
- `results.csv`: kết quả chi tiết từng ảnh;
- `progress.txt`: tiến độ hiện tại;
- `logs/`: log mã hóa, suy luận và giải mã;
- `decrypt_errors/`: artifacts của ảnh gặp lỗi giải mã.

Batch mặc định nên dùng là 10 ảnh trên máy 24 GB RAM. Server cho phép tối đa
20 ảnh theo cấu hình mặc định, nhưng tăng batch làm thời gian checkpoint dài và
tăng rủi ro mất cả batch khi tiến trình bị dừng.

## Lưu ý bảo mật và Git

Không commit secret key, evaluation keys, ciphertext, encrypted result, text
weights, packed weights, build output, môi trường Python hoặc log runtime.
Những artifacts này phải được sinh/cấp riêng sau khi clone. Không trộn key,
crypto context và ciphertext từ các lần sinh key khác nhau.
