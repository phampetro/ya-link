import Foundation

/// Kết quả một lần cập nhật vị trí.
public struct NavUpdate {
    public var info: NavInfo?
    public var needsReroute: Bool
    public var arrived: Bool
    public var passedIndex: Int
    public var offRouteM: Double
    public init(info: NavInfo?, needsReroute: Bool, arrived: Bool, passedIndex: Int, offRouteM: Double) {
        self.info = info
        self.needsReroute = needsReroute
        self.arrived = arrived
        self.passedIndex = passedIndex
        self.offRouteM = offRouteM
    }
}

/// Bám tuyến: snap vị trí GPS vào route, tính khoảng cách tới chỗ rẽ, ETA, giới hạn tốc độ, lệch tuyến.
public final class Navigator {
    public static let offRouteThresholdM = 40.0
    public static let offRouteHoldS = 5.0
    public static let rerouteMinIntervalS = 10.0
    public static let arrivalRadiusM = 30.0

    public private(set) var route: Route
    public let destinationName: String

    private var cum: [Double] = []
    private var matched = 0
    private var offSince: Date?
    private var lastReroute: Date?

    public init(route: Route, destinationName: String) {
        self.route = route
        self.destinationName = destinationName
        rebuild()
    }

    public func replaceRoute(_ r: Route) {
        route = r
        rebuild()
    }

    private func rebuild() {
        matched = 0
        offSince = nil
        let pts = route.points
        cum = [0]
        if pts.count > 1 {
            for i in 1..<pts.count { cum.append(cum[i - 1] + Navigator.haversine(pts[i - 1], pts[i])) }
        }
    }

    public func update(_ p: GeoPoint, at time: Date, speedMps: Double?) -> NavUpdate {
        let pts = route.points
        guard pts.count >= 2 else {
            let d = pts.first.map { Navigator.haversine(p, $0) } ?? 0
            return NavUpdate(info: nil, needsReroute: false, arrived: !pts.isEmpty && d < Navigator.arrivalRadiusM,
                             passedIndex: 0, offRouteM: d)
        }
        let lastSeg = pts.count - 2
        // Tìm trong cửa sổ từ chỗ đã khớp (lùi nhẹ 2 đoạn), nếu xa thì tìm toàn tuyến.
        var best = snap(p, from: max(0, matched - 2), to: min(lastSeg, matched + 60))
        if best.dist > Navigator.offRouteThresholdM {
            let g = snap(p, from: 0, to: lastSeg)
            if g.dist < best.dist { best = g }
        }
        let offRoute = best.dist > Navigator.offRouteThresholdM
        if !offRoute { matched = best.seg }
        let idx = matched
        let along = offRoute ? cum[idx] : best.along

        let total = cum[cum.count - 1]
        let remaining = max(0, total - along)
        let arrived = Navigator.haversine(p, pts[pts.count - 1]) < Navigator.arrivalRadiusM

        var needsReroute = false
        if offRoute && !arrived {
            if offSince == nil { offSince = time }
            if let s = offSince, time.timeIntervalSince(s) >= Navigator.offRouteHoldS,
               lastReroute.map({ time.timeIntervalSince($0) >= Navigator.rerouteMinIntervalS }) ?? true {
                needsReroute = true
                lastReroute = time
            }
        } else {
            offSince = nil
        }

        let steps = route.steps
        let cur = steps.last(where: { $0.startIndex <= idx })
        let next = steps.first(where: { $0.startIndex > idx })
        let maneuver: NavInfo.Maneuver
        let distTurn: Double
        let nextStreet: String
        if let n = next {
            maneuver = n.maneuver
            distTurn = max(0, cum[min(n.startIndex, cum.count - 1)] - along)
            nextStreet = n.street
        } else {
            maneuver = .straight
            distTurn = remaining
            nextStreet = destinationName
        }

        let rate = route.totalM > 0 && route.durationS > 0 ? route.durationS / route.totalM : 1.0 / 10.0
        var etaS = remaining * rate
        if let v = speedMps, v > 3 {
            // Gần đích tin tốc độ hiện tại hơn; xa thì tin ước lượng của tuyến hơn.
            let w = remaining < 2000 ? 0.6 : 0.3
            etaS = (1 - w) * etaS + w * (remaining / v)
        }
        let limit = route.speedLimits.first(where: { $0.start <= idx && idx < $0.end })?.kmh

        let info = NavInfo(maneuver: maneuver, distanceToTurnM: distTurn, nextStreet: nextStreet,
                           currentStreet: cur?.street ?? "", destination: destinationName,
                           remainingKm: remaining / 1000, eta: time.addingTimeInterval(etaS), speedLimit: limit)
        return NavUpdate(info: info, needsReroute: needsReroute, arrived: arrived, passedIndex: idx, offRouteM: best.dist)
    }

    /// Chiếu p lên các đoạn [lo, hi]; trả về đoạn gần nhất, khoảng cách và quãng đường dọc tuyến.
    private func snap(_ p: GeoPoint, from lo: Int, to hi: Int) -> (seg: Int, dist: Double, along: Double) {
        var res = (seg: lo, dist: Double.infinity, along: 0.0)
        guard lo <= hi else { return res }
        let pts = route.points
        for i in lo...hi {
            let a = pts[i], b = pts[i + 1]
            let k = 111_194.93
            let c = cos(a.lat * .pi / 180)
            let bx = (b.lon - a.lon) * c * k, by = (b.lat - a.lat) * k
            let px = (p.lon - a.lon) * c * k, py = (p.lat - a.lat) * k
            let len2 = bx * bx + by * by
            let t = len2 > 0 ? min(1, max(0, (px * bx + py * by) / len2)) : 0
            let q = GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
            let d = Navigator.haversine(p, q)
            if d < res.dist { res = (i, d, cum[i] + t * (cum[i + 1] - cum[i])) }
        }
        return res
    }

    public static func haversine(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
