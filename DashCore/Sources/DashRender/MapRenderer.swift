import CoreGraphics
import Foundation

/// Cảnh bản đồ cần vẽ: vị trí xe, hướng đi (heading-up: hướng đi luôn ở phía trên), tuyến, điểm đến.
public struct MapScene {
    public var center: MapPoint
    public var headingDeg: Double
    public var route: [MapPoint]
    public var passedIndex: Int
    public var destination: MapPoint?
    public var store: TileStore

    public init(center: MapPoint, headingDeg: Double, route: [MapPoint], passedIndex: Int,
                destination: MapPoint?, store: TileStore) {
        self.center = center
        self.headingDeg = headingDeg
        self.route = route
        self.passedIndex = passedIndex
        self.destination = destination
        self.store = store
    }
}

/// Vẽ bản đồ vector (OpenFreeMap, lược đồ OpenMapTiles) bằng CPU. Mỗi mức zoom vẽ lại với chi tiết khác nhau:
/// xa (0–1) đường lớn + tên quận · vừa (2–3) thêm đường nhỏ + tên đường · gần (4–5) thêm hẻm, cây xăng, bệnh viện, nhà.
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

        func screen(worldX: Double, worldY: Double) -> CGPoint {
            let dx = (worldX - cx) * k, dy = (worldY - cy) * k
            return CGPoint(x: 238 + dx * cosH + dy * sinH, y: 160 - dx * sinH + dy * cosH)
        }

        func screen(_ p: MapPoint) -> CGPoint {
            let w = Mercator.worldPixel(p, zoom: Double(z))
            return screen(worldX: w.x, worldY: w.y)
        }
    }

    static func makeView(_ scene: MapScene, zoomIndex zi: Int) -> View {
        let mpp = metersPerPixel[max(0, min(metersPerPixel.count - 1, zi))]
        let lat = scene.center.lat
        let ideal = log2(156543.03392 * cos(lat * .pi / 180) / mpp)
        let z = max(0, min(14, Int(ideal.rounded())))
        let cw = Mercator.worldPixel(scene.center, zoom: Double(z))
        let res = Mercator.metersPerPixel(lat: lat, zoom: Double(z))
        let h = scene.headingDeg * .pi / 180
        return View(z: z, cx: cw.x, cy: cw.y, k: res / mpp, cosH: cos(h), sinH: sin(h))
    }

    static func draw(_ c: Canvas, scene: MapScene, zoomIndex zi: Int, pc: RGB) {
        let v = makeView(scene, zoomIndex: zi)
        let ct = Mercator.tile(scene.center, z: v.z)
        let n = min(2, max(1, Int(ceil(300 / v.k / 256))))
        let limit = 1 << v.z
        var tiles: [(tx: Int, ty: Int, tile: MVTTile)] = []
        for ty in (ct.y - n)...(ct.y + n) {
            for tx in (ct.x - n)...(ct.x + n) where tx >= 0 && ty >= 0 && tx < limit && ty < limit {
                if let t = scene.store.tile(z: v.z, x: tx, y: ty) { tiles.append((tx, ty, t)) }
            }
        }

        func project(_ p: MVTPoint, _ tx: Int, _ ty: Int, _ extent: Int) -> CGPoint {
            let e = Double(extent)
            return v.screen(worldX: (Double(tx) + Double(p.x) / e) * 256, worldY: (Double(ty) + Double(p.y) / e) * 256)
        }

        func polygonPath(_ f: MVTFeature, _ tx: Int, _ ty: Int, _ extent: Int) -> CGPath {
            let path = CGMutablePath()
            for ring in f.geometry where ring.count >= 3 {
                path.addLines(between: ring.map { project($0, tx, ty, extent) })
                path.closeSubpath()
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

        // Đường: gom theo bậc, vẽ bậc nhỏ trước để đường lớn đè lên
        var tierPaths = [CGMutablePath](repeating: CGMutablePath(), count: 4)
        eachFeature("transportation") { f, tx, ty, e in
            guard f.kind == .line, let t = roadTier(f.properties["class"]?.stringValue), widths[t][zi] > 0 else { return }
            for part in f.geometry where part.count >= 2 {
                tierPaths[t].addLines(between: part.map { project($0, tx, ty, e) })
            }
        }
        for t in stride(from: 3, through: 0, by: -1) where widths[t][zi] > 0 {
            c.stroke(tierPaths[t], roadColors[t].cg(), width: widths[t][zi])
        }

        // Tuyến: đoạn đã qua xám, đoạn còn lại màu trang
        let wRoute: CGFloat = [5, 6, 8, 10, 12, 14][zi]
        let pts = scene.route.map { v.screen($0) }
        if pts.count >= 2 {
            let cut = max(0, min(pts.count - 1, scene.passedIndex))
            if cut >= 1 {
                let passed = CGMutablePath()
                passed.addLines(between: Array(pts[0...cut]))
                c.stroke(passed, RGB(90, 93, 90).cg(), width: wRoute)
            }
            let ahead = CGMutablePath()
            ahead.addLines(between: Array(pts[cut...]))
            c.stroke(ahead, pc.cg(), width: wRoute)
        }

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

        // Điểm đến
        if let d = scene.destination {
            let p = v.screen(d)
            if p.x > 8 && p.x < 472 && p.y > 24 && p.y < 230 {
                let pin = CGMutablePath()
                pin.move(to: p)
                pin.addLine(to: CGPoint(x: p.x - 9, y: p.y - 14))
                pin.addArc(center: CGPoint(x: p.x, y: p.y - 14), radius: 10.5, startAngle: .pi * 0.8, endAngle: .pi * 0.2,
                           clockwise: false)
                pin.closeSubpath()
                c.fill(pin, RGB(224, 32, 27).cg())
                c.stroke(pin, RGB.white.cg(), width: 2)
                c.fillCircle(center: CGPoint(x: p.x, y: p.y - 19), radius: 3.5, RGB.white.cg())
            }
        }

        if zi <= 1 {
            let suburbs: Set<String> = ["suburb", "quarter", "neighbourhood", "city_district"]
            var seen = Set<String>()
            eachFeature("place") { f, tx, ty, e in
                guard let cls = f.properties["class"]?.stringValue, suburbs.contains(cls),
                      let name = f.properties["name"]?.stringValue, !seen.contains(name),
                      let first = f.geometry.first?.first else { return }
                let p = project(first, tx, ty, e)
                let w = c.measure(name.uppercased(), size: 17, weight: .bold) + 8
                let r = CGRect(x: p.x - w / 2, y: p.y - 11, width: w, height: 22)
                guard place(r) else { return }
                seen.insert(name)
                c.text(name.uppercased(), x: p.x, y: r.minY + 1, size: 17, weight: .bold, color: RGB(154, 159, 154).cg(), align: .center)
            }
        }
        if zi >= 3 {
            var seen = Set<String>()
            eachFeature("transportation_name") { f, tx, ty, e in
                guard f.kind == .line, let name = f.properties["name"]?.stringValue, !seen.contains(name),
                      let tier = roadTier(f.properties["class"]?.stringValue), tier <= (zi >= 5 ? 2 : 1),
                      let part = f.geometry.max(by: { $0.count < $1.count }), part.count >= 2 else { return }
                let mid = project(part[part.count / 2], tx, ty, e)
                if place(CGRect(x: mid.x - c.measure(name, size: 16, weight: .semibold) / 2 - 7, y: mid.y - 11,
                                width: c.measure(name, size: 16, weight: .semibold) + 14, height: 22)) {
                    seen.insert(name)
                    let w = c.measure(name, size: 16, weight: .semibold) + 14
                    c.fill(CGRect(x: mid.x - w / 2, y: mid.y - 11, width: w, height: 22), RGB.black.cg(0.75), radius: 7)
                    c.text(name, x: mid.x, y: mid.y - 9.4, size: 16, weight: .semibold, color: RGB(216, 216, 216).cg(), align: .center)
                }
            }
        }
        if zi >= 4 {
            eachFeature("poi") { f, tx, ty, e in
                guard let cls = f.properties["class"]?.stringValue, cls == "fuel" || cls == "hospital",
                      let first = f.geometry.first?.first else { return }
                let p = project(first, tx, ty, e)
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

        // Xe của bạn: luôn ở (238, 160) hướng lên trên
        let me = CGMutablePath()
        me.addLines(between: [CGPoint(x: 238, y: 146), CGPoint(x: 225, y: 172), CGPoint(x: 238, y: 165), CGPoint(x: 251, y: 172)])
        me.closeSubpath()
        c.fill(me, RGB.white.cg())
        c.stroke(me, RGB(10, 12, 10).cg(), width: 3)
        c.fill(me, RGB.white.cg())
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
