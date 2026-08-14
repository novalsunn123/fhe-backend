# fhe-backend

Development pushes are validated by a self-hosted end-to-end FHE benchmark.
See [`CICD/README.md`](CICD/README.md) for the measured pipeline and report
contents.

Agent-authored source changes are submitted on `agent/*` pull requests. CI
builds and benchmarks each candidate against the latest `dev` baseline, then
publishes the measured deltas for manual review. CI never merges automatically.

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
