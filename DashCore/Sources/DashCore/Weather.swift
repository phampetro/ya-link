import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thời tiết từ Open-Meteo (miễn phí, không cần key). Kết quả là `WeatherInfo` cho trang chủ.
public enum Weather {
    public enum WeatherError: Error { case badURL, badResponse }

    /// URL lấy thời tiết hiện tại (nhiệt độ, mã WMO, ngày/đêm), múi giờ tự động.
    public static func url(lat: Double, lon: Double) -> URL? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return c?.url
    }

    /// Mã thời tiết WMO → (kiểu biểu tượng, chữ tiếng Việt). Ban đêm trời quang/ít mây dùng biểu tượng trăng.
    public static func describe(code: Int, isDay: Bool) -> (kind: WeatherInfo.Kind, label: String) {
        switch code {
        case 0: return (isDay ? .sun : .night, "Trời quang")
        case 1: return isDay ? (.sun, "Nắng nhẹ") : (.night, "Ít mây")
        case 2: return (.cloud, "Ít mây")
        case 3: return (.cloud, "Nhiều mây")
        case 45, 48: return (.cloud, "Sương mù")
        case 51...57: return (.rain, "Mưa phùn")
        case 61...67: return (.rain, "Mưa")
        case 80...82: return (.rain, "Mưa rào")
        case 95...99: return (.storm, "Dông")
        default: return (.cloud, "—")
        }
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        let current: Current
    }

    /// Đọc JSON trả về của Open-Meteo thành `WeatherInfo` (nhiệt độ làm tròn tới độ).
    public static func parse(_ data: Data, place: String) throws -> WeatherInfo {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let d = describe(code: r.current.weather_code, isDay: r.current.is_day != 0)
        return WeatherInfo(tempC: Int(r.current.temperature_2m.rounded()), kind: d.kind, label: d.label, place: place)
    }

    /// Rút gọn tên địa danh cho đồng hồ: "Quận 1"→"Q.1", "Phường Bến Thành"→"P. Bến Thành",
    /// "Thành phố Thủ Đức"→"TP. Thủ Đức", "Huyện X"→"H. X". Ưu tiên quận/phường, không có thì lấy thành phố.
    public static func shortPlaceName(subLocality: String?, locality: String?) -> String? {
        for raw in [subLocality, locality] {
            let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return shorten(s) }
        }
        return nil
    }

    private static let prefixes: [(String, String)] = [
        ("Thành phố ", "TP."), ("Thị trấn ", "TT."), ("Thị xã ", "TX."),
        ("Quận ", "Q."), ("Phường ", "P."), ("Huyện ", "H."), ("Xã ", "X."),
    ]

    private static func shorten(_ s: String) -> String {
        for (long, short) in prefixes {
            let lower = s.lowercased()
            if lower.hasPrefix(long.lowercased()) {
                let rest = String(s.dropFirst(long.count)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { return s }
                // Số đi liền ("Q.1"), chữ cách một khoảng ("P. Bến Thành")
                return rest.first!.isNumber ? short + rest : short + " " + rest
            }
        }
        return s
    }
}

/// Lấy thời tiết hiện tại tại toạ độ, gắn tên nơi `place` (đã rút gọn).
public func fetchWeather(lat: Double, lon: Double, place: String) async throws -> WeatherInfo {
    guard let url = Weather.url(lat: lat, lon: lon) else { throw Weather.WeatherError.badURL }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw Weather.WeatherError.badResponse
    }
    return try Weather.parse(data, place: place)
}

/// Bản rút gọn tên địa danh (gọi thẳng, cùng luật với `Weather.shortPlaceName`).
public func shortPlaceName(subLocality: String?, locality: String?) -> String? {
    Weather.shortPlaceName(subLocality: subLocality, locality: locality)
}
