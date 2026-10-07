## Đã sửa gì

Thêm workflow `fhe-surrogate-finetune.yml` chạy bốn cấu hình fine-tune Chebyshev-surrogate độc lập. Thêm chương trình fine-tune plaintext và cho phép ResNet-20 nhận activation factory mà không đổi checkpoint deployed.

## Cơ chế

Mỗi candidate load cùng checkpoint `outputs_fhe_selected/best.pt`, thay ReLU ở đường train bằng Chebyshev bậc 59 trên vùng FHE `[-1, 1]`, rồi tối ưu cross-entropy cùng range penalties. Checkpoint artifact bỏ các coefficient cố định của surrogate nên vẫn load được bởi ResNet-20 ReLU/exporter hiện tại.

## Cách hoạt động

Workflow chạy tuần tự bốn mức bound, learning rate và range/stem penalties; không build FHE, không sinh keys và không suy luận ciphertext. Mỗi candidate xuất `best.pt`, `report.json` gồm surrogate/exact-ReLU validation, và log thành artifact 30 ngày.

## Lợi ích

Cho phép chọn checkpoint có độ chính xác tốt trong điều kiện gần FHE trước khi tốn thời gian benchmark encrypted. Các candidate không ảnh hưởng model deployed cho đến khi người dùng chọn artifact tốt nhất và xác nhận lại bằng FHE sample.
