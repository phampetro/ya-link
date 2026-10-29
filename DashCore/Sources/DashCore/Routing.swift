import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Polyline (Google precision 5, Valhalla precision 6)

public enum Polyline {
    public static func decode(_ s: String, precision: Int = 5) -> [GeoPoint] {
        let b = Array(s.utf8)
        let f = pow(10.0, Double(precision))
        var i = 0, lat = 0, lon = 0
        var out: [GeoPoint] = []
        func next() -> Int? {
            var result = 0, shift = 0
            while i < b.count {
                let c = Int(b[i]) - 63
                i += 1
                if c < 0 || shift > 60 { return nil }
                result |= (c & 0x1f) << shift
                shift += 5
                if c < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < b.count {
            guard let dlat = next(), let dlon = next() else { break }
            lat += dlat
            lon += dlon
            out.append(GeoPoint(lat: Double(lat) / f, lon: Double(lon) / f))
        }
        return out
    }

    public static func encode(_ pts: [GeoPoint], precision: Int = 5) -> String {
        let f = pow(10.0, Double(precision))
        var out = ""
        var pLat = 0, pLon = 0
        for p in pts {
            let la = Int((p.lat * f).rounded()), lo = Int((p.lon * f).rounded())
            put(la - pLat, &out)
            put(lo - pLon, &out)
            pLat = la
            pLon = lo
        }
        return out
    }

    private static func put(_ v: Int, _ out: inout String) {
        var x = v < 0 ? ~(v << 1) : (v << 1)
        while x >= 0x20 {
            out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (x & 0x1f)) + 63)))
            x >>= 5
        }
        out.unicodeScalars.append(UnicodeScalar(UInt8(x + 63)))
    }
}

// MARK: - Model

public struct RouteStep: Equatable {
    public var maneuver: NavInfo.Maneuver
    public var street: String
    public var distanceM: Double
    public var startIndex: Int
    public init(maneuver: NavInfo.Maneuver, street: String, distanceM: Double, startIndex: Int) {
        self.maneuver = maneuver; self.street = street; self.distanceM = distanceM; self.startIndex = startIndex
    }
}

/// Đoạn giới hạn tốc độ trên `Route.points`, chỉ số `start...end` (bao gồm cả hai đầu).
public struct SpeedLimitSpan: Equatable {
    public var start: Int
    public var end: Int
    public var kmh: Int
    public init(start: Int, end: Int, kmh: Int) { self.start = start; self.end = end; self.kmh = kmh }
}

/// Tên đường theo thực tế dọc tuyến (từ trace_attributes), chỉ số theo `Route.points`, cả hai đầu đều tính.
public struct StreetSpan: Equatable {
    public var start: Int
    public var end: Int
    public var name: String
    public init(start: Int, end: Int, name: String) { self.start = start; self.end = end; self.name = name }
}

public struct Route: Equatable {
    public enum Source: String { case valhalla, google }
    public var points: [GeoPoint]
    public var steps: [RouteStep]
    public var totalM: Double
    public var durationS: Double
    public var speedLimits: [SpeedLimitSpan]
    public var streetSpans: [StreetSpan]
    public var source: Source

    public init(points: [GeoPoint], steps: [RouteStep], totalM: Double, durationS: Double,
                speedLimits: [SpeedLimitSpan] = [], streetSpans: [StreetSpan] = [], source: Source) {
        self.points = points; self.steps = steps; self.totalM = totalM; self.durationS = durationS
        self.speedLimits = speedLimits; self.streetSpans = streetSpans; self.source = source
    }

    public static func == (a: Route, b: Route) -> Bool {
        a.steps == b.steps && a.totalM == b.totalM && a.durationS == b.durationS
            && a.speedLimits == b.speedLimits && a.streetSpans == b.streetSpans && a.source == b.source
            && a.points.count == b.points.count
            && zip(a.points, b.points).allSatisfy { p in p.0.lat == p.1.lat && p.0.lon == p.1.lon }
    }
}

public enum RoutingError: Error, Equatable {
    case http(Int, String)
    case badResponse
    case noRoute
}

// MARK: - JSON helpers

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RoutingError.badResponse }
    return o
}
private func num(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue }
private func jsonData(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

// MARK: - Valhalla

public enum Valhalla {
    public static let baseURL = URL(string: "https://valhalla1.openstreetmap.de")!

    public static func routeRequestBody(from: GeoPoint, to: GeoPoint, via: [GeoPoint] = []) -> Data {
        var locs: [[String: Any]] = [["lat": from.lat, "lon": from.lon, "type": "break"]]
        for v in via { locs.append(["lat": v.lat, "lon": v.lon, "type": "via"]) }
        locs.append(["lat": to.lat, "lon": to.lon, "type": "break"])
        return jsonData([
            "locations": locs,
            "costing": "motor_scooter",
            "directions_options": ["language": "vi-VN", "units": "kilometers"],
        ] as [String: Any])
    }

    public static func maneuver(type t: Int) -> NavInfo.Maneuver {
        switch t {
        case 9, 10, 11, 18, 20, 23: return .right
        case 14, 15, 16, 19, 21, 24: return .left
        case 12, 13: return .uturn
        case 26, 27: return .roundabout
        default: return .straight
        }
    }

    public static func parseRoute(_ data: Data) throws -> Route {
        let o = try jsonObject(data)
        guard let trip = o["trip"] as? [String: Any], let legs = trip["legs"] as? [[String: Any]], !legs.isEmpty
        else { throw RoutingError.noRoute }
        var points: [GeoPoint] = []
        var steps: [RouteStep] = []
        for leg in legs {
            let shape = Polyline.decode(leg["shape"] as? String ?? "", precision: 6)
            let offset = points.isEmpty ? 0 : points.count - 1
            points += points.isEmpty ? shape : Array(shape.dropFirst())
            for m in leg["maneuvers"] as? [[String: Any]] ?? [] {
                let t = Int(num(m["type"]) ?? 0)
                let names = m["street_names"] as? [String] ?? []
                steps.append(RouteStep(maneuver: maneuver(type: t), street: names.first ?? "",
                                       distanceM: (num(m["length"]) ?? 0) * 1000,
                                       startIndex: offset + Int(num(m["begin_shape_index"]) ?? 0)))
            }
        }
        let sum = trip["summary"] as? [String: Any] ?? [:]
        return Route(points: points, steps: steps, totalM: (num(sum["length"]) ?? 0) * 1000,
                     durationS: num(sum["time"]) ?? 0, source: .valhalla)
    }

    public static func traceRequestBody(points: [GeoPoint]) -> Data {
        jsonData([
            "shape": points.map { ["lat": $0.lat, "lon": $0.lon] },
            "costing": "motor_scooter",
            "shape_match": "map_snap",
            "filters": [
                "attributes": ["edge.speed_limit", "edge.length", "edge.begin_shape_index",
                               "edge.end_shape_index", "edge.names", "matched.edge_index"],
                "action": "include",
            ] as [String: Any],
        ] as [String: Any])
    }

    /// Giới hạn tốc độ. Nếu có `matched_points` thì chỉ số theo điểm đầu vào, nếu không theo shape của edge.
    public static func parseTrace(_ data: Data) throws -> (matchedLengthKm: Double, limits: [SpeedLimitSpan], streets: [StreetSpan]) {
        let o = try jsonObject(data)
        guard let edges = o["edges"] as? [[String: Any]] else { throw RoutingError.badResponse }
        let length = edges.reduce(0.0) { $0 + (num($1["length"]) ?? 0) }
        let kmhOf: [Int] = edges.map { Int(num($0["speed_limit"]) ?? 0) }
        let nameOf: [String] = edges.map { ($0["names"] as? [String])?.first(where: { !$0.isEmpty }) ?? "" }
        var streets: [StreetSpan] = []
        func addStreet(_ s: Int, _ e: Int, _ name: String) {
            guard !name.isEmpty, e >= s else { return }
            if var last = streets.last, last.name == name, s <= last.end + 1 {
                last.end = max(last.end, e)
                streets[streets.count - 1] = last
            } else {
                streets.append(StreetSpan(start: s, end: e, name: name))
            }
        }
        var spans: [SpeedLimitSpan] = []
        func add(_ s: Int, _ e: Int, _ kmh: Int) {
            guard kmh > 0, kmh < 250, e >= s else { return }
            if var last = spans.last, last.kmh == kmh, s <= last.end + 1 {
                last.end = max(last.end, e)
                spans[spans.count - 1] = last
            } else {
                spans.append(SpeedLimitSpan(start: s, end: e, kmh: kmh))
            }
        }
        if let matched = o["matched_points"] as? [[String: Any]], !matched.isEmpty {
            for (i, m) in matched.enumerated() {
                guard let e = num(m["edge_index"]).map({ Int($0) }), e >= 0, e < kmhOf.count else { continue }
                add(i, i, kmhOf[e])
                addStreet(i, i, nameOf[e])
            }
        } else {
            for (i, e) in edges.enumerated() {
                add(Int(num(e["begin_shape_index"]) ?? 0), Int(num(e["end_shape_index"]) ?? 0), kmhOf[i])
                addStreet(Int(num(e["begin_shape_index"]) ?? 0), Int(num(e["end_shape_index"]) ?? 0), nameOf[i])
            }
        }
        return (length, spans, streets)
    }
}

// MARK: - Google Routes v2

public enum GoogleRoutes {
    public static let url = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!
    public static let fieldMask = "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.distanceMeters,routes.legs.steps.navigationInstruction,routes.legs.steps.polyline.encodedPolyline"

    private static func wp(_ p: GeoPoint) -> [String: Any] {
        ["location": ["latLng": ["latitude": p.lat, "longitude": p.lon]]]
    }

    public static func requestBody(from: GeoPoint, to: GeoPoint, via: [GeoPoint] = []) -> Data {
        var o: [String: Any] = [
            "origin": wp(from), "destination": wp(to),
            "travelMode": "TWO_WHEELER", "routingPreference": "TRAFFIC_AWARE",
            "languageCode": "vi", "units": "METRIC",
        ]
        if !via.isEmpty { o["intermediates"] = via.map(wp) }
        return jsonData(o)
    }

    public static func maneuver(_ s: String) -> NavInfo.Maneuver {
        let u = s.uppercased()
        if u.hasPrefix("UTURN") { return .uturn }
        if u.contains("ROUNDABOUT") { return .roundabout }
        if u.contains("RIGHT") { return .right }
        if u.contains("LEFT") { return .left }
        return .straight
    }

    public static func street(from instruction: String) -> String {
        for key in ["vào ", "onto "] {
            if let r = instruction.range(of: key, options: .caseInsensitive) {
                let rest = instruction[r.upperBound...]
                let line = rest.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    public static func parse(_ data: Data) throws -> Route {
        let o = try jsonObject(data)
        guard let r = (o["routes"] as? [[String: Any]])?.first else { throw RoutingError.noRoute }
        var points: [GeoPoint] = []
        var steps: [RouteStep] = []
        for leg in r["legs"] as? [[String: Any]] ?? [] {
            for s in leg["steps"] as? [[String: Any]] ?? [] {
                let enc = (s["polyline"] as? [String: Any])?["encodedPolyline"] as? String ?? ""
                let sp = Polyline.decode(enc, precision: 5)
                let start = max(points.count - 1, 0)
                points += points.isEmpty ? sp : Array(sp.dropFirst())
                let nav = s["navigationInstruction"] as? [String: Any] ?? [:]
                steps.append(RouteStep(maneuver: maneuver(nav["maneuver"] as? String ?? ""),
                                       street: street(from: nav["instructions"] as? String ?? ""),
                                       distanceM: num(s["distanceMeters"]) ?? 0, startIndex: start))
            }
        }
        if points.isEmpty, let enc = (r["polyline"] as? [String: Any])?["encodedPolyline"] as? String {
            points = Polyline.decode(enc, precision: 5)
        }
        guard !points.isEmpty else { throw RoutingError.noRoute }
        let dur = Double((r["duration"] as? String ?? "0s").trimmingCharacters(in: CharacterSet(charactersIn: "s"))) ?? 0
        return Route(points: points, steps: steps, totalM: num(r["distanceMeters"]) ?? 0, durationS: dur, source: .google)
    }
}

// MARK: - Planner

public enum KeyTestResult: Equatable {
    /// `rejected`: Google từ chối vì lý do khác key sai (chưa bật thanh toán, chưa bật Routes API, key bị hạn chế…); kèm câu Google trả về.
    case ok, invalidKey, twoWheelerUnsupported, rejected(String), network(String)
}

public final class RoutePlanner {
    public let googleKey: String?
    public let session: URLSession
    public var onGoogleCall: (() -> Void)?
    /// Dòng chẩn đoán ngắn (app ghi vào nhật ký): trace thành công hay lỗi, bao nhiêu đoạn có giới hạn tốc độ.
    public var onDiag: ((String) -> Void)?
    public static let maxTracePoints = 400

    public init(googleKey: String?, session: URLSession = .shared) {
        self.googleKey = googleKey
        self.session = session
    }

    public func plan(from: GeoPoint, to: GeoPoint, via: [GeoPoint] = []) async throws -> Route {
        if let key = googleKey, !key.isEmpty {
            onGoogleCall?()
            if let g = try? await google(key: key, from: from, to: to, via: via) {
                if let t = try? await trace(g.points), g.totalM > 0,
                   abs(t.matchedLengthKm * 1000 - g.totalM) / g.totalM <= 0.2 {
                    var r = g
                    r.speedLimits = t.limits
                    r.streetSpans = t.streets
                    diag("Google", r)
                    return r
                }
            }
        }
        var r = try await valhallaRoute(from: from, to: to, via: via)
        do {
            let t = try await trace(r.points)
            r.speedLimits = t.limits
            r.streetSpans = t.streets
        } catch {
            onDiag?("trace_attributes lỗi: \(error.localizedDescription)")
        }
        diag("Valhalla", r)
        return r
    }

    private func diag(_ source: String, _ r: Route) {
        let covered = r.speedLimits.reduce(0) { $0 + max(0, $1.end - $1.start + 1) }
        let pct = r.points.isEmpty ? 0 : min(100, covered * 100 / r.points.count)
        onDiag?("tuyến \(source): \(r.points.count) điểm, \(r.steps.count) bước, \(r.speedLimits.count) đoạn có giới hạn tốc độ (phủ \(pct)% tuyến), \(r.streetSpans.count) đoạn tên đường")
    }

    func valhallaRoute(from: GeoPoint, to: GeoPoint, via: [GeoPoint]) async throws -> Route {
        let d = try await post(Valhalla.baseURL.appendingPathComponent("route"),
                               Valhalla.routeRequestBody(from: from, to: to, via: via), headers: [:])
        return try Valhalla.parseRoute(d)
    }

    func google(key: String, from: GeoPoint, to: GeoPoint, via: [GeoPoint]) async throws -> Route {
        let d = try await post(GoogleRoutes.url, GoogleRoutes.requestBody(from: from, to: to, via: via),
                               headers: ["X-Goog-Api-Key": key, "X-Goog-FieldMask": GoogleRoutes.fieldMask])
        return try GoogleRoutes.parse(d)
    }

    /// Trace (lấy mẫu tối đa `maxTracePoints` điểm), đổi chỉ số về `points` gốc.
    func trace(_ points: [GeoPoint]) async throws -> (matchedLengthKm: Double, limits: [SpeedLimitSpan], streets: [StreetSpan]) {
        let n = points.count
        guard n >= 2 else { throw RoutingError.noRoute }
        let stride = max(1, Int((Double(n) / Double(Self.maxTracePoints)).rounded(.up)))
        var idx = Array(Swift.stride(from: 0, to: n, by: stride))
        if idx.last != n - 1 { idx.append(n - 1) }
        let d = try await post(Valhalla.baseURL.appendingPathComponent("trace_attributes"),
                               Valhalla.traceRequestBody(points: idx.map { points[$0] }), headers: [:])
        let t = try Valhalla.parseTrace(d)
        let limits: [SpeedLimitSpan] = t.limits.compactMap { s in
            let a = min(max(s.start, 0), idx.count - 1), b = min(max(s.end, 0), idx.count - 1)
            guard a <= b else { return nil }
            let end = b + 1 < idx.count ? idx[b + 1] - 1 : n - 1
            return SpeedLimitSpan(start: idx[a], end: max(idx[a], end), kmh: s.kmh)
        }
        let streets: [StreetSpan] = t.streets.compactMap { s in
            let a = min(max(s.start, 0), idx.count - 1), b = min(max(s.end, 0), idx.count - 1)
            guard a <= b else { return nil }
            let end = b + 1 < idx.count ? idx[b + 1] - 1 : n - 1
            return StreetSpan(start: idx[a], end: max(idx[a], end), name: s.name)
        }
        return (t.matchedLengthKm, limits, streets)
    }

    private func post(_ url: URL, _ body: Data, headers: [String: String]) async throws -> Data {
        let (d, code) = try await Self.send(session, url, body, headers)
        guard code == 200 else { throw RoutingError.http(code, String(decoding: d, as: UTF8.self)) }
        return d
    }

    private static func send(_ session: URLSession, _ url: URL, _ body: Data,
                             _ headers: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await session.data(for: req)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Câu `error.message` trong JSON lỗi của Google.
    static func googleMessage(_ data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let e = o["error"] as? [String: Any], let m = e["message"] as? String else { return nil }
        return m
    }

    public static func testGoogleKey(_ key: String, session: URLSession = .shared) async -> KeyTestResult {
        let body = GoogleRoutes.requestBody(from: GeoPoint(lat: 10.7769, lon: 106.7009),
                                            to: GeoPoint(lat: 10.7626, lon: 106.6602))
        do {
            let (d, code) = try await send(session, GoogleRoutes.url, body,
                                           ["X-Goog-Api-Key": key, "X-Goog-FieldMask": "routes.distanceMeters"])
            let text = String(decoding: d, as: UTF8.self)
            let u = text.uppercased()
            if code == 200 {
                return u.contains("ROUTES") ? .ok : .twoWheelerUnsupported
            }
            if u.contains("API_KEY_INVALID") || u.contains("API KEY NOT VALID") {
                return .invalidKey
            }
            if code == 400 || code == 401 || code == 403 || code == 429 {
                if !u.contains("TWO_WHEELER") || u.contains("PERMISSION_DENIED") {
                    return .rejected(googleMessage(d) ?? "HTTP \(code)")
                }
            }
            if u.contains("TWO_WHEELER") || u.contains("TRAVEL MODE") || u.contains("TRAVEL_MODE") {
                return .twoWheelerUnsupported
            }
            return .network("HTTP \(code): \(text.prefix(200))")
        } catch {
            return .network(error.localizedDescription)
        }
    }
}
