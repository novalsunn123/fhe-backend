# FHE Weapon Classification Backend

Repository triển khai phân loại ảnh vũ khí hai lớp (`Handgun`, `Knife`) bằng
CKKS/OpenFHE theo kiến trúc client–server. Client là vùng tin cậy: sinh khóa,
mã hóa ảnh 32×32 RGB và giải mã logits. Server chỉ nhận public/evaluation keys
và ciphertext để chạy ResNet-20; server không có secret key và không thể giải
mã ảnh hay kết quả.

Hướng dẫn tái tạo môi trường, build, sinh/chuyển khóa và chạy inference nằm tại
[`build.md`](build.md). Chi tiết benchmark CI nằm tại
[`CICD/README.md`](CICD/README.md).

## Kiến trúc

```text
CLIENT (trusted)                         SERVER (compute only)
----------------                         ---------------------
Generate CKKS keyset
  |-- giữ secret key
  `-- gửi public/evaluation keys ------> nạp context + evaluation keys

Ảnh RGB 32x32
  `-- encrypt bằng public key
      `-- encrypted-input.bin ---------> ResNet-20 trên ciphertext
                                          `-- encrypted-result.bin
Giải mã logits <------------------------ gửi encrypted result về client
  `-- Handgun / Knife
```

Các thành phần chính:

| Thành phần | Trách nhiệm |
|---|---|
| `FHEClient/` | Sinh/export keyset, kiểm tra ảnh 32×32 RGB, mã hóa và giải mã logits |
| `FHEServer/` | Inference đơn hoặc staged batch; không chứa secret key |
| `Common/` | Rotation-key schedule dùng chung, tránh lệch lịch sinh/nạp khóa |
| `CICD/` | Build, end-to-end benchmark, đo CPU/RAM/swap và tạo report |
| `.github/workflows/` | Chạy benchmark trên self-hosted runner và upload report nhỏ |

## Những thay đổi và tối ưu đã thực hiện

- **Tách client–server:** secret key chỉ tồn tại ở client; server chỉ nhận các
  key cần cho homomorphic evaluation.
- **Profiler chi tiết:** đo context/key loading, từng convolution, rotation,
  bootstrap, ReLU, residual block, layer và toàn circuit; có thể bật/tắt mà
  không thay đổi thuật toán.
- **Packed binary weights:** 6.315 text-weight files được đóng thành
  `packed-weights.bin` lúc build, giảm số lần mở file và parse số trong
  inference. Archive là build output và không được commit.
- **Rotation-key audit:** lịch rotation được dùng chung giữa client/server;
  loại các rotation downsample không được quan sát sử dụng, giảm key material
  thừa mà không đổi data layout hoặc CKKS parameters.
- **Staged multi-image inference:** `infer_batch` xử lý theo layer/key stage,
  tái sử dụng rotation keys cho nhiều ảnh và lưu ciphertext trung gian xuống
  đĩa. Cách này giảm mạnh chi phí nạp lại key so với chạy `infer` riêng từng ảnh.
- **Giới hạn batch an toàn:** mặc định tối đa 20 ảnh, khuyến nghị 10 ảnh trên
  máy 24 GB; manifest quá giới hạn bị từ chối trước khi nạp rotation keys.
- **CI/CD đo được:** mỗi thay đổi được build và chạy end-to-end trên self-hosted
  runner, nhưng quyết định merge vẫn là thủ công.

## Kết quả demo đã đo

Full validation bằng staged batch 10 trên máy 12 logical CPU/24 GB RAM:

| Chỉ số | Kết quả |
|---|---:|
| Dataset | 190 ảnh (100 Handgun, 90 Knife) |
| Accuracy tổng | 172/190 — **90,53%** |
| Handgun | 87/100 — 87,00% |
| Knife | 85/90 — 94,44% |
| Decrypt error | 0 |
| Tổng server inference | 20 giờ 07 phút 55 giây |
| Trung bình amortized | 381,445 giây/ảnh (~6 phút 21 giây) |
| Tổng FHE circuit | 18 giờ 13 phút 33 giây |

Số liệu phụ thuộc CPU, RAM, tình trạng page cache, OpenFHE build và bộ weights;
không nên so sánh giữa hai commit nếu môi trường/keyset/test image khác nhau.

## Dữ liệu không nằm trong Git

Repository source hiện rất nhỏ; dung lượng local chủ yếu đến từ keyset khoảng
23 GB và weights khoảng 1,3 GB. `.gitignore` loại trừ:

- build output và `packed-weights.bin`;
- client/server keysets, đặc biệt `secret-key.txt`;
- model weights/checkpoints;
- ciphertext, encrypted result và checkpoint trung gian;
- log, PID, core dump, runtime và benchmark reports.

Không cần xóa các file này khỏi máy để push source. Kiểm tra bằng
`git status --ignored --short`; chỉ file được `git add` và track mới đi lên
GitHub.

## Quy trình nhánh

```text
agent/<task> -> PR vào dev -> CI benchmark + đọc report -> merge dev
dev -> PR phát hành -> main
```

Development pushes are validated by a self-hosted end-to-end FHE benchmark.
CI không auto-merge và không được đưa key/weights/ciphertext vào GitHub.

## Lịch sử phiên bản dev

Mỗi phiên bản được người quản lý chấp nhận thủ công sau khi đọc benchmark.
Nội dung có thể gồm thay đổi, cơ chế, cách hoạt động, lợi ích và số liệu so với
phiên bản `dev` ngay trước đó.

<!-- DEV_HISTORY_START -->

### 2026-08-13 — perf: add detailed FHEServer operation profiler (infer -3.56%, RAM +0.45%)

**Code:** [`0dbd0b0`](https://github.com/novalsunn123/fhe-backend/commit/0dbd0b0765d18026ac93bf2b946b24265b972a0f)

#### Đã sửa gì

Bổ sung profiler nội bộ có thể bật/tắt cho FHEServer và ba báo cáo
`fhe-operation-profile.md`, `fhe-operation-profile.json`,
`fhe-operation-events.csv`. Profiler đo thời gian nạp context/evaluation keys,
từng layer, residual block, convolution, activation, downsample, bootstrap và
ghi kết quả mã hóa. Không thay đổi thuật toán FHE, tham số CKKS, data layout,
trọng số hoặc vị trí bootstrapping.

#### Cơ chế

Profiler dùng `std::chrono::steady_clock`, RAII scope, context layer/block theo
thread và bộ đệm event có mutex. Nó mặc định tắt, bật bằng `FHE_PROFILE=1` hoặc
`FHE_PROFILE_DIR`; trong CI nó tự dùng `CICD_REPORT_DIR` trừ khi
`FHE_PROFILE=0`. Báo cáo JSON dùng số cho thời gian/kích thước và `null` cho dữ
liệu không có; CSV escape trường văn bản; không ghi key, ciphertext, ảnh hoặc
trọng số.

#### Cách hoạt động

Khi profiling được bật, FHEServer thu thập event trong bộ nhớ, tự đếm số lần
bootstrap, ghi slots và level trước/sau rồi finalize Markdown/JSON/CSV khi infer
thành công hoặc khi exception được bắt. Workflow hiện tại upload toàn bộ
`CICD_REPORT_DIR`, nên các file profiler đi cùng `summary.md`, `benchmark.json`,
`metrics.csv` và log. CPU/RAM/swap tiếp tục do trusted CI đo ngoài tiến trình;
prediction/logits tiếp tục do FHEClient giải mã.

#### Lợi ích

Cung cấp dữ liệu operation-level để xác định bottleneck trước khi tối ưu mà
không cần cấp secret key cho server. Release build của FHEClient/FHEServer, các
test comparison/history và smoke test bật/tắt profiler đều đạt; JSON được kiểm
tra bằng `jq`. Đây là thay đổi observability, chưa tuyên bố cải thiện thời gian
hay RAM; overhead thực tế sẽ được performance gate đo trên full inference.


#### Benchmark so với phiên bản dev trước

| Chỉ số | Trước | Sau | Thay đổi |
|---|---:|---:|---:|
| Sinh khóa | 2m 47.344s | 2m 48.116s | +0.46% |
| Suy luận | 12m 51.263s | 12m 23.833s | -3.56% |
| Tính toán FHE | 10m 39.257s | 10m 11.864s | -4.29% |
| RAM trung bình | 14.78 GiB | 14.77 GiB | -0.08% |
| RAM đỉnh | 18.62 GiB | 18.71 GiB | +0.45% |
| CPU time | 54m 58.810s | 51m 51.760s | -5.67% |
| CPU trung bình | 427% | 418% | -2.11% |
| CPU đỉnh | 4.00% | 8.00% | +100.00% |

**Đánh giá:** Improved  
**Prediction:** Handgun  
**Swap khi suy luận:** 0 KiB

<!-- Phiên bản mới nhất được chèn ngay dưới dòng này. -->
<!-- DEV_HISTORY_END -->
