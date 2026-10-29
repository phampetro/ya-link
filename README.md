# Ya Link

App iPhone cá nhân cho đồng hồ TFT của Yamaha NMAX Tech MAX, dựng theo tài liệu của
[maxdash](https://github.com/lntvan166/maxdash).

> Không chính thức. Không liên quan, không được Yamaha Motor hay Garmin xác nhận.

| Thư mục | Nội dung |
|---|---|
| `DashCore/` | Lõi Swift thuần: khung Link A, CRC-32/MPEG-2, phiên bắt tay. Test chạy toàn bộ vectors của maxdash (`DashCore/Tests/DashCoreTests/vectors`, bản sao từ maxdash `80bbd9c`) |
| `App/` | App iPhone (SwiftUI). Bản 0.1 là app dò xe: kết nối, màn hình thử, ghi log mọi khung xe gửi về |
| `design/` | Mockup HTML của giao diện trên đồng hồ (mở `design/dash/home.html` bằng trình duyệt) |
| `project.yml` | XcodeGen: máy Mac trên GitHub Actions sinh project Xcode từ file này |

## Build

Mỗi lần push, GitHub Actions chạy `swift test` (vectors) rồi build file `.ipa` chưa ký. Tải `YaLink-ipa` ở
trang Actions, cài bằng Sideloadly với Apple ID của bạn. Apple ID miễn phí: cài lại sau mỗi 7 ngày.

**Test vectors đỏ = chưa được ra xe.**

## Quy trình làm việc (người và trợ lý AI)

1. **Nêu ý tưởng trước, chỉ sửa khi được đồng ý.** Gặp lỗi, câu hỏi hay ý tưởng mới: giải thích nguyên nhân và đề xuất
   cách làm (kèm ưu nhược điểm). Không tự sửa mã, thiết kế hay tài liệu cho tới khi chủ dự án đồng ý rõ ràng.
   Câu hỏi "có cách nào…" chỉ cần trả lời, không phải lệnh làm.
2. **Chỉ build khi được yêu cầu.** Mỗi lần push là chạy build, nên không push trước khi chủ dự án bảo build.
3. Giao diện thiết kế trên mockup HTML (`design/`) và được duyệt trước khi chuyển sang SwiftUI.
4. Tài liệu giao thức (`maxdash/docs`) sửa theo log đo trên xe thật, ghi rõ ngày và nguồn.

## Bản đồ khi chỉ đường: tên đường phía trước

Khi đang dẫn đường (có tuyến), trang Bản đồ **không** hiện tên đường quanh xe và cũng không hiện tên đường đang đi
(tên đường đang đi nằm ở thanh dưới của đồng hồ, thanh dưới không đổi). Thay vào đó chỉ có tên các đường **phía trước**,
tối đa **5 nhãn** cùng lúc:

- **1 nhãn "đi thẳng"**: tên đường mà tuyến sẽ đi tiếp, chỉ hiện khi tên đường **đổi** ở phía trước (đoạn tên đường kế tiếp
  có tên khác tên đang đi, lấy từ `Route.streetSpans`). Nhãn nằm ngay sau đầu xa nhìn thấy của tuyến, lệch khoảng 12 px sang phải.
- **2 đường cắt gần nhất bên trái** và **2 bên phải** (gần nhất trước), tính theo chiều đi của xe tại giao lộ.
  Nhãn trái nằm bên trái nét tuyến, căn phải, cách mép tuyến khoảng 10 px; nhãn phải nằm bên phải, căn trái. Không bao giờ
  đặt nhãn đè lên nét tuyến.
- Mỗi nhãn là một dòng "**Tên đường** · khoảng cách" (tên in đậm vừa, khoảng cách chữ thường, cỡ 16, nền đen 75 %, rộng tối đa
  khoảng 190 px, tên dài bị cắt bằng "…"). Khoảng cách là quãng đường **dọc tuyến** từ xe tới giao lộ, làm tròn như ô rẽ:
  trên 1 km theo 0,1 km · 100 m – 1 km theo 50 m · dưới 100 m theo 10 m (ví dụ `Lê Lợi · 150 m`).
- Bỏ: đường trùng tên với đường đang đi, đường chạy song song hoặc trùng với tuyến (góc cắt dưới 25°), đường dịch vụ/lối đi
  nhỏ (chỉ lấy từ đường lớn tới đường nhỏ `minor`), đường không có tên, tên trùng (giữ giao lộ gần nhất).
- Chỉ nhãn có vị trí neo nằm **trong vùng bản đồ nhìn thấy** mới được vẽ, nên tầm nhìn phía trước phụ thuộc mức thu phóng.
  Nhãn đè lên nhau, lên mũi tên, ô rẽ, giờ đến, biển tốc độ, nút ＋/－, thanh dưới hay menu thì bị bỏ (không dời).
  Mức xa nhất (2 km) không hiện nhãn; từ mức 1 km trở lên có.
- **Mức thu phóng mặc định thu nhỏ một mức** (từ 400 m xuống 600 m) để thấy đủ 5 nhãn.
- Nguồn tên đường cắt là **ô bản đồ OpenFreeMap** (lớp `transportation_name`), nên các hẻm không có tên trong dữ liệu
  sẽ không có nhãn. Nhãn "đi thẳng" lấy từ tên đường của tuyến (Valhalla `trace_attributes`), không phụ thuộc ô bản đồ.
- Khi không dẫn đường, bản đồ giữ nguyên các nhãn tên đường quanh xe như trước (từ mức thu phóng 400 m trở lên).

Mã: `DashCore/Sources/DashCore/AheadStreets.swift` (chọn nhãn, hàm thuần có test) và `MapRenderer.swift` (đổi ô bản đồ
thành đường, chiếu lên màn hình, đặt nhãn; kết quả chọn được lưu theo tuyến, vị trí xe làm tròn ~10 m và mức zoom).
