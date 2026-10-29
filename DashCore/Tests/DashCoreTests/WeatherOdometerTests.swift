import XCTest
@testable import DashCore

/// Thời tiết (mã WMO, đọc JSON Open-Meteo, rút gọn địa danh) và chữ thanh dưới ODO/TRIP/OIL.
final class WeatherOdometerTests: XCTestCase {
    // MARK: - Thời tiết

    func testWMOMapping() {
        XCTAssertEqual(Weather.describe(code: 0, isDay: true).kind, .sun)
        XCTAssertEqual(Weather.describe(code: 0, isDay: true).label, "Trời quang")
        XCTAssertEqual(Weather.describe(code: 0, isDay: false).kind, .night)
        XCTAssertEqual(Weather.describe(code: 1, isDay: true).label, "Nắng nhẹ")
        XCTAssertEqual(Weather.describe(code: 1, isDay: true).kind, .sun)
        XCTAssertEqual(Weather.describe(code: 2, isDay: true).kind, .cloud)
        XCTAssertEqual(Weather.describe(code: 2, isDay: true).label, "Ít mây")
        XCTAssertEqual(Weather.describe(code: 3, isDay: true).label, "Nhiều mây")
        XCTAssertEqual(Weather.describe(code: 45, isDay: true).label, "Sương mù")
        XCTAssertEqual(Weather.describe(code: 48, isDay: true).label, "Sương mù")
        XCTAssertEqual(Weather.describe(code: 53, isDay: true).label, "Mưa phùn")
        XCTAssertEqual(Weather.describe(code: 63, isDay: true).label, "Mưa")
        XCTAssertEqual(Weather.describe(code: 63, isDay: true).kind, .rain)
        XCTAssertEqual(Weather.describe(code: 81, isDay: false).label, "Mưa rào")
        XCTAssertEqual(Weather.describe(code: 95, isDay: true).kind, .storm)
        XCTAssertEqual(Weather.describe(code: 95, isDay: true).label, "Dông")
        XCTAssertEqual(Weather.describe(code: 71, isDay: true).label, "—")
    }

    func testParseOpenMeteo() throws {
        let json = """
        {"latitude":10.78,"longitude":106.7,"timezone":"Asia/Ho_Chi_Minh",
         "current_units":{"temperature_2m":"°C","weather_code":"wmo code","is_day":""},
         "current":{"time":"2026-10-28T14:00","interval":900,"temperature_2m":31.6,"weather_code":80,"is_day":1}}
        """
        let w = try Weather.parse(Data(json.utf8), place: "Q.1")
        XCTAssertEqual(w, WeatherInfo(tempC: 32, kind: .rain, label: "Mưa rào", place: "Q.1"))
    }

    func testParseNight() throws {
        let json = #"{"current":{"temperature_2m":26.2,"weather_code":0,"is_day":0}}"#
        let w = try Weather.parse(Data(json.utf8), place: "TP. Thủ Đức")
        XCTAssertEqual(w.kind, .night)
        XCTAssertEqual(w.tempC, 26)
    }

    func testParseBadJSONThrows() {
        XCTAssertThrowsError(try Weather.parse(Data("{}".utf8), place: ""))
    }

    func testURL() throws {
        let s = try XCTUnwrap(Weather.url(lat: 10.7769, lon: 106.7009)).absoluteString
        XCTAssertTrue(s.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
        XCTAssertTrue(s.contains("latitude=10.7769"))
        XCTAssertTrue(s.contains("longitude=106.7009"))
        XCTAssertTrue(s.contains("current=temperature_2m,weather_code,is_day"))
        XCTAssertTrue(s.contains("timezone=auto"))
    }

    func testShortPlaceName() {
        XCTAssertEqual(shortPlaceName(subLocality: "Quận 1", locality: "Hồ Chí Minh"), "Q.1")
        XCTAssertEqual(shortPlaceName(subLocality: "Phường Bến Thành", locality: nil), "P. Bến Thành")
        XCTAssertEqual(shortPlaceName(subLocality: nil, locality: "Thành phố Thủ Đức"), "TP. Thủ Đức")
        XCTAssertEqual(shortPlaceName(subLocality: "Huyện Nhà Bè", locality: nil), "H. Nhà Bè")
        XCTAssertEqual(shortPlaceName(subLocality: "  ", locality: "Quận Bình Thạnh"), "Q. Bình Thạnh")
        XCTAssertEqual(shortPlaceName(subLocality: nil, locality: "Đà Lạt"), "Đà Lạt")
        XCTAssertNil(shortPlaceName(subLocality: nil, locality: nil))
    }

    // MARK: - ODO

    func testOdoText() {
        let b = OdometerBook()
        XCTAssertEqual(b.barText(odoKm: 3214.7), "ODO 3.214 km")
        XCTAssertEqual(b.barText(odoKm: 1234567), "ODO 1.234.567 km")
        XCTAssertEqual(b.barText(odoKm: 512), "ODO 512 km")
        XCTAssertEqual(b.barText(odoKm: nil), "ODO -- km")
    }

    func testTripText() {
        var b = OdometerBook(trip1StartKm: 3000, trip2StartKm: 3200, barItem: .trip1)
        XCTAssertEqual(b.barText(odoKm: 3125.4), "TRIP 1 · 125,4 km")
        XCTAssertEqual(b.barText(odoKm: nil), "TRIP 1 · -- km")
        b.barItem = .trip2
        XCTAssertEqual(b.barText(odoKm: 3218.7), "TRIP 2 · 18,7 km")
        XCTAssertEqual(b.barText(odoKm: nil), "TRIP 2 · -- km")
        b.resetTrip2(odoKm: 3218.7)
        XCTAssertEqual(b.barText(odoKm: 3218.7), "TRIP 2 · 0,0 km")
        b.barItem = .trip1
        b.resetTrip1(odoKm: 3300)
        XCTAssertEqual(b.barText(odoKm: 3310.06), "TRIP 1 · 10,1 km")
    }

    func testNilStartMeansTripZero() {
        var b = OdometerBook(barItem: .trip1)
        XCTAssertEqual(b.barText(odoKm: 5000), "TRIP 1 · 0,0 km")
        b.sync(odoKm: 5000)
        XCTAssertEqual(b.trip1StartKm, 5000)
        XCTAssertEqual(b.trip2StartKm, 5000)
        XCTAssertEqual(b.oilChangedAtKm, 5000)
        XCTAssertEqual(b.barText(odoKm: 5012.3), "TRIP 1 · 12,3 km")
        b.sync(odoKm: 6000)                       // mốc đã có thì không đổi
        XCTAssertEqual(b.trip1StartKm, 5000)
    }

    func testOilText() {
        var b = OdometerBook(oilChangedAtKm: 2000, barItem: .oil)
        XCTAssertEqual(b.oilIntervalKm, 1500)
        XCTAssertEqual(b.barText(odoKm: 3180), "OIL · còn 320 km")
        XCTAssertEqual(b.barText(odoKm: 3540), "OIL · quá 40 km")
        XCTAssertEqual(b.barText(odoKm: 3500), "OIL · còn 0 km")
        XCTAssertEqual(b.barText(odoKm: nil), "OIL · -- km")
        b.oilChanged(odoKm: 3540)
        XCTAssertEqual(b.barText(odoKm: 3540), "OIL · còn 1.500 km")
    }

    func testCodableDefaults() throws {
        let old = try JSONDecoder().decode(OdometerBook.self, from: Data(#"{"trip1StartKm":10}"#.utf8))
        XCTAssertEqual(old, OdometerBook(trip1StartKm: 10))
        let b = OdometerBook(trip1StartKm: 1, trip2StartKm: 2, oilChangedAtKm: 3, oilIntervalKm: 2000, barItem: .oil)
        let back = try JSONDecoder().decode(OdometerBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }

    // MARK: - Mưa thực đo, dự báo cho xe

    func testRainOverridesDryModelCode() throws {
        let json = #"{"current":{"temperature_2m":28.0,"weather_code":3,"is_day":1,"precipitation":0.4}}"#
        let w = try Weather.parse(Data(json.utf8), place: "")
        XCTAssertEqual(w.kind, .rain)
        XCTAssertEqual(w.label, "Mưa")
        // dưới ngưỡng 0,2 mm: giữ nguyên
        let dry = #"{"current":{"temperature_2m":28.0,"weather_code":3,"is_day":1,"precipitation":0.1}}"#
        XCTAssertEqual(try Weather.parse(Data(dry.utf8), place: "").label, "Nhiều mây")
        // mã đã là mưa thì không đổi
        let rain = #"{"current":{"temperature_2m":28.0,"weather_code":80,"is_day":1,"precipitation":2.0}}"#
        XCTAssertEqual(try Weather.parse(Data(rain.utf8), place: "").label, "Mưa rào")
        XCTAssertEqual(Weather.effectiveCode(45, precipitationMm: 0.2), 61)
        XCTAssertEqual(Weather.effectiveCode(71, precipitationMm: 5), 71)
        XCTAssertTrue(try XCTUnwrap(Weather.url(lat: 1, lon: 2)).absoluteString.contains("precipitation"))
    }

    func testBikeIconTable() {
        XCTAssertEqual(Weather.bikeIcon(code: 0, isDay: true), 0)
        XCTAssertEqual(Weather.bikeIcon(code: 0, isDay: false), 128)
        XCTAssertEqual(Weather.bikeIcon(code: 2, isDay: true), 1)
        XCTAssertEqual(Weather.bikeIcon(code: 1, isDay: false), 129)
        XCTAssertEqual(Weather.bikeIcon(code: 3, isDay: true), 2)
        XCTAssertEqual(Weather.bikeIcon(code: 3, isDay: false), 130)
        XCTAssertEqual(Weather.bikeIcon(code: 48, isDay: false), 8)
        for c in [51, 53, 55, 61] { XCTAssertEqual(Weather.bikeIcon(code: c, isDay: true), 16) }
        XCTAssertEqual(Weather.bikeIcon(code: 57, isDay: true), 20)
        XCTAssertEqual(Weather.bikeIcon(code: 63, isDay: true), 3)
        XCTAssertEqual(Weather.bikeIcon(code: 65, isDay: true), 17)
        XCTAssertEqual(Weather.bikeIcon(code: 82, isDay: false), 17)
        XCTAssertEqual(Weather.bikeIcon(code: 67, isDay: true), 7)
        XCTAssertEqual(Weather.bikeIcon(code: 81, isDay: true), 13)
        XCTAssertEqual(Weather.bikeIcon(code: 80, isDay: false), 141)
        XCTAssertEqual(Weather.bikeIcon(code: 95, isDay: true), 14)
        XCTAssertEqual(Weather.bikeIcon(code: 95, isDay: false), 142)
        XCTAssertEqual(Weather.bikeIcon(code: 96, isDay: false), 12)
        XCTAssertEqual(Weather.bikeIcon(code: 99, isDay: true), 12)
        XCTAssertEqual(Weather.bikeIcon(code: 62, isDay: true), 15)     // "anything else"
        XCTAssertTrue([4, 18, 19].contains(Weather.bikeIcon(code: 73, isDay: true)))
    }

    private var forecastJSON: String {
        """
        {"current":{"time":"2026-10-28T14:10","temperature_2m":31.5,"weather_code":2,"is_day":1,"precipitation":0.0},
         "hourly":{"time":["2026-10-28T13:00","2026-10-28T14:00","2026-10-28T15:00","2026-10-28T16:00","2026-10-28T17:00","2026-10-28T18:00"],
           "temperature_2m":[30.0,31.0,32.4,31.1,29.0,27.0],
           "weather_code":[1,2,3,61,80,0],
           "precipitation_probability":[0,10,20,45,70,5]},
         "daily":{"time":["d0","d1","d2","d3","d4","d5","d6"],
           "weather_code":[2,3,63,95,0,45,65],
           "temperature_2m_max":[33.0,34.0,30.0,31.0,35.0,32.0,29.0],
           "temperature_2m_min":[26.0,25.0,24.0,25.0,26.0,27.0,23.0],
           "precipitation_probability_max":[40,60,90,80,0,15,100]}}
        """
    }

    func testParseForecast() throws {
        let f = try Weather.parseForecast(Data(forecastJSON.utf8))
        XCTAssertEqual(f.now, Weather.Point(code: 2, isDay: true, tempC: 31.5, maxC: 33, minC: 26, precipPercent: 40))
        XCTAssertEqual(f.hours.map { $0.tempC }, [32.4, 31.1, 29.0])          // 15, 16, 17 giờ
        XCTAssertEqual(f.hours.map { $0.code }, [3, 61, 80])
        XCTAssertEqual(f.hours.map { $0.precipPercent }, [20, 45, 70])
        XCTAssertEqual(f.hours[0].maxC, 0)
        XCTAssertEqual(f.days.count, 6)
        XCTAssertEqual(f.days[0], Weather.Point(code: 3, isDay: true, tempC: 29.5, maxC: 34, minC: 25, precipPercent: 60))
        XCTAssertEqual(f.days[5].code, 65)
        XCTAssertThrowsError(try Weather.parseForecast(Data("{}".utf8)))
    }

    func testForecastFramesSlots() throws {
        let f = try Weather.parseForecast(Data(forecastJSON.utf8))
        var n: UInt8 = 0
        let frames = Weather.forecastFrames(f, seq: { n += 1; return n })
        XCTAssertEqual(frames.count, 10)
        XCTAssertEqual(frames.map { $0[3] }, [0, 1, 2, 3, 4, 5, 9, 6, 7, 8])   // số ô
        XCTAssertEqual(frames.map { $0[2] }, Array(1...10))                    // seq tươi, tăng dần
        XCTAssertEqual(frames[0], [0x00, 0x05, 1, 0, 1, 0x01, 0x3B, 0x01, 0x4A, 0x01, 0x04, 8])   // 31,5 → 01 3B, ít mây ngày = 1
        XCTAssertEqual(frames[1], [0x00, 0x05, 2, 1, 2, 0x01, 0x27, 0x01, 0x54, 0x00, 0xFA, 12])  // 29,5 / 34 / 25, mưa 60 % → 12
        XCTAssertEqual(frames[7], [0x00, 0x05, 8, 6, 2, 0x01, 0x44, 0, 0, 0, 0, 4])              // 32,4 → 324 = 01 44, mưa 20 % → 4
    }

    func testForecastURL() throws {
        let s = try XCTUnwrap(Weather.forecastURL(lat: 10.7769, lon: 106.7009)).absoluteString
        XCTAssertTrue(s.contains("forecast_days=7"))
        XCTAssertTrue(s.contains("timezone=auto"))
        XCTAssertTrue(s.contains("hourly=temperature_2m,weather_code,precipitation_probability"))
        XCTAssertTrue(s.contains("daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"))
        XCTAssertTrue(s.contains("current=temperature_2m,weather_code,is_day,precipitation"))
    }
}
