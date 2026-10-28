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
}
