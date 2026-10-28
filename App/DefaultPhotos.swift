import UIKit

/// Hai ảnh nền mặc định (biển chiều, đồng cỏ) vẽ bằng code, dùng khi chưa chọn ảnh nào.
/// Hình theo design/dash/photo-sea.svg và photo-meadow.svg (viewBox 240×180, phóng 2×).
enum DefaultPhotos {
    static func make() -> [CGImage] {
        [sea(), meadow()].compactMap { $0.cgImage }
    }

    private static func render(_ draw: @escaping (CGContext) -> Void) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let r = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360), format: fmt)
        return r.image { ctx in
            ctx.cgContext.scaleBy(x: 2, y: 2)
            draw(ctx.cgContext)
        }
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rect(_ c: CGContext, _ hex: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        c.setFillColor(color(hex).cgColor)
        c.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    private static func ellipse(_ c: CGContext, _ hex: UInt32, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
        c.setFillColor(color(hex).cgColor)
        c.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    /// Dải sóng: từ trái sang phải qua hai đoạn cong bậc hai, rồi đóng xuống đáy.
    private static func wave(_ c: CGContext, _ hex: UInt32, y0: CGFloat, c1: CGPoint, m: CGPoint, c2: CGPoint, end: CGPoint) {
        c.setFillColor(color(hex).cgColor)
        c.move(to: CGPoint(x: 0, y: y0))
        c.addQuadCurve(to: m, control: c1)
        c.addQuadCurve(to: end, control: c2)
        c.addLine(to: CGPoint(x: 240, y: 180))
        c.addLine(to: CGPoint(x: 0, y: 180))
        c.closePath()
        c.fillPath()
    }

    private static func sea() -> UIImage {
        render { c in
            rect(c, 0x8fc7e8, 0, 0, 240, 180)
            rect(c, 0xa9d5ee, 0, 0, 240, 50)
            ellipse(c, 0xfff1c4, 170, 70, 22, 22)
            rect(c, 0x2f7fb5, 0, 96, 240, 84)
            rect(c, 0x4a97c8, 0, 96, 240, 14)
            wave(c, 0xf1d9a8, y0: 140, c1: CGPoint(x: 60, y: 128), m: CGPoint(x: 120, y: 140),
                 c2: CGPoint(x: 180, y: 152), end: CGPoint(x: 240, y: 140))
            c.setFillColor(color(0xe05a47).cgColor)
            c.move(to: CGPoint(x: 30, y: 140))
            c.addLine(to: CGPoint(x: 44, y: 114))
            c.addLine(to: CGPoint(x: 58, y: 140))
            c.closePath()
            c.fillPath()
        }
    }

    private static func meadow() -> UIImage {
        render { c in
            rect(c, 0x86d4ff, 0, 0, 240, 180)
            rect(c, 0xa6e0ff, 0, 0, 240, 52)
            rect(c, 0xc4ecff, 0, 52, 240, 30)
            ellipse(c, 0xfff6bd, 64, 48, 22, 22)
            for (x, y, rx, ry) in [(156, 40, 30, 9), (176, 33, 20, 9), (138, 35, 16, 7), (214, 70, 22, 7), (226, 64, 14, 6), (40, 86, 24, 6)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                ellipse(c, 0xffffff, x, y, rx, ry)
            }
            wave(c, 0x8fe39d, y0: 108, c1: CGPoint(x: 60, y: 84), m: CGPoint(x: 120, y: 100),
                 c2: CGPoint(x: 180, y: 116), end: CGPoint(x: 240, y: 92))
            wave(c, 0x5fcf7c, y0: 128, c1: CGPoint(x: 70, y: 104), m: CGPoint(x: 140, y: 122),
                 c2: CGPoint(x: 210, y: 140), end: CGPoint(x: 240, y: 116))
            wave(c, 0x3dba62, y0: 150, c1: CGPoint(x: 80, y: 130), m: CGPoint(x: 150, y: 146),
                 c2: CGPoint(x: 220, y: 162), end: CGPoint(x: 240, y: 140))
            for (x, y) in [(30, 140), (52, 152), (196, 150), (214, 164), (76, 166)] as [(CGFloat, CGFloat)] {
                ellipse(c, 0xffd84d, x, y, 2.6, 2.6)
            }
            for (x, y) in [(40, 160), (182, 164), (16, 156)] as [(CGFloat, CGFloat)] {
                ellipse(c, 0xff7aa8, x, y, 2.4, 2.4)
            }
        }
    }
}
