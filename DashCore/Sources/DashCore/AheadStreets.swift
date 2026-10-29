import Foundation

/// Một đường có tên lấy từ ô bản đồ (lớp `transportation_name`), đã đổi sang toạ độ địa lý.
public struct AheadRoad: Equatable {
    public var name: String
    public var points: [GeoPoint]
    /// Bậc đường: 0 lớn … 2 nhỏ (3 = đường dịch vụ, không dùng làm nhãn).
    public var tier: Int
    public init(name: String, points: [GeoPoint], tier: Int) {
        self.name = name
        self.points = points
        self.tier = tier
    }
}

/// Một nhãn tên đường phía trước xe khi đang dẫn đường.
public struct AheadLabel: Equatable {
    public enum Side: Equatable { case left, right, straight }
    public var name: String
    public var side: Side
    /// Quãng đường dọc tuyến từ xe tới giao lộ (hoặc tới chỗ đổi tên đường), mét.
    public var distanceM: Double
    /// Vị trí giao lộ trên tuyến (đường thẳng phía trước: điểm tuyến bắt đầu đoạn đường mới).
    public var anchor: GeoPoint
    /// Đoạn tuyến (`route[routeIndex]` → `route[routeIndex + 1]`) chứa `anchor`, để biết hướng đi tại đó.
    public var routeIndex: Int

    public init(name: String, side: Side, distanceM: Double, anchor: GeoPoint, routeIndex: Int) {
        self.name = name
        self.side = side
        self.distanceM = distanceM
        self.anchor = anchor
        self.routeIndex = routeIndex
    }

    /// "120 m", "1,2 km" (làm tròn như ô rẽ: DashUI.formatDistance).
    public var distanceText: String {
        let f = DashUI.formatDistance(distanceM)
        return "\(f.value) \(f.unit)"
    }
}

/// Chọn tên đường hiện trên bản đồ khi đang dẫn đường: tối đa 5 nhãn phía trước xe
/// (1 "đi thẳng" khi tên đường đổi + 2 đường cắt bên trái + 2 bên phải, gần nhất trước).
/// Hàm thuần, không phụ thuộc bộ vẽ: bộ vẽ đổi ô bản đồ thành `AheadRoad` rồi đặt nhãn lên màn hình.
public enum AheadStreets {
    public static let maxTier = 2
    public static let maxPerSide = 2
    /// Đường cắt tuyến góc nhỏ hơn mức này (độ) coi là chạy song song, bỏ.
    public static let minCrossingAngleDeg = 25.0
    /// Đường mà hầu hết đỉnh nằm trong khoảng này quanh tuyến coi là trùng tuyến, bỏ.
    public static let parallelToleranceM = 12.0
    /// Đường cắt phải nhô ra ít nhất bấy nhiêu mét về một phía (bỏ cụt ngắn).
    public static let minStubM = 15.0
    /// Đo đường cắt nhô ra bên nào trong phạm vi này (mét dọc đường đó).
    public static let sideReachM = 150.0
    /// Giao lộ gần xe hơn mức này coi là đã qua.
    public static let minAlongM = 5.0
    /// Kéo dài hai đầu đường thêm chừng này để bắt giao lộ chữ T bị lệch vài mét.
    public static let endExtensionM = 8.0

    private struct V2 {
        var x: Double
        var y: Double
    }

    /// Hệ toạ độ mét phẳng (equirectangular) quanh một gốc.
    private struct Frame {
        let lat0: Double
        let lon0: Double
        let mx: Double
        let my: Double
        init(origin: GeoPoint) {
            lat0 = origin.lat
            lon0 = origin.lon
            my = 111_194.93
            mx = 111_194.93 * cos(origin.lat * .pi / 180)
        }
        func xy(_ p: GeoPoint) -> V2 { V2(x: (p.lon - lon0) * mx, y: (p.lat - lat0) * my) }
        func geo(_ v: V2) -> GeoPoint { GeoPoint(lat: lat0 + v.y / my, lon: lon0 + v.x / mx) }
    }

    private static func sub(_ a: V2, _ b: V2) -> V2 { V2(x: a.x - b.x, y: a.y - b.y) }
    private static func cross(_ a: V2, _ b: V2) -> Double { a.x * b.y - a.y * b.x }
    private static func length(_ a: V2) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }

    private static func distToSegment(_ p: V2, _ a: V2, _ b: V2) -> Double {
        let ab = sub(b, a)
        let l2 = ab.x * ab.x + ab.y * ab.y
        if l2 < 1e-9 { return length(sub(p, a)) }
        let ap = sub(p, a)
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / l2))
        return length(sub(p, V2(x: a.x + ab.x * t, y: a.y + ab.y * t)))
    }

    /// Đoạn tuyến phía trước xe: điểm đầu là vị trí xe chiếu lên đoạn `passedIndex`, tiếp theo là các điểm tuyến
    /// cho tới khi đủ `lookAheadM` mét. Đoạn thứ k của kết quả thuộc đoạn tuyến `passedIndex + k`.
    public static func routeWindow(route: [GeoPoint], passedIndex: Int, car: GeoPoint?, lookAheadM: Double) -> [GeoPoint] {
        guard route.count >= 2 else { return route }
        let idx = max(0, min(route.count - 2, passedIndex))
        var start = route[idx]
        if let c = car {
            let f = Frame(origin: route[idx])
            let b = f.xy(route[idx + 1])
            let p = f.xy(c)
            let l2 = b.x * b.x + b.y * b.y
            if l2 > 1e-9 {
                let t = max(0, min(1, (p.x * b.x + p.y * b.y) / l2))
                start = f.geo(V2(x: b.x * t, y: b.y * t))
            }
        }
        var out = [start]
        var total = 0.0
        var prev = start
        var i = idx + 1
        while i < route.count {
            total += Navigator.haversine(prev, route[i])
            out.append(route[i])
            prev = route[i]
            if total >= lookAheadM { break }
            i += 1
        }
        return out
    }

    /// Tối đa 5 nhãn: nhãn "đi thẳng" (nếu có) đứng đầu, sau đó các đường cắt theo khoảng cách tăng dần.
    /// - route: toàn bộ điểm tuyến; passedIndex: đoạn xe đang đi (Navigator.passedIndex); car: vị trí xe.
    /// - streetSpans: tên đường dọc tuyến (Route.streetSpans), rỗng thì không có nhãn đi thẳng và không loại đường theo tên.
    /// - roads: các đường có tên quanh đó (từ ô bản đồ).
    public static func compute(route: [GeoPoint], passedIndex: Int, car: GeoPoint? = nil, streetSpans: [StreetSpan],
                               roads: [AheadRoad], lookAheadM: Double = 600) -> [AheadLabel] {
        guard route.count >= 2 else { return [] }
        let idx = max(0, min(route.count - 2, passedIndex))
        let win = routeWindow(route: route, passedIndex: idx, car: car, lookAheadM: lookAheadM)
        guard win.count >= 2 else { return [] }
        let frame = Frame(origin: win[0])
        let P = win.map { frame.xy($0) }
        var cum = [0.0]
        for k in 1..<P.count { cum.append(cum[k - 1] + length(sub(P[k], P[k - 1]))) }

        func ownName(_ r: Int) -> String? {
            streetSpans.last(where: { $0.start <= r && r <= $0.end })?.name
        }
        let currentName = ownName(idx) ?? ""

        // (a) đi thẳng: đoạn đường kế tiếp có tên khác tên đang đi
        var straight: AheadLabel?
        let ci = streetSpans.lastIndex(where: { $0.start <= idx && idx <= $0.end })
        let later: [StreetSpan]
        if let c = ci {
            later = Array(streetSpans[(c + 1)...])
        } else {
            later = streetSpans.filter { $0.start > idx }
        }
        if let s = later.first(where: { !$0.name.isEmpty && $0.name != currentName && $0.start > idx }) {
            let startI = min(s.start, route.count - 1)
            var d = cum[1]
            var k = idx + 1
            while k < startI {
                d += Navigator.haversine(route[k], route[k + 1])
                k += 1
            }
            straight = AheadLabel(name: s.name, side: .straight, distanceM: d, anchor: route[startI],
                                  routeIndex: min(startI, route.count - 2))
        }

        // (b, c) đường cắt: giao điểm giữa từng đường và các đoạn tuyến phía trước
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in P {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = 40.0
        let minSin = sin(minCrossingAngleDeg * .pi / 180)
        var hits: [AheadLabel] = []
        for road in roads {
            guard road.tier <= maxTier, !road.name.isEmpty, road.points.count >= 2, road.name != currentName else { continue }
            var R = road.points.map { frame.xy($0) }
            var rMinX = Double.infinity, rMaxX = -Double.infinity, rMinY = Double.infinity, rMaxY = -Double.infinity
            for p in R {
                rMinX = min(rMinX, p.x); rMaxX = max(rMaxX, p.x)
                rMinY = min(rMinY, p.y); rMaxY = max(rMaxY, p.y)
            }
            if rMaxX < minX - pad || rMinX > maxX + pad || rMaxY < minY - pad || rMinY > maxY + pad { continue }
            if isAlongRoute(R, P) { continue }
            R[0] = extended(R[0], from: R[1])
            R[R.count - 1] = extended(R[R.count - 1], from: R[R.count - 2])

            var best: AheadLabel?
            for j in 0..<(R.count - 1) {
                let r = sub(R[j + 1], R[j])
                let rl = length(r)
                if rl < 1e-6 { continue }
                for k in 0..<(P.count - 1) {
                    let s = sub(P[k + 1], P[k])
                    let sl = length(s)
                    if sl < 1e-6 { continue }
                    let denom = cross(r, s)
                    if abs(denom) / (rl * sl) < minSin { continue }
                    let q = sub(P[k], R[j])
                    let t = cross(q, s) / denom
                    let u = cross(q, r) / denom
                    guard t >= 0, t <= 1, u >= 0, u <= 1 else { continue }
                    let along = cum[k] + u * sl
                    if along < minAlongM { continue }
                    if let b = best, b.distanceM <= along { continue }
                    let seg = idx + k
                    let own = [ownName(seg - 1), ownName(seg), ownName(seg + 1)]
                    if own.contains(where: { $0 == road.name }) { continue }
                    let at = V2(x: R[j].x + r.x * t, y: R[j].y + r.y * t)
                    let dir = V2(x: s.x / sl, y: s.y / sl)
                    let ext = sideExtents(R, segment: j, at: at, dir: dir)
                    if max(ext.left, ext.right) < minStubM { continue }
                    let side: AheadLabel.Side = ext.left > ext.right ? .left : .right
                    best = AheadLabel(name: road.name, side: side, distanceM: along, anchor: frame.geo(at), routeIndex: seg)
                }
            }
            if let b = best { hits.append(b) }
        }

        // Gần nhất trước, mỗi tên một lần, mỗi bên tối đa 2
        hits.sort { $0.distanceM != $1.distanceM ? $0.distanceM < $1.distanceM : $0.name < $1.name }
        var seen = Set<String>()
        if let s = straight { seen.insert(s.name) }
        var left: [AheadLabel] = []
        var right: [AheadLabel] = []
        for h in hits where !seen.contains(h.name) {
            seen.insert(h.name)
            if h.side == .left {
                if left.count < maxPerSide { left.append(h) }
            } else if right.count < maxPerSide {
                right.append(h)
            }
        }
        var out: [AheadLabel] = []
        if let s = straight { out.append(s) }
        out += (left + right).sorted { $0.distanceM < $1.distanceM }
        return out
    }

    /// Đường nằm sát tuyến (phần lớn đỉnh trong `parallelToleranceM` quanh tuyến): chạy trùng, không phải đường cắt.
    private static func isAlongRoute(_ R: [V2], _ P: [V2]) -> Bool {
        guard R.count >= 3 else { return false }
        var near = 0
        for v in R {
            for k in 0..<(P.count - 1) where distToSegment(v, P[k], P[k + 1]) <= parallelToleranceM {
                near += 1
                break
            }
        }
        return near * 10 >= R.count * 6
    }

    private static func extended(_ p: V2, from q: V2) -> V2 {
        let d = sub(p, q)
        let l = length(d)
        if l < 1e-9 { return p }
        return V2(x: p.x + d.x / l * endExtensionM, y: p.y + d.y / l * endExtensionM)
    }

    /// Đường nhô ra xa nhất bao nhiêu mét về bên trái / bên phải hướng đi `dir` (tại giao điểm `at`),
    /// đo trong `sideReachM` mét dọc đường theo cả hai chiều. Dấu của tích có hướng quyết định bên trái (> 0) hay phải.
    private static func sideExtents(_ R: [V2], segment j: Int, at: V2, dir: V2) -> (left: Double, right: Double) {
        var left = 0.0
        var right = 0.0
        func scan(_ pts: [V2]) {
            var prev = at
            var budget = sideReachM
            for q in pts {
                let seg = length(sub(q, prev))
                var e = q
                var stop = false
                if seg > budget {
                    let t = seg > 0 ? budget / seg : 0
                    e = V2(x: prev.x + (q.x - prev.x) * t, y: prev.y + (q.y - prev.y) * t)
                    stop = true
                }
                let c = cross(dir, sub(e, at))
                if c > 0 { left = max(left, c) } else { right = max(right, -c) }
                if stop { break }
                budget -= seg
                prev = q
            }
        }
        scan(Array(R[(j + 1)...]))
        scan((0...j).reversed().map { R[$0] })
        return (left, right)
    }
}
