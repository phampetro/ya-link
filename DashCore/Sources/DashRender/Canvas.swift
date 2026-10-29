import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Màu sRGB 0–255.
public struct RGB: Equatable {
    public var r, g, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }
    public static let white = RGB(255, 255, 255)
    public static let black = RGB(0, 0, 0)
}

/// Vẽ bằng CPU vào bitmap, toạ độ như web: gốc trên trái, y đi xuống (giống mockup HTML).
final class Canvas {
    enum Align { case left, center, right }

    let ctx: CGContext
    let width: CGFloat
    let height: CGFloat

    init?(width: Int, height: Int) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(height))
        c.scaleBy(x: 1, y: -1)
        c.setShouldAntialias(true)
        c.interpolationQuality = .high
        ctx = c
        self.width = CGFloat(width)
        self.height = CGFloat(height)
    }

    func makeImage() -> CGImage? { ctx.makeImage() }

    // MARK: Hình

    func fill(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        ctx.setFillColor(color)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(rect)
        }
    }

    func fillCircle(center: CGPoint, radius: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func strokeCircle(center: CGPoint, radius: CGFloat, _ color: CGColor, width: CGFloat) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func fill(_ path: CGPath, _ color: CGColor, evenOdd: Bool = false) {
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
    }

    func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// Viền hình chữ nhật (bo góc nếu `radius` > 0); nét nằm giữa mép.
    func stroke(_ rect: CGRect, _ color: CGColor, width: CGFloat, radius: CGFloat = 0) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        } else {
            ctx.stroke(rect)
        }
    }

    /// Vẽ trong một hệ toạ độ riêng (vd. icon thiết kế trong hộp 26×26) đặt vào `rect`.
    func inBox(_ box: CGFloat, _ rect: CGRect, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / box, y: rect.height / box)
        body()
        ctx.restoreGState()
    }

    func withAlpha(_ alpha: Double, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(max(0, min(1, alpha))))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func translated(_ dx: CGFloat, _ dy: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: dx, y: dy)
        body()
        ctx.restoreGState()
    }

    /// Ảnh phủ kín `rect` (cắt bớt phần thừa), như CSS object-fit: cover.
    func image(_ img: CGImage, cover rect: CGRect, alpha: Double = 1) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let s = max(rect.width / iw, rect.height / ih)
        let dw = iw * s, dh = ih * s
        let dx = rect.minX + (rect.width - dw) / 2, dy = rect.minY + (rect.height - dh) / 2
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setAlpha(CGFloat(alpha))
        ctx.translateBy(x: dx, y: dy + dh)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        ctx.restoreGState()
    }

    // MARK: Chữ (CoreText, chữ tiếng Việt có dấu)

    enum Weight: CGFloat {
        case regular = 0.0, medium = 0.23, semibold = 0.3, bold = 0.4
    }

    private static var fontCache: [String: CTFont] = [:]

    static func font(_ size: CGFloat, _ weight: Weight) -> CTFont {
        let key = "\(size)-\(weight.rawValue)"
        if let f = fontCache[key] { return f }
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait as String: weight.rawValue] as CFDictionary
        let desc = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
                                                            [kCTFontTraitsAttribute as String: traits] as CFDictionary)
        let f = CTFontCreateWithFontDescriptor(desc, size, nil)
        fontCache[key] = f
        return f
    }

    private func line(_ s: String, _ size: CGFloat, _ weight: Weight, _ color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): Canvas.font(size, weight),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    func measure(_ s: String, size: CGFloat, weight: Weight) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(s, size, weight, RGB.white.cg()), nil, nil, nil))
    }

    /// Vẽ một dòng chữ; `y` là mép trên của dòng (cao = size × 1,2). Trả về độ rộng đã vẽ.
    @discardableResult
    func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: Weight, color: CGColor,
              maxWidth: CGFloat? = nil, align: Align = .left) -> CGFloat {
        var l = line(s, size, weight, color)
        if let maxW = maxWidth, CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) > maxW {
            let ellipsis = line("…", size, weight, color)
            l = CTLineCreateTruncatedLine(l, Double(maxW), .end, ellipsis) ?? l
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(l, &ascent, &descent, nil))
        let lineH = size * 1.2
        let baseline = y + (lineH - (ascent + descent)) / 2 + ascent
        let startX: CGFloat
        switch align {
        case .left: startX = x
        case .center: startX = x - w / 2
        case .right: startX = x - w
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: startX, y: baseline)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
        return w
    }
}

public enum ImageEncoder {
    /// JPEG baseline (ImageIO), chất lượng 0–1. Đồng hồ nhận JPEG 4:2:0 baseline.
    public static func jpeg(_ image: CGImage, quality: Double) -> [UInt8] {
        encode(image, type: "public.jpeg", options: [kCGImageDestinationLossyCompressionQuality as String: quality])
    }

    public static func png(_ image: CGImage) -> [UInt8] {
        encode(image, type: "public.png", options: [:])
    }

    private static func encode(_ image: CGImage, type: String, options: [String: Any]) -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return [] }
        return [UInt8](data as Data)
    }

    /// Đọc ảnh (JPEG/PNG/HEIC) thành CGImage, thu nhỏ còn cạnh dài `maxPixel` để vẽ nhanh.
    public static func load(_ data: Data, maxPixel: Int = 960) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
