import XCTest
@testable import DashCore

/// Lịch sử theo ngày: km, lít, km/L, ngày thiếu xăng, cắt 30 ngày, lưu JSON.
final class HistoryTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testKeyFormat() {
        XCTAssertEqual(DailyHistory.key(for: day(2026, 3, 5), calendar: cal), "2026-03-05")
        XCTAssertEqual(DailyHistory.key(daysAgo: 6, from: day(2026, 3, 5), calendar: cal), "2026-02-27")
    }

    func testRecordTracksStartAndEnd() {
        var h = DailyHistory()
        XCTAssertTrue(h.record(odoKm: 1000, fuelUsedL: 0.0, date: day(2026, 5, 1), calendar: cal))
        XCTAssertTrue(h.record(odoKm: 1012.4, fuelUsedL: 0.3, date: day(2026, 5, 1, hour: 18), calendar: cal))
        XCTAssertFalse(h.record(odoKm: 1012.4, fuelUsedL: 0.3, date: day(2026, 5, 1, hour: 19), calendar: cal))
        XCTAssertEqual(h.days.count, 1)
        let r = h.days[0]
        XCTAssertEqual(r.date, "2026-05-01")
        XCTAssertEqual(r.km, 12.4, accuracy: 1e-9)
        XCTAssertEqual(r.litres ?? -1, 0.3, accuracy: 1e-9)
    }

    func testNilOdoIgnored() {
        var h = DailyHistory()
        XCTAssertFalse(h.record(odoKm: nil, fuelUsedL: 1, date: day(2026, 5, 1), calendar: cal))
        XCTAssertTrue(h.isEmpty)
    }

    func testFuelCounterResetCarriesLitres() {
        var h = DailyHistory()
        _ = h.record(odoKm: 100, fuelUsedL: 0, date: day(2026, 5, 1), calendar: cal)
        _ = h.record(odoKm: 120, fuelUsedL: 0.5, date: day(2026, 5, 1, hour: 11), calendar: cal)
        // app chạy lại: bộ đếm về 0
        _ = h.record(odoKm: 121, fuelUsedL: 0, date: day(2026, 5, 1, hour: 14), calendar: cal)
        _ = h.record(odoKm: 140, fuelUsedL: 0.4, date: day(2026, 5, 1, hour: 16), calendar: cal)
        let r = h.days[0]
        XCTAssertEqual(r.km, 40, accuracy: 1e-9)
        XCTAssertEqual(r.litres ?? -1, 0.9, accuracy: 1e-9)
    }

    func testMissingFuelDayIsExcludedFromAverage() {
        var h = DailyHistory()
        let today = day(2026, 5, 10)
        // hôm nay: 40 km, 1 L (hợp lệ)
        _ = h.record(odoKm: 1000, fuelUsedL: 0, date: today, calendar: cal)
        _ = h.record(odoKm: 1040, fuelUsedL: 1, date: today, calendar: cal)
        // hôm qua: 100 km nhưng không có số xăng
        let y = day(2026, 5, 9)
        _ = h.record(odoKm: 900, fuelUsedL: nil, date: y, calendar: cal)
        _ = h.record(odoKm: 1000, fuelUsedL: nil, date: y, calendar: cal)
        // 3 ngày trước: 20 km, 0.5 L
        let t3 = day(2026, 5, 7)
        _ = h.record(odoKm: 800, fuelUsedL: 10, date: t3, calendar: cal)
        _ = h.record(odoKm: 820, fuelUsedL: 10.5, date: t3, calendar: cal)

        let s = h.summary(range: 7, today: today, calendar: cal)
        XCTAssertEqual(s.totalKm, 160, accuracy: 1e-9)
        XCTAssertEqual(s.validKm, 60, accuracy: 1e-9)
        XCTAssertEqual(s.litres, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.kmPerLitre ?? 0, 40, accuracy: 1e-9)      // 60 / 1,5, không phải trung bình cộng 40 và 40
        XCTAssertEqual(s.ranDays, 3)
        XCTAssertEqual(s.missingDays, 1)

        let rows = h.rows(range: 7, today: today, calendar: cal)
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[0].kind, .valid)
        XCTAssertEqual(rows[1].kind, .missingFuel)
        XCTAssertEqual(rows[2].kind, .none)
        XCTAssertNil(rows[1].kmPerLitre)
        XCTAssertEqual(rows[0].kmPerLitre ?? 0, 40, accuracy: 1e-9)
    }

    func testAverageIsTotalOverTotalNotMeanOfRatios() {
        var h = DailyHistory()
        let today = day(2026, 5, 10)
        // 10 km / 0.1 L = 100 km/L ; 90 km / 3 L = 30 km/L → tổng 100 km / 3,1 L = 32,26
        _ = h.record(odoKm: 0, fuelUsedL: 0, date: today, calendar: cal)
        _ = h.record(odoKm: 10, fuelUsedL: 0.1, date: today, calendar: cal)
        let y = day(2026, 5, 9)
        _ = h.record(odoKm: 10, fuelUsedL: 5, date: y, calendar: cal)
        _ = h.record(odoKm: 100, fuelUsedL: 8, date: y, calendar: cal)
        let s = h.summary(range: 7, today: today, calendar: cal)
        XCTAssertEqual(s.kmPerLitre ?? 0, 100 / 3.1, accuracy: 1e-9)
    }

    func testRangesAndEmpty() {
        var h = DailyHistory()
        let today = day(2026, 5, 31)
        XCTAssertNil(h.summary(range: 7, today: today, calendar: cal).kmPerLitre)
        XCTAssertEqual(h.summary(range: 30, today: today, calendar: cal).ranDays, 0)
        // một ngày cách 10 ngày: có trong 30, không có trong 7
        let old = day(2026, 5, 21)
        _ = h.record(odoKm: 500, fuelUsedL: 0, date: old, calendar: cal)
        _ = h.record(odoKm: 530, fuelUsedL: 1, date: old, calendar: cal)
        XCTAssertEqual(h.summary(range: 7, today: today, calendar: cal).totalKm, 0, accuracy: 1e-9)
        XCTAssertEqual(h.summary(range: 30, today: today, calendar: cal).totalKm, 30, accuracy: 1e-9)
    }

    func testPrunesTo30Days() {
        var h = DailyHistory()
        for i in 0..<40 {
            let d = cal.date(byAdding: .day, value: i, to: day(2026, 1, 1))!
            _ = h.record(odoKm: Double(i * 10), fuelUsedL: nil, date: d, calendar: cal)
        }
        XCTAssertEqual(h.days.count, DailyHistory.maxDays)
        XCTAssertEqual(h.days.first?.date, "2026-01-11")
        XCTAssertEqual(h.days.last?.date, "2026-02-09")
    }

    func testJSONRoundTripAndOldFormat() {
        var h = DailyHistory()
        _ = h.record(odoKm: 10, fuelUsedL: 1, date: day(2026, 5, 1), calendar: cal)
        _ = h.record(odoKm: 25, fuelUsedL: 1.5, date: day(2026, 5, 1), calendar: cal)
        let data = h.encoded()!
        XCTAssertEqual(DailyHistory.decode(data), h)
        // thiếu khoá fuelCarry / fuel vẫn đọc được
        let old = #"{"days":[{"date":"2026-05-02","odoStart":1,"odoEnd":3}]}"#.data(using: .utf8)!
        let d = DailyHistory.decode(old)
        XCTAssertEqual(d?.days.first?.km, 2)
        XCTAssertNil(d?.days.first?.litres)
    }

    func testCSV() {
        var h = DailyHistory()
        _ = h.record(odoKm: 10, fuelUsedL: 0, date: day(2026, 5, 1), calendar: cal)
        _ = h.record(odoKm: 40, fuelUsedL: 1, date: day(2026, 5, 1), calendar: cal)
        _ = h.record(odoKm: 40, fuelUsedL: nil, date: day(2026, 5, 2), calendar: cal)
        _ = h.record(odoKm: 50, fuelUsedL: nil, date: day(2026, 5, 2), calendar: cal)
        let lines = h.csv().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "date,odo_start,odo_end,km,litres,km_per_litre")
        XCTAssertEqual(lines[1], "2026-05-01,10.0,40.0,30.0,1.000,30.00")
        XCTAssertEqual(lines[2], "2026-05-02,40.0,50.0,10.0,,")
    }
}
