import UIKit

/// Màn hình thử cho lần ra xe đầu tiên: vẽ bằng CPU (chạy được cả khi khoá máy), JPEG chất lượng 0,5.
/// Chữ tránh vùng nút ＋/－ (x < 56, y 68–168) và thanh dưới (y ≥ 186). Màu xanh dương của trang Home.
enum TestScreen {
    static func render(width: Int, height: Int, speed: Int?, lastButton: String, frames: Int) -> [UInt8] {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.03, green: 0.10, blue: 0.22, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 42))

            draw("Ya Link · thử kết nối", at: CGPoint(x: 12, y: 9), size: 20, weight: .semibold)
            draw(speed.map { "\($0)" } ?? "--", at: CGPoint(x: 72, y: 56), size: 64, weight: .bold)
            draw("km/h", at: CGPoint(x: 72, y: 128), size: 18, weight: .medium, color: .lightGray)
            draw("Nút cuối", at: CGPoint(x: 230, y: 62), size: 16, weight: .medium, color: .lightGray)
            draw(lastButton, at: CGPoint(x: 230, y: 84), size: 18, weight: .semibold)
            draw("Khung đã gửi: \(frames)", at: CGPoint(x: 230, y: 128), size: 16, weight: .medium, color: .lightGray)
        }
        return Array(image.jpegData(compressionQuality: 0.5) ?? Data())
    }

    private static func draw(_ text: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight, color: UIColor = .white) {
        (text as NSString).draw(at: p, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }
}
