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
