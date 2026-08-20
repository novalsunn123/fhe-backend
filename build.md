# Build và vận hành FHE Backend

Tài liệu này mô tả cách tái tạo `FHEClient` và `FHEServer` từ một clone Git
sạch. Repository chỉ lưu source và ảnh test nhỏ; khóa FHE, model weights,
ciphertext, kết quả, checkpoint trung gian và build output không nằm trong Git.

## 1. Yêu cầu hệ thống

Cấu hình đã được kiểm thử:

- Ubuntu 24.04 x86-64;
- 12 logical CPU;
- 24 GB RAM và swap dự phòng;
- CMake 3.28, GCC/G++ 13 với C++17 và OpenMP;
- OpenFHE 1.0.4 cài dưới `/usr/local`;
- tối thiểu khoảng 30 GB trống để sinh một keyset và chạy inference đơn;
- nên còn ít nhất 40 GB trống và 18 GB RAM available khi chạy staged batch.

Không nên chạy đồng thời hai tiến trình `FHEServer`: mỗi inference có thể đạt
khoảng 18.7 GB peak RSS trên cấu hình đã đo.

## 2. Cài OpenFHE 1.0.4

```bash
git clone --branch v1.0.4 --depth 1 \
  https://github.com/openfheorg/openfhe-development.git

cmake -S openfhe-development -B openfhe-development/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local

cmake --build openfhe-development/build --parallel 2
sudo cmake --install openfhe-development/build
```

Kiểm tra package CMake:

```bash
find /usr/local -name 'OpenFHEConfig.cmake' -print
```

Các key/ciphertext được serialize bằng một crypto context cụ thể. Không trộn
artifacts tạo bởi phiên bản OpenFHE hoặc keyset khác nhau.

## 3. Clone source và cấp model weights

```bash
git clone https://github.com/novalsunn123/fhe-backend.git
cd fhe-backend
git switch main
```

Inference cần thư mục `FHEServer/weights` chứa bộ trọng số đã export, gồm
`fc.bin`, `fc_bias.bin` và các file convolution/batch-normalization. Bộ hiện tại
có 6.315 file và khoảng 1.3 GB nên không được lưu trong Git.

Nếu đã có bộ trọng số được export:

```bash
cp -a /path/to/exported/weights FHEServer/weights
test -s FHEServer/weights/fc.bin
```

Trong workspace huấn luyện hiện tại, trọng số được export từ checkpoint bằng
`LowMemoryFHEWeaponResNet20_v1/export_weapon_weights.py`, rồi copy thư mục
`weights` sinh ra sang `FHEServer/weights`. Script export phụ thuộc code training
và notebook đóng gói của model, nên chúng phải được quản lý như một artifact
training riêng.

## 4. Build Client và Server

Chạy tại root của repository:

```bash
cmake -S FHEClient -B FHEClient/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/usr/local
cmake --build FHEClient/build --parallel 2

cmake -S FHEServer -B FHEServer/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/usr/local
cmake --build FHEServer/build --parallel 2
```

Khi `FHEServer/weights/fc.bin` tồn tại, build sẽ tạo
`FHEServer/build/packed-weights.bin`. Archive này được sinh lại tự động khi
text weights thay đổi và không được commit.

Chạy unit/smoke tests:

```bash
ctest --test-dir FHEServer/build --output-on-failure
```

Kiểm tra CLI:

```bash
./FHEClient/build/FHEClient
./FHEServer/build/FHEServer
```

## 5. Sinh và chuyển khóa

Tạo experiment 1 từ thư mục build của client:

```bash
cd FHEClient/build
./FHEClient generate_keys 1
cd ../..
```

Lệnh tạo:

- `FHEClient/keys_exp1`: toàn bộ keyset, bao gồm `secret-key.txt`;
- `FHEClient/server_keys_exp1`: chỉ public/evaluation keys dành cho server.

Trên cùng filesystem có thể dùng hard link để không nhân đôi khoảng 23 GB:

```bash
mkdir -p FHEServer/keys_exp1
cp -al FHEClient/server_keys_exp1/. FHEServer/keys_exp1/

test ! -e FHEServer/keys_exp1/secret-key.txt \
  && echo 'OK: server không có secret key'
```

Nếu client và server là hai máy khác nhau, truyền toàn bộ
`FHEClient/server_keys_exp1/` bằng SCP/rsync/object storage có kiểm soát, rồi đặt
tại `FHEServer/keys_exp1/`. Tuyệt đối không truyền `secret-key.txt`.

## 6. Chạy một ảnh

Ảnh đầu vào phải là PNG/JPEG RGB đúng 32×32.

Mã hóa tại client:

```bash
mkdir -p FHEClient/ciphertexts FHEServer/results

cd FHEClient/build
./FHEClient encrypt 1 \
  ../inputs/2041_0.png \
  ../ciphertexts/encrypted-input.bin
cd ../..
```

Suy luận tại server. Ví dụ dưới đây dùng shared filesystem; khi triển khai thật,
hãy chuyển ciphertext sang server trước:

```bash
cd FHEServer/build
FHE_BINARY_WEIGHTS=1 ./FHEServer infer 1 \
  ../../FHEClient/ciphertexts/encrypted-input.bin \
  ../results/encrypted-result.bin 1
cd ../..
```

Chuyển encrypted result về client và giải mã:

```bash
cd FHEClient/build
./FHEClient decrypt 1 \
  ../../FHEServer/results/encrypted-result.bin
cd ../..
```

## 7. Chạy staged batch

Manifest không có header, mỗi dòng gồm đường dẫn ciphertext input và output,
phân cách bởi đúng một ký tự tab:

```text
/absolute/path/01-input.bin\t/absolute/path/01-result.bin
/absolute/path/02-input.bin\t/absolute/path/02-result.bin
```

Checkpoint directory phải rỗng trước khi chạy:

```bash
mkdir -p FHEServer/checkpoints/batch-01 FHEServer/results

cd FHEServer/build
FHE_BINARY_WEIGHTS=1 ./FHEServer infer_batch 1 \
  ../batch-jobs.tsv \
  ../checkpoints/batch-01 \
  ../results/batch-metrics.tsv 1
cd ../..
```

Giới hạn mặc định là 20 ảnh/batch; cấu hình 24 GB nên dùng 10 ảnh/batch. Có thể
override bằng `FHE_BATCH_MAX_IMAGES`, tối đa 1.000, nhưng tăng batch không làm
giảm peak RAM đáng kể và làm tăng dữ liệu checkpoint/rủi ro mất tiến trình.

## 8. Profiler

```bash
mkdir -p reports/profile-01

cd FHEServer/build
FHE_PROFILE=1 \
FHE_PROFILE_DIR=../../reports/profile-01 \
FHE_BINARY_WEIGHTS=1 \
./FHEServer infer 1 \
  ../../FHEClient/ciphertexts/encrypted-input.bin \
  ../results/profile-result.bin 2
cd ../..
```

Profiler sinh Markdown, JSON và CSV về key loading, convolution, rotation,
bootstrapping, ReLU, residual block và từng layer. Nó không ghi secret key hay
nội dung ciphertext.

## 9. Những file không đưa lên Git

Có thể xóa và build lại ngay:

- `FHEClient/build/`, `FHEServer/build/`;
- `FHEServer/build/packed-weights.bin`;
- ciphertext, encrypted results và checkpoint trung gian;
- profiler reports, CI reports, log, PID và core dump.

Có thể tái tạo nhưng không nên xóa tùy tiện:

- `FHEClient/keys_exp*` và `FHEClient/server_keys_exp*`: sinh lại tốn thời gian;
- `FHEServer/keys_exp*`: phải cùng keyset với client;
- xóa/sinh key mới khiến ciphertext và encrypted result cũ không còn giải mã
  hoặc suy luận tương thích.

Phải lấy từ pipeline training/artifact storage:

- `FHEServer/weights/` hoặc checkpoint cùng công cụ export tương ứng;
- dataset đầy đủ dùng để đánh giá model.

Xác minh trước khi commit:

```bash
git status --short
git ls-files | grep -E 'keys_exp|secret-key|weights/|ciphertexts|results/|checkpoints|build/' \
  && echo 'ERROR: có artifact nặng được track' \
  || echo 'OK: chỉ source được track'
```

## 10. CI/CD và phát hành

Luồng an toàn của repository:

```text
agent/<task> -> Pull Request vào dev -> benchmark thủ công -> merge dev
dev -> Pull Request phát hành -> main
```

Không force-push hoặc đưa trực tiếp artifact local lên `main`. Self-hosted
runner cần OpenFHE và weights nằm ngoài checkout; GitHub artifact chỉ lưu report
nhỏ, không lưu keyset/trọng số/ciphertext.
