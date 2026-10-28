import CoreGraphics
import DashCore
import Foundation

/// Icon vẽ bằng đường vector (chép từ SVG trong mockup), dạng đặc để JPEG 4:2:0 không làm nhoè.
/// Mỗi hàm vẽ trong hộp toạ độ riêng; gọi qua `Canvas.inBox`.
enum Icons {
    private static func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

    // MARK: Menu (hộp 26)

    static func music(_ c: Canvas, _ color: CGColor) {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 8.6, y: 6.6), CGPoint(x: 21.4, y: 3.4), CGPoint(x: 21.4, y: 6.8), CGPoint(x: 8.6, y: 10)])
        p.closeSubpath()
        p.addRect(CGRect(x: 8.6, y: 6.6, width: 2.4, height: 13))
        p.addRect(CGRect(x: 19, y: 4, width: 2.4, height: 12.6))
        p.addEllipse(in: CGRect(x: 3.3, y: 16.8, width: 7.4, height: 6))
        p.addEllipse(in: CGRect(x: 13.7, y: 13.8, width: 7.4, height: 6))
        c.fill(p, color)
    }

    static func home(_ c: Canvas, _ color: CGColor) {
        let p = CGMutablePath()
        p.addLines(between: [
            CGPoint(x: 13, y: 2.8), CGPoint(x: 2.6, y: 11.8), CGPoint(x: 5.2, y: 11.8), CGPoint(x: 5.2, y: 22.8),
            CGPoint(x: 10.4, y: 22.8), CGPoint(x: 10.4, y: 16.6), CGPoint(x: 15.6, y: 16.6), CGPoint(x: 15.6, y: 22.8),
            CGPoint(x: 20.8, y: 22.8), CGPoint(x: 20.8, y: 11.8), CGPoint(x: 23.4, y: 11.8),
        ])
        p.closeSubpath()
        c.fill(p, color)
    }

    static func pin(_ c: Canvas, _ color: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 13, y: 24.4))
        p.addArc(center: CGPoint(x: 13, y: 10.2), radius: 8.4, startAngle: deg(140), endAngle: deg(400), clockwise: false)
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 9.8, y: 7, width: 6.4, height: 6.4))
        c.fill(p, color, evenOdd: true)
    }

    // MARK: Hướng rẽ (hộp 36, nét 4)

    static func turn(_ c: Canvas, _ m: NavInfo.Maneuver, _ color: CGColor, width: CGFloat = 4) {
        let p = CGMutablePath()
        switch m {
        case .right:
            p.move(to: CGPoint(x: 12, y: 32)); p.addLine(to: CGPoint(x: 12, y: 19))
            p.addQuadCurve(to: CGPoint(x: 19, y: 12), control: CGPoint(x: 12, y: 12)); p.addLine(to: CGPoint(x: 29, y: 12))
            p.move(to: CGPoint(x: 23, y: 6)); p.addLine(to: CGPoint(x: 30, y: 12)); p.addLine(to: CGPoint(x: 23, y: 18))
        case .left:
            p.move(to: CGPoint(x: 24, y: 32)); p.addLine(to: CGPoint(x: 24, y: 19))
            p.addQuadCurve(to: CGPoint(x: 17, y: 12), control: CGPoint(x: 24, y: 12)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.move(to: CGPoint(x: 13, y: 6)); p.addLine(to: CGPoint(x: 6, y: 12)); p.addLine(to: CGPoint(x: 13, y: 18))
        case .straight:
            p.move(to: CGPoint(x: 18, y: 32)); p.addLine(to: CGPoint(x: 18, y: 6))
            p.move(to: CGPoint(x: 11, y: 13)); p.addLine(to: CGPoint(x: 18, y: 6)); p.addLine(to: CGPoint(x: 25, y: 13))
        case .uturn:
            p.move(to: CGPoint(x: 24, y: 32)); p.addLine(to: CGPoint(x: 24, y: 15))
            p.addArc(center: CGPoint(x: 17, y: 15), radius: 7, startAngle: 0, endAngle: -.pi, clockwise: true)
            p.addLine(to: CGPoint(x: 10, y: 28))
            p.move(to: CGPoint(x: 4, y: 22)); p.addLine(to: CGPoint(x: 10, y: 29)); p.addLine(to: CGPoint(x: 16, y: 22))
        case .roundabout:
            p.addEllipse(in: CGRect(x: 12, y: 11, width: 12, height: 12))
            p.move(to: CGPoint(x: 18, y: 33)); p.addLine(to: CGPoint(x: 18, y: 23))
            p.move(to: CGPoint(x: 22.5, y: 12.5)); p.addLine(to: CGPoint(x: 27, y: 5))
            p.move(to: CGPoint(x: 21, y: 5)); p.addLine(to: CGPoint(x: 27, y: 5)); p.addLine(to: CGPoint(x: 27.5, y: 11))
        }
        c.stroke(p, color, width: width)
    }

    // MARK: Thời tiết (hộp 40)

    static func weather(_ c: Canvas, _ kind: WeatherInfo.Kind) {
        let sun = RGB(255, 194, 26).cg(), cloud = RGB(230, 230, 230).cg(), rain = RGB(74, 168, 255).cg()
        func cloudPath(_ dy: CGFloat, _ color: CGColor) {
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: 7, y: 14 + dy, width: 12, height: 12))
            p.addEllipse(in: CGRect(x: 13, y: 7 + dy, width: 17, height: 17))
            p.addEllipse(in: CGRect(x: 23, y: 13 + dy, width: 12, height: 12))
            p.addRect(CGRect(x: 13, y: 18 + dy, width: 16, height: 8))
            c.fill(p, color)
        }
        switch kind {
        case .sun:
            c.fillCircle(center: CGPoint(x: 20, y: 20), radius: 8, sun)
            let rays = CGMutablePath()
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                rays.move(to: CGPoint(x: 20 + cos(a) * 12, y: 20 + sin(a) * 12))
                rays.addLine(to: CGPoint(x: 20 + cos(a) * 17, y: 20 + sin(a) * 17))
            }
            c.stroke(rays, sun, width: 3)
        case .cloud:
            c.fillCircle(center: CGPoint(x: 14, y: 15), radius: 6, sun)
            cloudPath(4, cloud)
        case .rain:
            cloudPath(0, RGB(207, 207, 207).cg())
            let drops = CGMutablePath()
            for x in [13.0, 21.0, 29.0] as [CGFloat] {
                drops.move(to: CGPoint(x: x, y: 30)); drops.addLine(to: CGPoint(x: x - 2, y: 35))
            }
            c.stroke(drops, rain, width: 3)
        case .storm:
            cloudPath(-2, RGB(154, 154, 154).cg())
            let bolt = CGMutablePath()
            bolt.addLines(between: [CGPoint(x: 21, y: 22), CGPoint(x: 16, y: 30), CGPoint(x: 21, y: 30), CGPoint(x: 18, y: 38),
                                    CGPoint(x: 27, y: 27), CGPoint(x: 22, y: 27), CGPoint(x: 25, y: 22)])
            bolt.closeSubpath()
            c.fill(bolt, sun)
        case .night:
            c.ctx.saveGState()
            let clip = CGMutablePath()
            clip.addRect(CGRect(x: 0, y: 0, width: 40, height: 40))
            clip.addEllipse(in: CGRect(x: 15, y: 5, width: 22, height: 22))
            c.ctx.addPath(clip)
            c.ctx.clip(using: .evenOdd)
            c.fillCircle(center: CGPoint(x: 19, y: 21), radius: 12, RGB(240, 230, 180).cg())
            c.ctx.restoreGState()
        }
    }

    // MARK: Ô xe (hộp 24)

    static func thermometer(_ c: Canvas, _ color: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 12, y: 3)); p.addLine(to: CGPoint(x: 12, y: 14))
        p.move(to: CGPoint(x: 15, y: 6)); p.addLine(to: CGPoint(x: 18, y: 6))
        p.move(to: CGPoint(x: 15, y: 10)); p.addLine(to: CGPoint(x: 18, y: 10))
        c.stroke(p, color, width: 2.4)
        c.fillCircle(center: CGPoint(x: 12, y: 17.5), radius: 3.6, color)
    }

    static func battery(_ c: Canvas, _ color: CGColor) {
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: 2, y: 7, width: 20, height: 13), cornerWidth: 2, cornerHeight: 2)
        p.move(to: CGPoint(x: 6, y: 4.5)); p.addLine(to: CGPoint(x: 6, y: 7))
        p.move(to: CGPoint(x: 18, y: 4.5)); p.addLine(to: CGPoint(x: 18, y: 7))
        p.move(to: CGPoint(x: 5.5, y: 13.5)); p.addLine(to: CGPoint(x: 9.5, y: 13.5))
        p.move(to: CGPoint(x: 14, y: 13.5)); p.addLine(to: CGPoint(x: 18, y: 13.5))
        p.move(to: CGPoint(x: 16, y: 11.5)); p.addLine(to: CGPoint(x: 16, y: 15.5))
        c.stroke(p, color, width: 2)
    }

    // MARK: Nhạc (hộp 18 / 20 / 48)

    static func skip(_ c: Canvas, forward: Bool, _ color: CGColor) {
        let p = CGMutablePath()
        if forward {
            p.addLines(between: [CGPoint(x: 2, y: 3), CGPoint(x: 9, y: 9), CGPoint(x: 2, y: 15)]); p.closeSubpath()
            p.addLines(between: [CGPoint(x: 8.5, y: 3), CGPoint(x: 15, y: 9), CGPoint(x: 8.5, y: 15)]); p.closeSubpath()
            p.addRect(CGRect(x: 15, y: 3, width: 2, height: 12))
        } else {
            p.addLines(between: [CGPoint(x: 16, y: 3), CGPoint(x: 9, y: 9), CGPoint(x: 16, y: 15)]); p.closeSubpath()
            p.addLines(between: [CGPoint(x: 9.5, y: 3), CGPoint(x: 3, y: 9), CGPoint(x: 9.5, y: 15)]); p.closeSubpath()
            p.addRect(CGRect(x: 1, y: 3, width: 2, height: 12))
        }
        c.fill(p, color)
    }

    static func playPause(_ c: Canvas, playing: Bool, _ color: CGColor) {
        let p = CGMutablePath()
        if playing {
            p.addRect(CGRect(x: 4, y: 3, width: 4, height: 14))
            p.addRect(CGRect(x: 12, y: 3, width: 4, height: 14))
        } else {
            p.addLines(between: [CGPoint(x: 5, y: 3), CGPoint(x: 17, y: 10), CGPoint(x: 5, y: 17)]); p.closeSubpath()
        }
        c.fill(p, color)
    }

    static func bigNote(_ c: Canvas, _ color: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 18, y: 34)); p.addLine(to: CGPoint(x: 18, y: 12)); p.addLine(to: CGPoint(x: 38, y: 8)); p.addLine(to: CGPoint(x: 38, y: 30))
        c.stroke(p, color, width: 3.5)
        c.fillCircle(center: CGPoint(x: 13, y: 34), radius: 5.5, color)
        c.fillCircle(center: CGPoint(x: 33, y: 30), radius: 5.5, color)
    }

    static func speaker(_ c: Canvas, _ color: CGColor) {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 3, y: 9.5), CGPoint(x: 7.5, y: 9.5), CGPoint(x: 13, y: 5), CGPoint(x: 13, y: 21),
                             CGPoint(x: 7.5, y: 16.5), CGPoint(x: 3, y: 16.5)])
        p.closeSubpath()
        c.fill(p, color)
        let w = CGMutablePath()
        w.addArc(center: CGPoint(x: 13, y: 13), radius: 5, startAngle: deg(-50), endAngle: deg(50), clockwise: false)
        w.move(to: CGPoint(x: 13 + 9 * cos(deg(-50)), y: 13 + 9 * sin(deg(-50))))
        w.addArc(center: CGPoint(x: 13, y: 13), radius: 9, startAngle: deg(-50), endAngle: deg(50), clockwise: false)
        c.stroke(w, color, width: 2.4)
    }

    // MARK: Logo đồng hồ tốc độ (viewBox 140 205 744 620; chép từ design/logo/app-icon.svg)

    /// Cung tròn tâm `center`, bán kính `radius`, đi từ điểm `a` tới điểm `b` theo chiều kim đồng hồ trên màn hình.
    /// Vẽ bằng nhiều đoạn thẳng ngắn (2°) để khỏi phụ thuộc quy ước chiều của `addArc`.
    private static func arcPath(center: CGPoint, radius: CGFloat, from a: CGPoint, to b: CGPoint) -> CGPath {
        let a0 = atan2(a.y - center.y, a.x - center.x)
        var a1 = atan2(b.y - center.y, b.x - center.x)
        while a1 <= a0 { a1 += 2 * .pi }
        let steps = max(8, Int((a1 - a0) * 90 / .pi))
        let p = CGMutablePath()
        for i in 0...steps {
            let t = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            let pt = CGPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// Ba cung (hồng, xanh dương, xanh lá) + kim nổi không chạm tâm. Màu phẳng (không chuyển sắc) cho JPEG nhẹ.
    static func logo(_ c: Canvas, in rect: CGRect) {
        let s = min(rect.width / 744, rect.height / 620)
        let w = 744 * s, h = 620 * s
        c.ctx.saveGState()
        c.ctx.translateBy(x: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2)
        c.ctx.scaleBy(x: s, y: s)
        c.ctx.translateBy(x: -140, y: -205)

        let o = CGPoint(x: 512, y: 600)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let pink = RGB(255, 96, 132), blue = RGB(52, 158, 255), green = RGB(64, 214, 106)
        c.stroke(arcPath(center: o, radius: 330, from: pt(226.2, 765), to: pt(282.8, 362.6)), pink.cg(), width: 92)
        c.stroke(arcPath(center: o, radius: 330, from: pt(318, 333), to: pt(706, 333)), blue.cg(), width: 92)
        c.stroke(arcPath(center: o, radius: 330, from: pt(741.2, 362.6), to: pt(797.8, 765)), green.cg(), width: 92)

        // Viền sáng ngoài và trong mỗi cung
        let rimOut = RGB.white.cg(0.6), rimIn = RGB.white.cg(0.18)
        c.stroke(arcPath(center: o, radius: 345, from: pt(196.8, 740.3), to: pt(247.7, 378.2)), rimOut, width: 9)
        c.stroke(arcPath(center: o, radius: 313, from: pt(217.9, 707.1), to: pt(258.8, 416.0)), rimIn, width: 5)
        c.stroke(arcPath(center: o, radius: 345, from: pt(339.5, 301.2), to: pt(684.5, 301.2)), rimOut, width: 9)
        c.stroke(arcPath(center: o, radius: 313, from: pt(374.8, 318.7), to: pt(649.2, 318.7)), rimIn, width: 5)
        c.stroke(arcPath(center: o, radius: 345, from: pt(776.3, 378.2), to: pt(827.2, 740.3)), rimOut, width: 9)
        c.stroke(arcPath(center: o, radius: 313, from: pt(765.2, 416.0), to: pt(806.1, 707.1)), rimIn, width: 5)

        // Kim nổi (đỉnh 366, đáy 588) và vệt sáng
        let needle = CGMutablePath()
        needle.move(to: pt(512, 366))
        needle.addLine(to: pt(562, 574))
        needle.addQuadCurve(to: pt(549, 588), control: pt(563, 588))
        needle.addLine(to: pt(475, 588))
        needle.addQuadCurve(to: pt(462, 574), control: pt(461, 588))
        needle.closeSubpath()
        c.fill(needle, RGB.white.cg(0.82))
        c.stroke(needle, RGB.white.cg(0.92), width: 8)
        let shine = CGMutablePath()
        shine.move(to: pt(512, 408)); shine.addLine(to: pt(484, 560))
        c.stroke(shine, RGB.white.cg(0.7), width: 6)

        // Tâm: vòng mờ + chấm trắng (cách xa chân kim)
        c.fillCircle(center: pt(512, 700), radius: 50, RGB.white.cg(0.16))
        c.strokeCircle(center: pt(512, 700), radius: 50, RGB.white.cg(0.9), width: 8)
        c.fillCircle(center: pt(512, 700), radius: 15, RGB.white.cg())
        c.ctx.restoreGState()
    }

    // MARK: Bản đồ (hộp 48)

    static func foldedMap(_ c: Canvas, line: CGColor) {
        let m = CGMutablePath()
        m.addLines(between: [CGPoint(x: 6, y: 12), CGPoint(x: 17, y: 7), CGPoint(x: 31, y: 12), CGPoint(x: 42, y: 7),
                             CGPoint(x: 42, y: 36), CGPoint(x: 31, y: 41), CGPoint(x: 17, y: 36), CGPoint(x: 6, y: 41)])
        m.closeSubpath()
        c.fill(m, RGB.white.cg())
        let folds = CGMutablePath()
        folds.move(to: CGPoint(x: 17, y: 7)); folds.addLine(to: CGPoint(x: 17, y: 36))
        folds.move(to: CGPoint(x: 31, y: 12)); folds.addLine(to: CGPoint(x: 31, y: 41))
        c.stroke(folds, line, width: 2.5)
        let pin = CGMutablePath()
        pin.move(to: CGPoint(x: 24, y: 33))
        pin.addArc(center: CGPoint(x: 24, y: 21.5), radius: 7, startAngle: deg(140), endAngle: deg(400), clockwise: false)
        pin.closeSubpath()
        c.fill(pin, RGB(224, 32, 27).cg())
        c.stroke(pin, RGB.white.cg(), width: 2)
        c.fillCircle(center: CGPoint(x: 24, y: 21.5), radius: 2.6, RGB.white.cg())
    }
}
