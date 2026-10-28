import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Một điểm trên bản đồ (độ, WGS84).
public struct GeoPoint: Equatable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
    /// Toạ độ hợp lệ (vĩ độ ±90, kinh độ ±180).
    public var isValid: Bool { lat.isFinite && lon.isFinite && abs(lat) <= 90 && abs(lon) <= 180 }
}

/// Điểm đến lấy từ link chia sẻ. Có `point` thì đi thẳng; chỉ có `searchText` thì phải tìm rồi cho người lái xác nhận.
public struct SharedDestination: Equatable {
    public var name: String?
    public var point: GeoPoint?
    public var stops: [GeoPoint]
    public var searchText: String?
    public init(name: String? = nil, point: GeoPoint? = nil, stops: [GeoPoint] = [], searchText: String? = nil) {
        self.name = name
        self.point = point
        self.stops = stops
        self.searchText = searchText
    }
}

/// Đọc link Google Maps / Apple Maps được chia sẻ vào app (xem routing-options.md, mục "Shared links").
public enum ShareLink {
    /// URL http(s) đầu tiên trong đoạn text.
    public static func firstURL(in text: String) -> URL? {
        guard let m = groups(#"https?://[^\s<>"]+"#, in: text, caseInsensitive: true).first?.first else { return nil }
        var s = Substring(m)
        while let c = s.last, ".,;".contains(c) { s = s.dropLast() }
        return URL(string: String(s))
    }

    /// Link rút gọn cần theo redirect (maps.app.goo.gl, goo.gl/maps).
    public static func isShortLink(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        if host == "maps.app.goo.gl" { return true }
        return host == "goo.gl" && url.path.hasPrefix("/maps")
    }

    /// Phân tích offline một link bản đồ. `sharedText` cho tên từ dòng đầu (nếu dòng đó không phải URL).
    /// Toạ độ ngoài phạm vi hay không phải link bản đồ: trả nil, không đoán.
    public static func parse(url: URL, sharedText: String?) -> SharedDestination? {
        guard var dest = parseMapURL(url) else { return nil }
        if dest.name == nil, let line = sharedText?.split(whereSeparator: \.isNewline).first {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.range(of: "http", options: .caseInsensitive) == nil { dest.name = t }
        }
        return dest
    }

    /// Tìm URL, theo link rút gọn bằng tay (không tự redirect, đọc header Location, tối đa 5 bước) rồi phân tích.
    public static func resolve(text: String) async -> SharedDestination? {
        guard var url = firstURL(in: text) else { return nil }
        var hops = 0
        while isShortLink(url) || consentTarget(url) != nil {
            guard hops < 5 else { return nil }
            if let inner = consentTarget(url) { url = inner; hops += 1; continue }
            guard let next = await location(of: url) else { return nil }
            url = next
            hops += 1
        }
        return parse(url: url, sharedText: text)
    }

    /// Trang đồng ý cookie của Google (consent.google.com/...?continue=<link bản đồ>): lấy link đích trong `continue`.
    static func consentTarget(_ url: URL) -> URL? {
        guard (url.host ?? "").lowercased().hasPrefix("consent."),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let v = c.queryItems?.first(where: { $0.name == "continue" })?.value else { return nil }
        return URL(string: v)
    }

    // MARK: - Phân tích

    private static func parseMapURL(_ url: URL) -> SharedDestination? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (comps.host ?? "").lowercased()
        let rawPath = comps.percentEncodedPath
        let isGoogle = host.contains("google.") && (host.hasPrefix("maps.") || rawPath.hasPrefix("/maps"))
        let isApple = host == "maps.apple.com"
        guard isGoogle || isApple else { return nil }

        let segs = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var query: [String: String] = [:]
        for item in comps.percentEncodedQueryItems ?? [] where query[item.name.lowercased()] == nil {
            if let v = item.value.map(decode), !v.isEmpty { query[item.name.lowercased()] = v }
        }

        // 1. Chỉ đường: /maps/dir/<đi>/<dừng>.../<đến>/@.../data=...
        if let i = segs.firstIndex(of: "dir") {
            let rest = segs[(i + 1)...].prefix { !$0.hasPrefix("@") && !$0.hasPrefix("data=") }
            // Bỏ phần rỗng ở cuối (".../dir/A/B/" hoặc ".../dir/?api=1&destination=...").
            var names = rest.map(decode)
            while let l = names.last, l.isEmpty { names.removeLast() }
            let data = segs.first { $0.hasPrefix("data=") } ?? ""
            let blocks = waypointBlocks(decode(data))
            var points: [GeoPoint?] = []
            for (k, n) in names.enumerated() {
                var p = latLng(n)
                if p == nil, k < blocks.count { p = blocks[k] }
                if let p = p, !p.isValid { return nil }
                points.append(p)
            }
            if names.isEmpty {
                if query["destination"] == nil && query["daddr"] == nil { return nil }
            } else {
                let last = names.count - 1
                let stops = names.count > 2 ? points[1..<last].compactMap { $0 } : []
                let destName = latLng(names[last]) == nil && !names[last].isEmpty ? names[last] : nil
                if let p = points[last] { return SharedDestination(name: destName, point: p, stops: stops) }
                guard let t = destName else { return nil }
                return SharedDestination(name: t, stops: stops, searchText: t)
            }
        }

        // Tên: đoạn sau /place/, hoặc q= dạng chữ (Apple: ll= toạ độ + q= tên).
        var placeName: String?
        if let i = segs.firstIndex(of: "place"), i + 1 < segs.count {
            let n = decode(segs[i + 1])
            if !n.isEmpty { placeName = n }
        }
        // /maps/search/<chữ hoặc toạ độ>/ : chữ này là thứ cần tìm (khung nhìn @ chỉ là vùng đang xem).
        var searchSeg: String?
        if let i = segs.firstIndex(of: "search"), i + 1 < segs.count {
            let n = decode(segs[i + 1])
            if !n.isEmpty, !n.hasPrefix("@"), !n.hasPrefix("data=") { searchSeg = n }
        }
        // /maps/place/<lat,lng>/ hoặc /maps/search/<lat,lng>/: toạ độ nằm ngay trong đường dẫn.
        var pathPoint: GeoPoint?
        for cand in [placeName, searchSeg] {
            if let c = cand, let p = latLng(c) { pathPoint = p; break }
        }
        if pathPoint != nil, placeName.flatMap(latLng) != nil { placeName = nil }
        let textKeys = ["q", "query", "destination", "daddr"]

        // 2. !3d<lat>!4d<lng> của địa điểm (không lấy khung nhìn @).
        var point: GeoPoint?
        if let m = groups(#"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"#, in: rawPath).last {
            point = GeoPoint(lat: Double(m[1]) ?? .nan, lon: Double(m[2]) ?? .nan)
        }
        if point == nil { point = pathPoint }
        // 3. q=, ll=, query=, destination= dạng toạ độ (Apple Maps: coordinate=).
        if point == nil {
            for k in ["q", "ll", "query", "destination", "daddr", "coordinate"] {
                if let v = query[k], let p = latLng(v) { point = p; break }
            }
        }
        // 4. Chỉ có khung nhìn @lat,lng. Link /search/<chữ> thì không dùng khung nhìn: phải tìm chữ đó.
        let searchOnlyText = searchSeg != nil && pathPoint == nil
        if point == nil, !searchOnlyText, let m = groups(#"@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)"#, in: rawPath).first {
            point = GeoPoint(lat: Double(m[1]) ?? .nan, lon: Double(m[2]) ?? .nan)
        }
        let text = textKeys.lazy.compactMap { k -> String? in
            guard let v = query[k], latLng(v) == nil else { return nil }
            return v
        }.first ?? searchSeg.flatMap { latLng($0) == nil ? $0 : nil }
        if isApple, placeName == nil, let n = query["name"] { placeName = n }
        if let p = point {
            guard p.isValid else { return nil }
            return SharedDestination(name: placeName ?? text, point: p)
        }
        // 5. Chữ thay cho toạ độ, hoặc chỉ có tên: phải tìm kiếm.
        if let t = text ?? placeName { return SharedDestination(name: placeName ?? t, searchText: t) }
        return nil
    }

    /// Toạ độ từng waypoint trong phần data= của link chỉ đường: mỗi khối `!1m<n>` chứa `!1d<lng>!2d<lat>` (có thể trống).
    private static func waypointBlocks(_ data: String) -> [GeoPoint?] {
        let tokens = data.split(separator: "!").map(String.init)
        guard var i = tokens.firstIndex(where: { $0.hasPrefix("1m") }) else { return [] }
        var out: [GeoPoint?] = []
        while i < tokens.count, tokens[i].hasPrefix("1m"), let n = Int(tokens[i].dropFirst(2)) {
            let end = min(tokens.count, i + 1 + n)
            let block = tokens[(i + 1)..<end]
            let lng = block.first { $0.hasPrefix("1d") }.flatMap { Double($0.dropFirst(2)) }
            let lat = block.first { $0.hasPrefix("2d") }.flatMap { Double($0.dropFirst(2)) }
            if let lat = lat, let lng = lng { out.append(GeoPoint(lat: lat, lon: lng)) } else { out.append(nil) }
            i = end
        }
        return out
    }

    /// "lat,lng" (đúng hai số) → điểm; không kiểm tra phạm vi ở đây.
    private static func latLng(_ s: String) -> GeoPoint? {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("loc:") { s = String(s.dropFirst(4)) }   // ?q=loc:lat,lng
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return GeoPoint(lat: lat, lon: lon)
    }

    /// Giải mã phần URL: '+' thành dấu cách, rồi %XX.
    private static func decode(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "+", with: " ")
        return (t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespaces)
    }

    private static func groups(_ pattern: String, in s: String, caseInsensitive: Bool = false) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { k in Range(m.range(at: k), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    // MARK: - Mạng

    /// Chặn tự động redirect để đọc được header Location.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// GET không theo redirect, trả URL trong header Location (nil nếu không có).
    private static func location(of url: URL) async -> URL? {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let response: URLResponse? = await withCheckedContinuation { cont in
            session.dataTask(with: req) { _, resp, _ in cont.resume(returning: resp) }.resume()
        }
        guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) else { return nil }
        let loc = http.allHeaderFields.first { ($0.key as? String)?.lowercased() == "location" }?.value as? String
        return loc.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
    }
}
