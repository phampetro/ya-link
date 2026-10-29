import CoreGraphics
import DashCore
import Foundation

/// Cảnh bản đồ cần vẽ: vị trí xe, hướng đi (heading-up: hướng đi luôn ở phía trên), tuyến, điểm đến.
public struct MapScene {
    public var center: MapPoint
    public var headingDeg: Double
    public var route: [MapPoint]
    public var passedIndex: Int
    public var destination: MapPoint?
    public var store: TileStore
    /// Tên đường dọc tuyến (Route.streetSpans, chỉ số theo `route`); rỗng thì không có nhãn "đi thẳng".
    public var streetSpans: [StreetSpan]

    public init(center: MapPoint, headingDeg: Double, route: [MapPoint], passedIndex: Int,
                destination: MapPoint?, store: TileStore, streetSpans: [StreetSpan] = []) {
        self.center = center
        self.headingDeg = headingDeg
        self.route = route
        self.passedIndex = passedIndex
        self.destination = destination
        self.store = store
        self.streetSpans = streetSpans
    }
}

/// Điểm trên mặt đất theo toạ độ màn hình phẳng, gốc ở mũi tên xe: `u` sang phải, `d` về phía trước
/// (đơn vị điểm ảnh ở tỉ lệ tại mũi tên, nên mức zoom của DashUI vẫn có nghĩa là "tỉ lệ ngay chỗ mũi tên").
struct GP {
    var u: Double
    var d: Double
}

/// Vẽ bản đồ vector (OpenFreeMap, lược đồ OpenMapTiles) bằng CPU. Mỗi mức zoom vẽ lại với chi tiết khác nhau:
/// xa (0–1) đường lớn + tên quận · vừa (2–3) thêm đường nhỏ + tên đường · gần (4–5) thêm hẻm, cây xăng, bệnh viện, nhà.
/// Chế độ nghiêng: bản đồ phẳng được chiếu phối cảnh (camera nghiêng `tiltDeg` độ), mũi tên nằm thấp, đường phía trước
/// thu nhỏ dần rồi mờ vào nền.
enum MapRenderer {
    /// Mét trên mỗi điểm ảnh theo mức zoom của DashUI (2 km … 150 m).
    static let metersPerPixel: [Double] = [9.0, 4.5, 2.6, 1.7, 1.0, 0.6]

    /// Độ rộng nét đường (điểm ảnh) theo bậc đường (0 lớn … 3 nhỏ) và mức zoom; 0 = ẩn.
    static let widths: [[CGFloat]] = [
        [5, 7, 10, 13, 17, 22],
        [0, 4, 7, 10, 13, 17],
        [0, 0, 5, 7, 9, 12],
        [0, 0, 0, 0, 4, 6],
    ]
    static let roadColors: [RGB] = [RGB(56, 60, 56), RGB(46, 50, 46), RGB(31, 34, 31), RGB(22, 25, 22)]
    static let water = RGB(12, 27, 43)
    static let green = RGB(13, 26, 16)
    static let building = RGB(20, 23, 20)
    static let background = RGB(10, 12, 10)

    // Phối cảnh: camera nghiêng `tiltDeg` so với nhìn thẳng xuống, cách điểm xoay (mũi tên) `camDist` điểm ảnh.
    static let tiltDeg = 52.0
    static let camDist = 330.0
    static let sinT = sin(52.0 * Double.pi / 180)
    static let cosT = cos(52.0 * Double.pi / 180)
    /// Phía sau mũi tên: cắt mặt đất ở d = nearD (đã nằm ngoài màn hình) để phép chiếu không bị méo.
    static let nearD = -120.0

    /// Vùng bị đồng hồ hoặc ô thông tin che: không đặt chữ và icon ở đây.
    static let busyZones: [CGRect] = [
        CGRect(x: 0, y: 64, width: 60, height: 108), CGRect(x: 0, y: 182, width: 480, height: 60),
        CGRect(x: 0, y: 0, width: 182, height: 62), CGRect(x: 172, y: 0, width: 136, height: 42),
        CGRect(x: 420, y: 0, width: 60, height: 56),
    ]

    struct View {
        let z: Int
        let cx: Double, cy: Double      // tâm trong toạ độ thế giới ở mức z
        let k: Double                   // điểm ảnh màn hình trên mỗi điểm ảnh thế giới
        let cosH: Double, sinH: Double
        let tilt: Bool

        /// Mặt đất phía sau d = nearD bị cắt bỏ khi nghiêng.
        var nearD: Double { tilt ? MapRenderer.nearD : -Double.infinity }

        func ground(worldX: Double, worldY: Double) -> GP {
            let dx = (worldX - cx) * k, dy = (worldY - cy) * k
            return GP(u: dx * cosH + dy * sinH, d: dx * sinH - dy * cosH)
        }

        func ground(_ p: MapPoint) -> GP {
            let w = Mercator.worldPixel(p, zoom: Double(z))
            return ground(worldX: w.x, worldY: w.y)
        }

        /// Tỉ lệ thu nhỏ theo khoảng cách d (1 tại mũi tên).
        func scale(_ d: Double) -> Double {
            guard tilt else { return 1 }
            return MapRenderer.camDist / max(40, MapRenderer.camDist + d * MapRenderer.sinT)
        }

        /// Chiếu mặt đất lên màn hình.
        func project(_ g: GP) -> CGPoint {
            guard tilt else { return CGPoint(x: 238 + g.u, y: 160 - g.d) }
            let z = MapRenderer.camDist + g.d * MapRenderer.sinT
            let s = MapRenderer.camDist / max(40, z)
            return CGPoint(x: 238 + g.u * s, y: 160 - g.d * MapRenderer.cosT * s)
        }

        func screen(worldX: Double, worldY: Double) -> CGPoint {
            project(ground(worldX: worldX, worldY: worldY))
        }

        func screen(_ p: MapPoint) -> CGPoint {
            project(ground(p))
        }

        /// Dải độ rộng (tỉ lệ ×10, 2…16) của một đoạn nằm giữa hai độ sâu; phẳng thì luôn 10.
        func band(_ d0: Double, _ d1: Double) -> Int {
            guard tilt else { return 10 }
            let s = scale((d0 + d1) / 2)
            return max(2, min(16, Int((s * 10).rounded())))
        }
    }

    static func makeView(_ scene: MapScene, zoomIndex zi: Int, tilt: Bool = false) -> View {
        let mpp = metersPerPixel[max(0, min(metersPerPixel.count - 1, zi))]
        let lat = scene.center.lat
        let ideal = log2(156543.03392 * cos(lat * .pi / 180) / mpp)
        let z = max(0, min(14, Int(ideal.rounded())))
        let cw = Mercator.worldPixel(scene.center, zoom: Double(z))
        let res = Mercator.metersPerPixel(lat: lat, zoom: Double(z))
        let h = scene.headingDeg * .pi / 180
        return View(z: z, cx: cw.x, cy: cw.y, k: res / mpp, cosH: cos(h), sinH: sin(h), tilt: tilt)
    }

    // MARK: - Cắt hình ở mép sau (d ≥ near)

    private static func crossing(_ a: GP, _ b: GP, _ near: Double) -> GP {
        let t = (near - a.d) / (b.d - a.d)
        return GP(u: a.u + (b.u - a.u) * t, d: near)
    }

    static func clipLine(_ g: [GP], near: Double) -> [[GP]] {
        if g.allSatisfy({ $0.d >= near }) { return [g] }
        var out: [[GP]] = []
        var cur: [GP] = []
        for i in 0..<g.count {
            let b = g[i]
            if i == 0 {
                if b.d >= near { cur = [b] }
                continue
            }
            let a = g[i - 1]
            let ain = a.d >= near, bin = b.d >= near
            if ain && bin {
                cur.append(b)
            } else if ain {
                cur.append(crossing(a, b, near))
                out.append(cur)
                cur = []
            } else if bin {
                cur = [crossing(a, b, near), b]
            }
        }
        if cur.count >= 2 { out.append(cur) }
        return out
    }

    static func clipPolygon(_ g: [GP], near: Double) -> [GP] {
        if g.allSatisfy({ $0.d >= near }) { return g }
        var out: [GP] = []
        for i in 0..<g.count {
            let a = g[i], b = g[(i + 1) % g.count]
            let ain = a.d >= near, bin = b.d >= near
            if ain {
                out.append(a)
                if !bin { out.append(crossing(a, b, near)) }
            } else if bin {
                out.append(crossing(a, b, near))
            }
        }
        return out
    }

    /// Thêm đường gấp khúc vào các path theo dải độ rộng (nét thu nhỏ theo khoảng cách khi nghiêng).
    static func addBanded(_ g: [GP], _ v: View, into paths: inout [Int: CGMutablePath]) {
        for piece in clipLine(g, near: v.nearD) where piece.count >= 2 {
            var prevBand = -1
            var prev = v.project(piece[0])
            for i in 1..<piece.count {
                let b = v.project(piece[i])
                let band = v.band(piece[i - 1].d, piece[i].d)
                let path: CGMutablePath
                if let p = paths[band] {
                    path = p
                } else {
                    path = CGMutablePath()
                    paths[band] = path
                }
                if band != prevBand {
                    path.move(to: prev)
                    prevBand = band
                }
                path.addLine(to: b)
                prev = b
            }
        }
    }

    static func strokeBanded(_ c: Canvas, _ g: [GP], _ v: View, color: CGColor, width: CGFloat) {
        var paths: [Int: CGMutablePath] = [:]
        addBanded(g, v, into: &paths)
        for band in paths.keys.sorted() {
            guard let path = paths[band] else { continue }
            c.stroke(path, color, width: max(2, width * CGFloat(band) / 10))
        }
    }

    /// Mờ dần vào nền ở mép xa của bản đồ nghiêng (không có đường chân trời, không có bầu trời).
    static func drawFarFade(_ c: Canvas) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let colors = [background.cg(1), background.cg(0.6), background.cg(0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) else { return }
        let h: CGFloat = 92
        c.ctx.saveGState()
        c.ctx.clip(to: CGRect(x: 0, y: 0, width: c.width, height: h))
        c.ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        c.ctx.restoreGState()
    }

    static func draw(_ c: Canvas, scene: MapScene, zoomIndex zi: Int, pc: RGB, tilt: Bool = false) {
        let v = makeView(scene, zoomIndex: zi, tilt: tilt)
        let navigating = scene.route.count >= 2
        let ct = Mercator.tile(scene.center, z: v.z)
        let reach = tilt ? 700.0 : 300.0
        let n = min(2, max(1, Int(ceil(reach / v.k / 256))))
        let limit = 1 << v.z
        var tiles: [(tx: Int, ty: Int, tile: MVTTile)] = []
        for ty in (ct.y - n)...(ct.y + n) {
            for tx in (ct.x - n)...(ct.x + n) where tx >= 0 && ty >= 0 && tx < limit && ty < limit {
                if let t = scene.store.tile(z: v.z, x: tx, y: ty) { tiles.append((tx, ty, t)) }
            }
        }

        func gp(_ p: MVTPoint, _ tx: Int, _ ty: Int, _ extent: Int) -> GP {
            let e = Double(extent)
            return v.ground(worldX: (Double(tx) + Double(p.x) / e) * 256, worldY: (Double(ty) + Double(p.y) / e) * 256)
        }

        /// Điểm đặt chữ / icon; khi nghiêng bỏ điểm ở sau xe hoặc ở vùng xa bị ép dẹt (đã mờ).
        func labelPoint(_ p: MVTPoint, _ tx: Int, _ ty: Int, _ extent: Int) -> CGPoint? {
            let g = gp(p, tx, ty, extent)
            let s = v.project(g)
            if tilt && (g.d < -60 || s.y < 56) { return nil }
            return s
        }

        func polygonPath(_ f: MVTFeature, _ tx: Int, _ ty: Int, _ extent: Int) -> CGPath {
            let path = CGMutablePath()
            for ring in f.geometry where ring.count >= 3 {
                let g = clipPolygon(ring.map { gp($0, tx, ty, extent) }, near: v.nearD)
                if g.count >= 3 {
                    path.addLines(between: g.map { v.project($0) })
                    path.closeSubpath()
                }
            }
            return path
        }

        func eachFeature(_ layer: String, _ body: (MVTFeature, Int, Int, Int) -> Void) {
            for t in tiles {
                guard let l = t.tile.layers[layer] else { continue }
                for f in l.features { body(f, t.tx, t.ty, l.extent) }
            }
        }

        // Nước, công viên
        eachFeature("water") { f, tx, ty, e in
            if f.kind == .polygon { c.fill(polygonPath(f, tx, ty, e), water.cg(), evenOdd: true) }
        }
        let greenClasses: Set<String> = ["grass", "wood", "forest", "park", "garden", "cemetery", "pitch", "playground"]
        for layer in ["landcover", "landuse", "park"] {
            eachFeature(layer) { f, tx, ty, e in
                guard f.kind == .polygon else { return }
                if layer != "park", !greenClasses.contains(f.properties["class"]?.stringValue ?? "") { return }
                c.fill(polygonPath(f, tx, ty, e), green.cg(), evenOdd: true)
            }
        }
        if zi >= 5 {
            eachFeature("building") { f, tx, ty, e in
                if f.kind == .polygon { c.fill(polygonPath(f, tx, ty, e), building.cg(), evenOdd: true) }
            }
        }

        // Đường: gom theo bậc (và theo dải khoảng cách khi nghiêng), vẽ bậc nhỏ trước để đường lớn đè lên
        var tierBands = [[Int: CGMutablePath]](repeating: [:], count: 4)
        eachFeature("transportation") { f, tx, ty, e in
            guard f.kind == .line, let t = roadTier(f.properties["class"]?.stringValue), widths[t][zi] > 0 else { return }
            for part in f.geometry where part.count >= 2 {
                addBanded(part.map { gp($0, tx, ty, e) }, v, into: &tierBands[t])
            }
        }
        for t in stride(from: 3, through: 0, by: -1) where widths[t][zi] > 0 {
            for band in tierBands[t].keys.sorted() {
                guard let path = tierBands[t][band] else { continue }
                c.stroke(path, roadColors[t].cg(), width: max(1, widths[t][zi] * CGFloat(band) / 10))
            }
        }

        // Tuyến: đoạn đã qua xám, đoạn còn lại màu trang
        let wRoute: CGFloat = [5, 6, 8, 10, 12, 14][zi]
        let rg = scene.route.map { v.ground($0) }
        if rg.count >= 2 {
            let cut = max(0, min(rg.count - 1, scene.passedIndex))
            if cut >= 1 {
                strokeBanded(c, Array(rg[0...cut]), v, color: RGB(90, 93, 90).cg(), width: wRoute)
            }
            strokeBanded(c, Array(rg[cut...]), v, color: pc.cg(), width: wRoute)
        }

        if tilt { drawFarFade(c) }

        // Nhãn và icon: chỉ vẽ khi không đè vùng bị che
        var busy = busyZones
        func place(_ rect: CGRect) -> Bool {
            if rect.minX < 4 || rect.minY < 0 || rect.maxX > 476 || rect.maxY > 234 { return false }
            if busy.contains(where: { $0.intersects(rect) }) { return false }
            busy.append(rect)
            return true
        }
        func pill(_ text: String, at p: CGPoint, bg: CGColor, fg: CGColor) {
            let w = c.measure(text, size: 16, weight: .semibold) + 14
            let r = CGRect(x: p.x - w / 2, y: p.y - 11, width: w, height: 22)
            guard place(r) else { return }
            c.fill(r, bg, radius: 7)
            c.text(text, x: p.x, y: r.minY + 1.6, size: 16, weight: .semibold, color: fg, align: .center)
        }

        // Điểm đến (ghim đứng thẳng, nhỏ dần theo khoảng cách khi nghiêng)
        if let d = scene.destination {
            let g = v.ground(d)
            let p = v.project(g)
            if g.d >= v.nearD && p.x > 8 && p.x < 472 && p.y > 24 && p.y < 230 {
                let ps = CGFloat(tilt ? max(0.6, min(1, v.scale(g.d))) : 1)
                let pin = CGMutablePath()
                pin.move(to: p)
                pin.addLine(to: CGPoint(x: p.x - 9 * ps, y: p.y - 14 * ps))
                pin.addArc(center: CGPoint(x: p.x, y: p.y - 14 * ps), radius: 10.5 * ps, startAngle: .pi * 0.8,
                           endAngle: .pi * 0.2, clockwise: false)
                pin.closeSubpath()
                c.fill(pin, RGB(224, 32, 27).cg())
                c.stroke(pin, RGB.white.cg(), width: 2)
                c.fillCircle(center: CGPoint(x: p.x, y: p.y - 19 * ps), radius: 3.5 * ps, RGB.white.cg())
            }
        }

        if zi <= 1 {
            let suburbs: Set<String> = ["suburb", "quarter", "neighbourhood", "city_district"]
            var seen = Set<String>()
            eachFeature("place") { f, tx, ty, e in
                guard let cls = f.properties["class"]?.stringValue, suburbs.contains(cls),
                      let name = f.properties["name"]?.stringValue, !seen.contains(name),
                      let first = f.geometry.first?.first, let p = labelPoint(first, tx, ty, e) else { return }
                let w = c.measure(name.uppercased(), size: 17, weight: .bold) + 8
                let r = CGRect(x: p.x - w / 2, y: p.y - 11, width: w, height: 22)
                guard place(r) else { return }
                seen.insert(name)
                c.text(name.uppercased(), x: p.x, y: r.minY + 1, size: 17, weight: .bold, color: RGB(154, 159, 154).cg(), align: .center)
            }
        }
        if navigating && zi >= 1 {
            // Đang dẫn đường: chỉ tên đường phía trước (không có tên đường quanh xe, không có tên đường đang đi)
            let labels = aheadLabels(scene: scene, v: v, zi: zi, tiles: tiles)
            drawAheadLabels(c, labels: labels, scene: scene, v: v, tilt: tilt, routeWidth: wRoute, place: place)
        }
        if !navigating && zi >= 2 {
            // Mỗi đường có tên: lấy mẫu các đỉnh của mọi đoạn, giữ đỉnh nằm trong vùng nhìn thấy và cách mũi tên đủ xa,
            // chọn đỉnh gần mũi tên (nghiêng) hoặc gần tâm màn hình (phẳng) nhất.
            let winMinX = 50.0, winMaxX = 430.0
            let winMinY = tilt ? 66.0 : 14.0, winMaxY = 180.0
            let ref = tilt ? CGPoint(x: 238, y: 160) : CGPoint(x: 240, y: 97)
            var found: [(name: String, p: CGPoint, dist: Double)] = []
            eachFeature("transportation_name") { f, tx, ty, e in
                guard f.kind == .line, let name = f.properties["name"]?.stringValue,
                      let tier = roadTier(f.properties["class"]?.stringValue), tier <= 2 else { return }
                var best: CGPoint?
                var bestScore = Double.infinity
                for part in f.geometry where part.count >= 2 {
                    // ~40 đỉnh mỗi đoạn; đoạn thẳng dài (ô chỉ có hai đỉnh ở hai mép) được chia nhỏ để vẫn có điểm trong vùng nhìn.
                    let step = max(1, part.count / 40)
                    var samples: [MVTPoint] = []
                    var i = 0
                    while i < part.count {
                        samples.append(part[i])
                        if step == 1, i + 1 < part.count {
                            let a = part[i], b = part[i + 1]
                            let segLen = hypot(Double(b.x - a.x), Double(b.y - a.y))
                            let subs = min(32, max(1, Int(segLen / (Double(e) / 64))))
                            if subs > 1 {
                                for j in 1..<subs {
                                    let t = Double(j) / Double(subs)
                                    samples.append(MVTPoint(x: a.x + Int((Double(b.x - a.x) * t).rounded()),
                                                            y: a.y + Int((Double(b.y - a.y) * t).rounded())))
                                }
                            }
                        }
                        i += step
                    }
                    for sp in samples {
                        guard let s = labelPoint(sp, tx, ty, e),
                              Double(s.x) >= winMinX, Double(s.x) <= winMaxX,
                              Double(s.y) >= winMinY, Double(s.y) <= winMaxY,
                              hypot(Double(s.x) - 238, Double(s.y) - 160) >= 34 else { continue }
                        let score = hypot(Double(s.x) - Double(ref.x), Double(s.y) - Double(ref.y))
                        if score < bestScore {
                            bestScore = score
                            best = s
                        }
                    }
                }
                if let b = best {
                    found.append((name, b, hypot(Double(b.x) - 238, Double(b.y) - 160)))
                }
            }
            found.sort { $0.dist < $1.dist }
            var seen = Set<String>()
            var cands: [(name: String, p: CGPoint)] = []
            for item in found where !seen.contains(item.name) {
                seen.insert(item.name)
                cands.append((item.name, item.p))
            }
            seen.removeAll()
            var placed = 0
            for cand in cands where !seen.contains(cand.name) {
                if tilt && placed >= 6 { break }
                let w = c.measure(cand.name, size: 16, weight: .semibold) + 14
                if place(CGRect(x: cand.p.x - w / 2, y: cand.p.y - 11, width: w, height: 22)) {
                    seen.insert(cand.name)
                    placed += 1
                    c.fill(CGRect(x: cand.p.x - w / 2, y: cand.p.y - 11, width: w, height: 22), RGB.black.cg(0.75), radius: 7)
                    c.text(cand.name, x: cand.p.x, y: cand.p.y - 9.4, size: 16, weight: .semibold, color: RGB(216, 216, 216).cg(), align: .center)
                }
            }
        }
        if zi >= 4 {
            eachFeature("poi") { f, tx, ty, e in
                guard let cls = f.properties["class"]?.stringValue, cls == "fuel" || cls == "hospital",
                      let first = f.geometry.first?.first, let p = labelPoint(first, tx, ty, e) else { return }
                let r = CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)
                guard place(r) else { return }
                if cls == "fuel" {
                    c.fill(r, RGB(230, 149, 0).cg(), radius: 6)
                    let g = CGMutablePath()
                    g.addRect(CGRect(x: p.x - 5, y: p.y - 6, width: 7, height: 13))
                    g.move(to: CGPoint(x: p.x + 2, y: p.y - 2)); g.addLine(to: CGPoint(x: p.x + 5, y: p.y - 2)); g.addLine(to: CGPoint(x: p.x + 5, y: p.y + 5))
                    c.stroke(g, RGB.white.cg(), width: 2)
                } else {
                    c.fill(r, RGB(224, 32, 27).cg(), radius: 6)
                    let g = CGMutablePath()
                    g.move(to: CGPoint(x: p.x, y: p.y - 7)); g.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                    g.move(to: CGPoint(x: p.x - 7, y: p.y)); g.addLine(to: CGPoint(x: p.x + 7, y: p.y))
                    c.stroke(g, RGB.white.cg(), width: 3.5)
                }
            }
        }
        _ = pill   // dành cho nhãn tuyến sau này

        // Xe của bạn: luôn ở (238, 160) hướng lên trên (khi nghiêng có thêm bóng dưới chân)
        if tilt {
            c.ctx.setFillColor(RGB.black.cg(0.4))
            c.ctx.fillEllipse(in: CGRect(x: 216, y: 162, width: 44, height: 15))
        }
        let me = CGMutablePath()
        me.addLines(between: [CGPoint(x: 238, y: 146), CGPoint(x: 225, y: 172), CGPoint(x: 238, y: 165), CGPoint(x: 251, y: 172)])
        me.closeSubpath()
        c.fill(me, RGB.white.cg())
        c.stroke(me, RGB(10, 12, 10).cg(), width: 3)
        c.fill(me, RGB.white.cg())
    }

    // MARK: - Nhãn tên đường phía trước (khi đang dẫn đường)

    private struct AheadKey: Equatable {
        var count: Int
        var first: MapPoint
        var last: MapPoint
        var passed: Int
        var carLat: Int
        var carLon: Int
        var z: Int
        var zoomIndex: Int
        var tiles: Int
        var named: Int
        var spans: Int
    }

    private static let aheadLock = NSLock()
    private static var aheadKey: AheadKey?
    private static var aheadCache: [AheadLabel] = []

    /// Nhãn đường phía trước, lưu theo (tuyến, đoạn đã đi, vị trí xe làm tròn ~10 m, zoom, ô đã tải)
    /// nên khung hình liên tiếp không tính lại (khung ~4–5 lần mỗi giây).
    static func aheadLabels(scene: MapScene, v: View, zi: Int,
                            tiles: [(tx: Int, ty: Int, tile: MVTTile)]) -> [AheadLabel] {
        let route = scene.route
        guard route.count >= 2 else { return [] }
        var named = 0
        for t in tiles { named += t.tile.layers["transportation_name"]?.features.count ?? 0 }
        let key = AheadKey(count: route.count, first: route[0], last: route[route.count - 1], passed: scene.passedIndex,
                           carLat: Int((scene.center.lat * 1e4).rounded()), carLon: Int((scene.center.lon * 1e4).rounded()),
                           z: v.z, zoomIndex: zi, tiles: tiles.count, named: named, spans: scene.streetSpans.count)
        aheadLock.lock()
        if aheadKey == key {
            let hit = aheadCache
            aheadLock.unlock()
            return hit
        }
        aheadLock.unlock()

        let geo = route.map { GeoPoint(lat: $0.lat, lon: $0.lon) }
        let car = GeoPoint(lat: scene.center.lat, lon: scene.center.lon)
        let look = max(450, min(1500, metersPerPixel[max(0, min(metersPerPixel.count - 1, zi))] * 240))
        let window = AheadStreets.routeWindow(route: geo, passedIndex: scene.passedIndex, car: car, lookAheadM: look)

        // Hộp bao của đoạn tuyến phía trước (toạ độ thế giới ở mức v.z) để bỏ nhanh các đường ở xa
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in window {
            let w = Mercator.worldPixel(MapPoint(lat: p.lat, lon: p.lon), zoom: Double(v.z))
            minX = min(minX, w.x); maxX = max(maxX, w.x)
            minY = min(minY, w.y); maxY = max(maxY, w.y)
        }
        let margin = 300 / Mercator.metersPerPixel(lat: scene.center.lat, zoom: Double(v.z))
        minX -= margin; maxX += margin; minY -= margin; maxY += margin

        var roads: [AheadRoad] = []
        for t in tiles {
            guard let layer = t.tile.layers["transportation_name"] else { continue }
            let e = Double(layer.extent)
            for f in layer.features {
                guard f.kind == .line, let name = f.properties["name"]?.stringValue, !name.isEmpty,
                      let tier = roadTier(f.properties["class"]?.stringValue), tier <= AheadStreets.maxTier else { continue }
                for part in f.geometry where part.count >= 2 {
                    let world: [(x: Double, y: Double)] = part.map {
                        (x: (Double(t.tx) + Double($0.x) / e) * 256, y: (Double(t.ty) + Double($0.y) / e) * 256)
                    }
                    var pMinX = Double.infinity, pMaxX = -Double.infinity, pMinY = Double.infinity, pMaxY = -Double.infinity
                    for w in world {
                        pMinX = min(pMinX, w.x); pMaxX = max(pMaxX, w.x)
                        pMinY = min(pMinY, w.y); pMaxY = max(pMaxY, w.y)
                    }
                    if pMaxX < minX || pMinX > maxX || pMaxY < minY || pMinY > maxY { continue }
                    let pts: [GeoPoint] = world.map { w in
                        let m = Mercator.point(worldX: w.x, worldY: w.y, zoom: Double(v.z))
                        return GeoPoint(lat: m.lat, lon: m.lon)
                    }
                    roads.append(AheadRoad(name: name, points: pts, tier: tier))
                }
            }
        }
        let labels = AheadStreets.compute(route: geo, passedIndex: scene.passedIndex, car: car,
                                          streetSpans: scene.streetSpans, roads: roads, lookAheadM: look)
        aheadLock.lock()
        aheadKey = key
        aheadCache = labels
        aheadLock.unlock()
        return labels
    }

    /// Đoạn thẳng a–b có cắt hình chữ nhật không (Liang–Barsky).
    static func segmentHitsRect(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> Bool {
        var t0 = 0.0, t1 = 1.0
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let p = [-dx, dx, -dy, dy]
        let q = [Double(a.x - r.minX), Double(r.maxX - a.x), Double(a.y - r.minY), Double(r.maxY - a.y)]
        for i in 0..<4 {
            if p[i] == 0 {
                if q[i] < 0 { return false }
            } else {
                let t = q[i] / p[i]
                if p[i] < 0 {
                    if t > t1 { return false }
                    if t > t0 { t0 = t }
                } else {
                    if t < t0 { return false }
                    if t < t1 { t1 = t }
                }
            }
        }
        return true
    }

    /// Vẽ nhãn "Tên đường · khoảng cách": nhãn trái nằm bên trái tuyến (căn phải, cách mép tuyến ~10 px), nhãn phải bên phải,
    /// nhãn đi thẳng ở cuối đoạn tuyến nhìn thấy (lệch ~12 px sang phải). Không bao giờ nằm trên nét tuyến;
    /// nhãn đè lên nhau, lên mũi tên, ô thông tin hay thanh dưới thì bỏ.
    static func drawAheadLabels(_ c: Canvas, labels: [AheadLabel], scene: MapScene, v: View, tilt: Bool,
                                routeWidth: CGFloat, place: (CGRect) -> Bool) {
        guard !labels.isEmpty, scene.route.count >= 2 else { return }
        let winTop: CGFloat = tilt ? 72 : 30
        func inside(_ p: CGPoint) -> Bool { p.x >= 12 && p.x <= 468 && p.y >= winTop && p.y <= 178 }
        func halfRoute(_ d: Double) -> CGFloat {
            tilt ? max(1.5, routeWidth * CGFloat(v.scale(d)) / 2) : routeWidth / 2
        }

        // Nét tuyến trên màn hình từ xe tới mép nhìn thấy xa nhất
        let idx = max(0, min(scene.route.count - 2, scene.passedIndex))
        var line: [CGPoint] = [v.project(GP(u: 0, d: 0))]
        var prevG = GP(u: 0, d: 0)
        var endG = GP(u: 0, d: 0)
        var i = idx + 1
        while i < scene.route.count && line.count < 600 {
            let g = v.ground(scene.route[i])
            let s = v.project(g)
            if inside(s) {
                line.append(s)
                prevG = g
                endG = g
            } else {
                var lo = 0.0, hi = 1.0
                for _ in 0..<12 {
                    let mid = (lo + hi) / 2
                    let gm = GP(u: prevG.u + (g.u - prevG.u) * mid, d: prevG.d + (g.d - prevG.d) * mid)
                    if inside(v.project(gm)) { lo = mid } else { hi = mid }
                }
                endG = GP(u: prevG.u + (g.u - prevG.u) * lo, d: prevG.d + (g.d - prevG.d) * lo)
                line.append(v.project(endG))
                break
            }
            i += 1
        }
        func hitsRoute(_ r: CGRect) -> Bool {
            let rr = r.insetBy(dx: -2, dy: -2)
            for k in 1..<line.count where segmentHitsRect(line[k - 1], line[k], rr) { return true }
            return false
        }

        func layout(_ l: AheadLabel) -> (name: String, dist: String, w: CGFloat) {
            let dist = " · " + l.distanceText
            let distW = c.measure(dist, size: 16, weight: .regular)
            let room = 190 - 14 - distW
            var name = l.name
            if c.measure(name, size: 16, weight: .semibold) > room {
                var chars = Array(name)
                name = "…"
                while chars.count > 1 {
                    chars.removeLast()
                    let t = String(chars).trimmingCharacters(in: .whitespaces) + "…"
                    if c.measure(t, size: 16, weight: .semibold) <= room {
                        name = t
                        break
                    }
                }
            }
            return (name, dist, c.measure(name, size: 16, weight: .semibold) + distW + 14)
        }
        func paint(_ r: CGRect, _ l: (name: String, dist: String, w: CGFloat)) {
            c.fill(r, RGB.black.cg(0.75), radius: 7)
            let nw = c.text(l.name, x: r.minX + 7, y: r.minY + 1.6, size: 16, weight: .semibold, color: RGB(216, 216, 216).cg())
            c.text(l.dist, x: r.minX + 7 + nw, y: r.minY + 1.6, size: 16, weight: .regular, color: RGB(176, 176, 176).cg())
        }

        _ = place(CGRect(x: 226, y: 144, width: 24, height: 32))      // giữ chỗ cho mũi tên xe

        // Đi thẳng: ngay sau mép xa nhìn thấy của tuyến, lệch sang phải
        if let sl = labels.first(where: { $0.side == .straight }), line.count >= 2 {
            let l = layout(sl)
            let e = line[line.count - 1]
            let hr = halfRoute(endG.d)
            var cands: [CGRect] = []
            for off in [8.0, 30.0, 52.0] {
                cands.append(CGRect(x: e.x + 12 + hr, y: e.y + CGFloat(off) - 11, width: l.w, height: 22))
            }
            // Không còn chỗ bên phải (tuyến đi ngang ra mép màn hình): đặt vuông góc với hướng tuyến, phải rồi trái
            let a = line[line.count - 2]
            var dx = Double(e.x - a.x), dy = Double(e.y - a.y)
            let dn = hypot(dx, dy)
            if dn > 0.01 {
                dx /= dn
                dy /= dn
            } else {
                dx = 0
                dy = -1
            }
            for sign in [1.0, -1.0] {
                let nx = CGFloat(-dy * sign), ny = CGFloat(dx * sign)
                let off = abs(nx) * l.w / 2 + abs(ny) * 11 + hr + 10
                let cx = min(max(e.x + nx * off, 6 + l.w / 2), 474 - l.w / 2)
                cands.append(CGRect(x: cx - l.w / 2, y: e.y + ny * off - 11, width: l.w, height: 22))
            }
            for r in cands where !hitsRoute(r) {
                if place(r) {
                    paint(r, l)
                    break
                }
            }
        }

        // Đường cắt: gần nhất trước
        for lab in labels where lab.side != .straight {
            let g = v.ground(MapPoint(lat: lab.anchor.lat, lon: lab.anchor.lon))
            if g.d < 4 { continue }
            let s = v.project(g)
            guard inside(s) else { continue }
            // Hướng tuyến tại giao lộ (tính trên mặt đất rồi chiếu, nên đúng cả khi nghiêng)
            let ri = max(0, min(scene.route.count - 2, lab.routeIndex))
            let ga = v.ground(scene.route[ri]), gb = v.ground(scene.route[ri + 1])
            var du = gb.u - ga.u, dd = gb.d - ga.d
            let dl = hypot(du, dd)
            if dl > 1e-6 {
                du /= dl
                dd /= dl
            } else {
                du = 0
                dd = 1
            }
            let p1 = v.project(GP(u: g.u + du * 20, d: g.d + dd * 20))
            var sx = Double(p1.x - s.x), sy = Double(p1.y - s.y)
            let sn = hypot(sx, sy)
            if sn > 1e-6 {
                sx /= sn
                sy /= sn
            } else {
                sx = 0
                sy = -1
            }
            // Pháp tuyến trên màn hình: trái = (sy, -sx), phải = (-sy, sx)
            let isLeft = lab.side == .left
            let nx = CGFloat(isLeft ? sy : -sy), ny = CGFloat(isLeft ? -sx : sx)
            let l = layout(lab)
            let off = abs(nx) * l.w / 2 + abs(ny) * 11 + halfRoute(g.d) + 10
            let r = CGRect(x: s.x + nx * off - l.w / 2, y: s.y + ny * off - 11, width: l.w, height: 22)
            if hitsRoute(r) || !place(r) { continue }
            paint(r, l)
        }
    }

    static func roadTier(_ cls: String?) -> Int? {
        switch cls ?? "" {
        case "motorway", "trunk", "primary": return 0
        case "secondary", "tertiary": return 1
        case "minor": return 2
        case "service", "track": return 3
        default: return nil
        }
    }
}
