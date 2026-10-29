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
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,precipitation"),
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
            let precipitation: Double?
        }
        let current: Current
    }

    /// Mưa thực đo (mm) từ mức này trở lên thì coi là đang mưa dù mã WMO của mô hình nói trời khô.
    public static let rainThresholdMm = 0.2

    /// Mã WMO "khô" (0–3, 45, 48) nhưng đang có mưa ≥ 0,2 mm → mã 61 (mưa nhẹ: kiểu .rain, chữ "Mưa", icon xe 16).
    public static func effectiveCode(_ code: Int, precipitationMm: Double?) -> Int {
        let dry = (0...3).contains(code) || code == 45 || code == 48
        if dry, let p = precipitationMm, p >= rainThresholdMm { return 61 }
        return code
    }

    /// Đọc JSON trả về của Open-Meteo thành `WeatherInfo` (nhiệt độ làm tròn tới độ).
    public static func parse(_ data: Data, place: String) throws -> WeatherInfo {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let code = effectiveCode(r.current.weather_code, precipitationMm: r.current.precipitation)
        let d = describe(code: code, isDay: r.current.is_day != 0)
        return WeatherInfo(tempC: Int(r.current.temperature_2m.rounded()), kind: d.kind, label: d.label, place: place)
    }

    // MARK: - Dự báo cho xe (cmd 5)

    /// Một điểm dự báo (mã WMO đã qua `effectiveCode` với điểm "bây giờ").
    public struct Point: Equatable {
        public var code: Int
        public var isDay: Bool
        public var tempC: Double
        public var maxC: Double
        public var minC: Double
        public var precipPercent: Int
        public init(code: Int, isDay: Bool, tempC: Double, maxC: Double, minC: Double, precipPercent: Int) {
            self.code = code
            self.isDay = isDay
            self.tempC = tempC
            self.maxC = maxC
            self.minC = minC
            self.precipPercent = precipPercent
        }
    }

    public struct Forecast: Equatable {
        public var now: Point
        /// Tối đa 3 giờ kế tiếp (sau giờ hiện tại).
        public var hours: [Point]
        /// Các ngày kế tiếp (ngày mai trở đi), tối đa 6.
        public var days: [Point]
        public init(now: Point, hours: [Point], days: [Point]) {
            self.now = now
            self.hours = hours
            self.days = days
        }
    }

    /// URL dự báo: hiện tại + 3 giờ kế + 7 ngày, múi giờ tự động.
    public static func forecastURL(lat: Double, lon: Double) -> URL? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,precipitation"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
        ]
        return c?.url
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
            let precipitation: Double?
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
            let precipitation_probability: [Double?]?
        }
        struct Daily: Decodable {
            let weather_code: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Double?]?
        }
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    /// Đọc JSON dự báo của Open-Meteo. Giờ kế tiếp = 3 mốc giờ đầu tiên có thời gian > `current.time`
    /// (cùng múi giờ địa phương, so chuỗi `yyyy-MM-ddTHH:mm`). Ngày = các chỉ số 1…6 (bỏ hôm nay).
    /// Thiếu hoặc null thì bỏ điểm đó (ô tương ứng không được gửi).
    public static func parseForecast(_ data: Data) throws -> Forecast {
        let r = try JSONDecoder().decode(ForecastResponse.self, from: data)
        func at<T>(_ a: [T?]?, _ i: Int) -> T? { (a != nil && i < a!.count) ? a![i] : nil }

        let todayMax = at(r.daily.temperature_2m_max, 0) ?? r.current.temperature_2m
        let todayMin = at(r.daily.temperature_2m_min, 0) ?? r.current.temperature_2m
        let todayPrecip = Int((at(r.daily.precipitation_probability_max, 0) ?? 0).rounded())
        let nowCode = effectiveCode(r.current.weather_code, precipitationMm: r.current.precipitation)
        let now = Point(code: nowCode, isDay: r.current.is_day != 0, tempC: r.current.temperature_2m,
                        maxC: todayMax, minC: todayMin, precipPercent: todayPrecip)

        var hours: [Point] = []
        for (i, t) in r.hourly.time.enumerated() where t > r.current.time {
            guard hours.count < 3 else { break }
            guard let temp = at(r.hourly.temperature_2m, i), let code = at(r.hourly.weather_code, i) else { continue }
            // Giờ trong ngày từ chuỗi "…THH:mm": 6 giờ sáng đến trước 18 giờ là ban ngày (đoán, Open-Meteo hourly không kèm is_day ở đây)
            let timePart: String = t.split(separator: "T").last.map(String.init) ?? ""
            let hour = Int(String(timePart.prefix(2))) ?? 12
            hours.append(Point(code: code, isDay: hour >= 6 && hour < 18, tempC: temp, maxC: 0, minC: 0,
                               precipPercent: Int((at(r.hourly.precipitation_probability, i) ?? 0).rounded())))
        }

        var days: [Point] = []
        for i in 1...6 {
            guard let code = at(r.daily.weather_code, i), let hi = at(r.daily.temperature_2m_max, i),
                  let lo = at(r.daily.temperature_2m_min, i) else { break }
            days.append(Point(code: code, isDay: true, tempC: (hi + lo) / 2, maxC: hi, minC: lo,
                              precipPercent: Int((at(r.daily.precipitation_probability_max, i) ?? 0).rounded())))
        }
        return Forecast(now: now, hours: hours, days: days)
    }

    /// Mã WMO → mã biểu tượng của xe (docs/protocol/link-b-ccu.md, bảng "Icon codes"), ngày / đêm.
    /// Dải tuyết 71–77, 85, 86 chỉ ghi "4, 18, 19" nên phân chia là đoán: 71, 85 → 4; 73, 77 → 18; 75, 86 → 19.
    public static func bikeIcon(code: Int, isDay: Bool) -> UInt8 {
        switch code {
        case 0: return isDay ? 0 : 128
        case 1, 2: return isDay ? 1 : 129
        case 3: return isDay ? 2 : 130
        case 45, 48: return 8
        case 51, 53, 55, 61: return 16
        case 56, 57: return 20
        case 63: return 3
        case 65, 82: return 17
        case 66, 67: return 7
        case 71, 85: return 4
        case 72, 73, 77: return 18
        case 74, 75, 76, 86: return 19
        case 80, 81: return isDay ? 13 : 141
        case 95: return isDay ? 14 : 142
        case 96, 99: return 12
        default: return 15
        }
    }

    /// Mười khung cmd 5, theo thứ tự ô 0…9: ô 0 hiện tại; ô 1–5 và 9 là sáu ngày kế; ô 6–8 là ba giờ kế (max = min = 0).
    /// Ô nào thiếu dữ liệu thì bỏ. Mỗi khung kèm số ô để gọi `CCUCommand.forecast`.
    public static func forecastFrames(_ f: Forecast, seq: () -> UInt8) -> [[UInt8]] {
        func frame(_ slot: UInt8, _ p: Point) -> [UInt8] {
            CCUCommand.forecast(seq: seq(), slot: slot, icon: bikeIcon(code: p.code, isDay: p.isDay), tempC: p.tempC,
                                maxC: p.maxC, minC: p.minC, precipPercent: p.precipPercent)
        }
        var out: [[UInt8]] = [frame(0, f.now)]
        let daySlots: [UInt8] = [1, 2, 3, 4, 5, 9]
        for (i, p) in f.days.enumerated() where i < daySlots.count { out.append(frame(daySlots[i], p)) }
        for (i, p) in f.hours.enumerated() where i < 3 { out.append(frame(UInt8(6 + i), p)) }
        return out
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

/// Lấy dự báo (hiện tại, 3 giờ kế, 6 ngày kế) tại toạ độ để gửi cho xe.
public func fetchForecast(lat: Double, lon: Double) async throws -> Weather.Forecast {
    guard let url = Weather.forecastURL(lat: lat, lon: lon) else { throw Weather.WeatherError.badURL }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw Weather.WeatherError.badResponse
    }
    return try Weather.parseForecast(data)
}
