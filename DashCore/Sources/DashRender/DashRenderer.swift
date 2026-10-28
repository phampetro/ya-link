import CoreGraphics
import DashCore
import Foundation

/// Vẽ một khung hình cho đồng hồ từ trạng thái DashUI, theo đúng mockup design/dash/home.html.
/// Toạ độ theo khung 480×234 (đo trên NMAX Tech MAX); chữ tránh nút ＋/－ (x < 56, y 68–168)
/// và thanh dưới của đồng hồ (y ≥ 186).
public struct DashRenderer {
    public struct Input {
        public var width = 480
        public var height = 234
        /// Ảnh nền hiện tại và ảnh trước đó (để mờ dần khi đổi ảnh), `photoFade` 0 → 1.
        public var photo: CGImage?
        public var previousPhoto: CGImage?
        public var photoFade: Double = 1
        public var dim: Double = 0.15
        public var date = Date()
        public init() {}
    }

    static let pageColors = [RGB(255, 45, 85), RGB(10, 132, 255), RGB(48, 209, 88)]   // Nhạc, Home, Bản đồ
    static let warn = RGB(255, 194, 26)
    static let bad = RGB(224, 32, 27)
    static let wheelCenterY: CGFloat = 108
    static let wheelRadius: CGFloat = 53

    public init() {}

    public func render(_ ui: DashUI, now: TimeInterval, input: Input) -> CGImage? {
        guard let c = Canvas(width: input.width, height: input.height) else { return nil }
        let r = ui.wheelPosition(now: now)
        let pc = Self.blendedPageColor(r)
        let page = ui.page
        let welcome = ui.inWelcome(now)
        let entry = ui.sinceWelcomeEnd(now).map { easeOut(($0 - 0.2) / 0.8) } ?? 1   // 0 → 1 sau màn chào

        // Nền
        c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height), RGB(10, 12, 10).cg())
        if !(page == .map && ui.mapOpen && !welcome) {
            if let prev = input.previousPhoto, input.photoFade < 1 {
                c.image(prev, cover: CGRect(x: 0, y: 0, width: c.width, height: c.height))
            }
            if let photo = input.photo {
                c.image(photo, cover: CGRect(x: 0, y: 0, width: c.width, height: c.height), alpha: input.photoFade)
            }
            let dim = welcome ? 0.6 : 0.6 + (input.dim - 0.6) * entry
            c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height), RGB.black.cg(dim))
        }

        if welcome {
            drawWelcome(c, ui, pc: pc, date: input.date, alpha: min(1, (now - (ui.welcomeStart ?? now)) / 0.3))
        } else {
            switch page {
            case .home: drawHome(c, ui, pc: pc, slide: entry)
            case .music: drawMusic(c, ui, pc: pc, now: now)
            case .map:
                if ui.mapOpen { drawMapOpen(c, ui, pc: pc, date: input.date) } else { drawMapCover(c, ui, pc: pc, date: input.date) }
            }
        }

        // Thanh dưới do đồng hồ vẽ (đen ~62 %): tô màu trang vào ảnh ngay dưới nó để thanh ngả màu
        c.fill(CGRect(x: 0, y: 188, width: c.width, height: c.height - 188), pc.cg(0.63))
        drawGlow(c, pc, alpha: welcome ? 0 : entry)
        if !welcome { drawWheel(c, ui, r: r, now: now, entry: entry) }
        return c.makeImage()
    }

    // MARK: - Màu trang

    /// Trộn màu các trang theo vị trí bánh xe, nên khi xoay mọi thứ đổi màu dần.
    static func blendedPageColor(_ r: Double) -> RGB {
        var sum = (0.0, 0.0, 0.0), wsum = 0.0
        for (i, col) in pageColors.enumerated() {
            let w = pow(max(0, cos((Double(i) - r) * 2 * .pi / 3)), 2)
            sum.0 += col.r * w; sum.1 += col.g * w; sum.2 += col.b * w
            wsum += w
        }
        return RGB(sum.0 / wsum, sum.1 / wsum, sum.2 / wsum)
    }

    // MARK: - Màn chào

    private func drawWelcome(_ c: Canvas, _ ui: DashUI, pc: RGB, date: Date, alpha: Double) {
        c.withAlpha(alpha) {
            let cx = c.width / 2
            c.strokeCircle(center: CGPoint(x: cx, y: 58), radius: 19, pc.cg(), width: 3.5)
            let chevron = CGMutablePath()
            chevron.move(to: CGPoint(x: cx - 9, y: 65)); chevron.addLine(to: CGPoint(x: cx, y: 50)); chevron.addLine(to: CGPoint(x: cx + 9, y: 65))
            c.stroke(chevron, RGB.white.cg(), width: 3.5)
            let hour = Calendar.current.component(.hour, from: date)
            c.text(DashUI.greeting(hour: hour), x: cx, y: 84, size: 30, weight: .semibold, color: RGB.white.cg(), align: .center)
            let cool = ui.vehicle.coolantC.map { "\($0)°C" } ?? "--"
            let batt = ui.vehicle.batteryV.map { String(format: "%.1f V", $0) } ?? "--"
            c.text("Máy \(cool) · Ắc quy \(batt) · Sẵn sàng", x: cx, y: 124, size: 17, weight: .medium,
                   color: RGB(230, 230, 230).cg(), maxWidth: 360, align: .center)
        }
    }

    // MARK: - Trang chủ

    private func drawHome(_ c: Canvas, _ ui: DashUI, pc: RGB, slide: Double) {
        c.translated(0, CGFloat(-48 * (1 - slide))) {
            c.fill(CGRect(x: 0, y: 0, width: c.width, height: 42), RGB.black.cg(0.45))
            c.fill(CGRect(x: 0, y: 0, width: c.width, height: 42), pc.cg(0.35))

            // Ô bên phải, xếp từ phải sang trái: ắc quy, nhiệt độ máy, (đang chỉ đường)
            var right = c.width - 8
            let batt = ui.vehicle.batteryV
            right = chip(c, right: right, level: batt.map(DashUI.batteryLevel) ?? .normal, pc: pc,
                         value: batt.map { String(format: "%.1f", $0) } ?? "--", unit: "V") { Icons.battery(c, $0) } - 6
            let cool = ui.vehicle.coolantC
            right = chip(c, right: right, level: cool.map(DashUI.coolantLevel) ?? .normal, pc: pc,
                         value: cool.map { "\($0)" } ?? "--", unit: "°C") { Icons.thermometer(c, $0) } - 6
            if let n = ui.nav {
                let d = DashUI.formatDistance(n.distanceToTurnM)
                right = chip(c, right: right, level: DashUI.turnUrgency(n.distanceToTurnM), pc: pc, value: d.value, unit: d.unit,
                             normalFill: Self.pageColors[2], iconBox: 36) { Icons.turn(c, n.maneuver, $0, width: 4.5) } - 6
            }

            // Thời tiết bên trái, co lại theo chỗ trống; tên dài bị cắt "…"
            if let w = ui.weather {
                c.inBox(40, CGRect(x: 8, y: 7, width: 28, height: 28)) { Icons.weather(c, w.kind) }
                let tw = c.text("\(w.tempC)°", x: 42, y: 6.5, size: 24, weight: .semibold, color: RGB.white.cg())
                let x = 42 + tw + 6
                c.text("\(w.label) · \(w.place)", x: x, y: 11, size: 16, weight: .medium, color: RGB(224, 224, 224).cg(),
                       maxWidth: max(0, right - 4 - x))
            }
        }
    }

    /// Ô bo tròn cao 32 ở dải trên, căn phải tại `right`. Trả về mép trái.
    private func chip(_ c: Canvas, right: CGFloat, level: DashUI.Level, pc: RGB, value: String, unit: String,
                      normalFill: RGB? = nil, iconBox: CGFloat = 24, icon: (CGColor) -> Void) -> CGFloat {
        let vw = c.measure(value, size: 19, weight: .semibold)
        let uw = c.measure(unit, size: 16, weight: .medium)
        let width = 5 + 19 + 3 + vw + 1 + uw + 8
        let rect = CGRect(x: right - width, y: 5, width: width, height: 32)
        let fg: CGColor
        switch level {
        case .warn:
            c.fill(rect, Self.warn.cg(), radius: 8); fg = RGB.black.cg()
        case .bad:
            c.fill(rect, Self.bad.cg(), radius: 8); fg = RGB.white.cg()
        case .normal:
            if let solid = normalFill {
                c.fill(rect, solid.cg(), radius: 8)
            } else {
                c.fill(rect, RGB.black.cg(0.55), radius: 8)
                c.fill(rect, pc.cg(0.32), radius: 8)
            }
            fg = RGB.white.cg()
        }
        c.inBox(iconBox, CGRect(x: rect.minX + 5, y: 11.5, width: 19, height: 19)) { icon(fg) }
        c.text(value, x: rect.minX + 27, y: 9.6, size: 19, weight: .semibold, color: fg)
        let unitColor = level == .normal && normalFill == nil ? RGB(161, 161, 168).cg() : fg
        c.text(unit, x: rect.minX + 27 + vw + 1, y: 11.4, size: 16, weight: .medium, color: unitColor)
        return rect.minX
    }

    // MARK: - Trang Nhạc

    private func drawMusic(_ c: Canvas, _ ui: DashUI, pc: RGB, now: TimeInterval) {
        c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height), RGB.black.cg(0.5))
        c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height), pc.cg(0.14))
        var flashing: DashUI.FlashTarget?
        if let f = ui.flash, now - f.at < 0.4 { flashing = f.target }

        if ui.volumeMode {
            c.inBox(26, CGRect(x: 66, y: 36, width: 26, height: 26)) { Icons.speaker(c, RGB.white.cg()) }
            let bar = CGRect(x: 66, y: 68, width: 26, height: 80)
            c.fill(bar, RGB.black.cg(0.5), radius: 13)
            c.ctx.saveGState()
            c.ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 13, cornerHeight: 13, transform: nil))
            c.ctx.clip()
            let h = bar.height * CGFloat(ui.volume) / 100
            c.fill(CGRect(x: bar.minX, y: bar.maxY - h, width: bar.width, height: h), pc.cg())
            c.ctx.restoreGState()
        } else {
            for (forward, y) in [(true, CGFloat(67)), (false, CGFloat(114))] {
                let target: DashUI.FlashTarget = forward ? .next : .previous
                let on = flashing == target
                let s: CGFloat = on ? 1.15 : 1
                let center = CGPoint(x: 79, y: y + 17)
                c.fillCircle(center: center, radius: 17 * s, on ? pc.cg() : RGB.black.cg(0.5))
                c.inBox(18, CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)) {
                    Icons.skip(c, forward: forward, RGB.white.cg())
                }
            }
        }

        let art = CGRect(x: 108, y: 22, width: 92, height: 92)
        c.fill(art, pc.cg(0.35), radius: 12)
        c.inBox(48, art.insetBy(dx: 23, dy: 23)) { Icons.bigNote(c, RGB.white.cg()) }

        let m = ui.music
        c.text(m?.title ?? "Chưa phát nhạc", x: 214, y: 22, size: 22, weight: .semibold, color: RGB.white.cg(), maxWidth: 196)
        c.text(m?.artist ?? "Mở Apple Music trên iPhone", x: 214, y: 51, size: 17, weight: .medium,
               color: RGB(224, 224, 224).cg(), maxWidth: 196)

        let playing = m?.playing ?? false
        let ps: CGFloat = flashing == DashUI.FlashTarget.play ? 1.15 : 1
        c.fillCircle(center: CGPoint(x: 236, y: 104), radius: 22 * ps, pc.cg())
        c.inBox(20, CGRect(x: 226, y: 94, width: 20, height: 20)) { Icons.playPause(c, playing: playing, RGB.white.cg()) }
        let state = ui.volumeMode ? "Âm lượng \(ui.volume)%" : playing ? "Đang phát" : "Tạm dừng"
        c.text(state, x: 268, y: 94, size: 17, weight: .semibold, color: RGB.white.cg())

        let track = CGRect(x: 108, y: 148, width: 302, height: 6)
        c.fill(track, RGB.white.cg(0.22), radius: 3)
        if let m = m, m.duration > 0 {
            let w = track.width * CGFloat(min(1, max(0, m.position / m.duration)))
            c.fill(CGRect(x: track.minX, y: track.minY, width: w, height: 6), pc.cg(), radius: 3)
            c.text(Self.mmss(m.position), x: 108, y: 160, size: 16, weight: .medium, color: RGB(224, 224, 224).cg())
            c.text(Self.mmss(m.duration), x: 410, y: 160, size: 16, weight: .medium, color: RGB(224, 224, 224).cg(), align: .right)
        }
    }

    static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Bản đồ

    private func drawMapCover(_ c: Canvas, _ ui: DashUI, pc: RGB, date: Date) {
        c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height), RGB.black.cg(0.55))
        c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height), pc.cg(0.12))
        let tile = CGRect(x: 70, y: 51, width: 84, height: 84)
        for i in 1...4 {   // ánh sáng quanh ô
            c.fill(tile.insetBy(dx: CGFloat(-3 * i), dy: CGFloat(-3 * i)), pc.cg(0.1), radius: 20 + CGFloat(3 * i))
        }
        c.fill(tile, pc.cg(), radius: 20)
        c.inBox(48, tile.insetBy(dx: 14, dy: 14)) { Icons.foldedMap(c, line: pc.cg()) }

        let x: CGFloat = 170, maxW: CGFloat = 244
        c.text("Bản đồ", x: x, y: 37, size: 28, weight: .semibold, color: RGB.white.cg())
        var l1 = "Chưa chỉ đường", l2 = "Chia sẻ địa điểm từ Google Maps"
        if let n = ui.nav {
            l1 = "Tới \(n.destination)"
            l2 = "\(Self.km(n.remainingKm)) km · đến lúc \(Self.hhmm(n.eta))"
        }
        c.text(l1, x: x, y: 75, size: 17, weight: .medium, color: RGB(230, 230, 230).cg(), maxWidth: maxW)
        c.text(l2, x: x, y: 101, size: 17, weight: .medium, color: RGB(230, 230, 230).cg(), maxWidth: maxW)
        c.text("Nhấn Enter để mở", x: x, y: 127, size: 16, weight: .semibold, color: pc.cg())
    }

    /// Bản đồ đang mở. Chưa có dữ liệu bản đồ thật: vẽ sơ đồ tuyến theo mức zoom (đường lớn, đường nhỏ,
    /// tuyến màu trang). Bản đồ vector (OpenFreeMap) sẽ thay phần sơ đồ này.
    private func drawMapOpen(_ c: Canvas, _ ui: DashUI, pc: RGB, date: Date) {
        let z = CGFloat(DashUI.zoomScales[ui.zoom])
        func X(_ x: CGFloat) -> CGFloat { 238 + x * z }
        func Y(_ y: CGFloat) -> CGFloat { 160 + y * z }
        let wMaj: CGFloat = [5, 7, 11, 14, 18, 22][ui.zoom], wMin: CGFloat = [0, 0, 5, 7, 9, 11][ui.zoom]
        let wRoute: CGFloat = [5, 6, 8, 10, 12, 14][ui.zoom]

        if ui.zoom >= 2 {
            let minor = CGMutablePath()
            for k in stride(from: -1320 as CGFloat, through: 1320, by: 110) {
                minor.move(to: CGPoint(x: X(k + 50), y: Y(-1600))); minor.addLine(to: CGPoint(x: X(k + 50), y: Y(1600)))
                minor.move(to: CGPoint(x: X(-1600), y: Y(k - 20))); minor.addLine(to: CGPoint(x: X(1600), y: Y(k - 20)))
            }
            c.stroke(minor, RGB(31, 34, 31).cg(), width: wMin)
        }
        let major = CGMutablePath()
        for (a, b) in [((0, 1600), (0, -1600)), ((-1600, -68), (1600, -68)), ((-1600, -420), (1600, -420)),
                       ((-380, 1600), (-380, -1600)), ((600, 1600), (600, -1600)), ((-1400, 700), (1200, -900))]
            as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
            major.move(to: CGPoint(x: X(a.0), y: Y(a.1))); major.addLine(to: CGPoint(x: X(b.0), y: Y(b.1)))
        }
        c.stroke(major, RGB(56, 60, 56).cg(), width: wMaj)

        let route: [(CGFloat, CGFloat)] = [(0, 160), (0, 0), (0, -44), (4, -58), (12, -65), (24, -68), (600, -68), (600, -420), (900, -420)]
        let passed = CGMutablePath(), ahead = CGMutablePath()
        passed.move(to: CGPoint(x: X(route[0].0), y: Y(route[0].1))); passed.addLine(to: CGPoint(x: X(route[1].0), y: Y(route[1].1)))
        ahead.addLines(between: route.dropFirst().map { CGPoint(x: X($0.0), y: Y($0.1)) })
        c.stroke(passed, RGB(90, 93, 90).cg(), width: wRoute)
        c.stroke(ahead, pc.cg(), width: wRoute)

        let me = CGMutablePath()
        me.addLines(between: [CGPoint(x: 238, y: 146), CGPoint(x: 225, y: 172), CGPoint(x: 238, y: 165), CGPoint(x: 251, y: 172)])
        me.closeSubpath()
        c.fill(me, RGB.white.cg())
        c.stroke(me, RGB(10, 12, 10).cg(), width: 3)
        c.fill(me, RGB.white.cg())

        guard let n = ui.nav else {
            c.text("Chưa chỉ đường", x: 240, y: 8, size: 17, weight: .semibold, color: RGB.white.cg(), align: .center)
            return
        }

        // Ô hướng rẽ (góc trên trái), đổi màu theo khoảng cách
        let d = DashUI.formatDistance(n.distanceToTurnM)
        let urgency = DashUI.turnUrgency(n.distanceToTurnM)
        let tileColor = urgency == .bad ? Self.bad : urgency == .warn ? Self.warn : pc
        let glyph = urgency == .warn ? RGB.black.cg() : RGB.white.cg()
        let dw = c.measure(d.value, size: 26, weight: .bold) + 2 + c.measure(d.unit, size: 16, weight: .semibold)
        let sw = min(92, c.measure(n.nextStreet, size: 16, weight: .semibold))
        let card = CGRect(x: 6, y: 6, width: 52 + 8 + max(dw, sw) + 12, height: 52)
        c.fill(card, RGB.black.cg(0.72), radius: 12)
        c.fill(CGRect(x: 6, y: 6, width: 52, height: 52), tileColor.cg(), radius: 12)
        c.inBox(36, CGRect(x: 14, y: 14, width: 36, height: 36)) { Icons.turn(c, n.maneuver, glyph) }
        let vw = c.text(d.value, x: 66, y: 7, size: 26, weight: .bold, color: RGB.white.cg())
        c.text(d.unit, x: 66 + vw + 2, y: 14, size: 16, weight: .semibold, color: RGB.white.cg())
        c.text(n.nextStreet, x: 66, y: 36, size: 16, weight: .semibold, color: RGB(224, 224, 224).cg(), maxWidth: 92)

        // Giờ đến và quãng đường còn lại (giữa trên)
        let t1 = Self.hhmm(n.eta), t2 = " · \(Self.km(n.remainingKm)) km"
        let w1 = c.measure(t1, size: 17, weight: .semibold), w2 = c.measure(t2, size: 17, weight: .medium)
        let eta = CGRect(x: 240 - (w1 + w2 + 20) / 2, y: 6, width: w1 + w2 + 20, height: 30)
        c.fill(eta, RGB.black.cg(0.72), radius: 9)
        c.text(t1, x: eta.minX + 10, y: 11.8, size: 17, weight: .semibold, color: RGB.white.cg())
        c.text(t2, x: eta.minX + 10 + w1, y: 11.8, size: 17, weight: .medium, color: RGB(200, 200, 200).cg())

        // Biển tốc độ do app tự vẽ (góc trên phải, 44 px); biển gốc của đồng hồ để tắt (cmd 17 = 0)
        if let limit = n.speedLimit {
            let center = CGPoint(x: c.width - 30, y: 28)
            c.fillCircle(center: center, radius: 22, RGB.white.cg())
            c.strokeCircle(center: center, radius: 19.5, Self.bad.cg(), width: 5)
            c.text("\(limit)", x: center.x, y: center.y - 10.2, size: 17, weight: .bold, color: RGB.black.cg(), align: .center)
        }
    }

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func km(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Ánh màu mép khung, menu bánh xe

    private func drawGlow(_ c: Canvas, _ pc: RGB, alpha: Double) {
        guard alpha > 0 else { return }
        let steps = 14
        for i in 0..<steps {
            let k = 1 - Double(i) / Double(steps)
            let inset = CGFloat(i * 2) + 1
            c.ctx.setStrokeColor(pc.cg(0.42 * k * k * alpha))
            c.ctx.setLineWidth(2)
            c.ctx.stroke(CGRect(x: 0, y: 0, width: c.width, height: c.height).insetBy(dx: inset, dy: inset))
        }
    }

    private func drawWheel(_ c: Canvas, _ ui: DashUI, r: Double, now: TimeInterval, entry: Double) {
        // Trượt ra khi mở bản đồ, trượt vào khi thoát; trượt vào sau màn chào
        let t = now - ui.mapToggledAt
        var slide = ui.mapOpen ? easeOut(t / 0.4) : 1 - easeOut(t / 0.4)
        slide = max(slide, 1 - entry)
        guard slide < 1 else { return }

        var items: [(i: Int, front: Double, y: CGFloat)] = []
        for i in 0..<3 {
            let a = (Double(i) - r) * 2 * .pi / 3
            items.append((i, (cos(a) + 1) / 2, Self.wheelCenterY + Self.wheelRadius * CGFloat(sin(a))))
        }
        for item in items.sorted(by: { $0.front < $1.front }) {
            let op = pow(item.front, 0.35)
            guard op > 0.02 else { continue }
            let s = CGFloat(0.7 + 0.3 * item.front)
            let x = 450 + CGFloat(70 * slide)
            let rect = CGRect(x: x - 22 * s, y: item.y - 20 * s, width: 44 * s, height: 40 * s)
            c.withAlpha(op) {
                c.fill(rect, Self.pageColors[item.i].cg(), radius: 10 * s)
                let g = CGRect(x: x - 13 * s, y: item.y - 13 * s, width: 26 * s, height: 26 * s)
                c.inBox(26, g) {
                    switch item.i {
                    case 0: Icons.music(c, RGB.white.cg())
                    case 1: Icons.home(c, RGB.white.cg())
                    default: Icons.pin(c, RGB.white.cg())
                    }
                }
            }
        }
    }
}

func easeOut(_ x: Double) -> Double {
    let k = min(1, max(0, x))
    return 1 - pow(1 - k, 3)
}
