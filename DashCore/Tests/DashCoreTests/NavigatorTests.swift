import XCTest
@testable import DashCore

/// Tuyến chữ L tổng hợp gần TP.HCM: đi bắc 300 m rồi rẽ phải đi đông 300 m (điểm cách nhau 50 m).
final class NavigatorTests: XCTestCase {
    let lat0 = 10.7769, lon0 = 106.7009
    let k = 111_194.93
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// x: mét về phía đông, y: mét về phía bắc tính từ gốc.
    func pt(_ x: Double, _ y: Double) -> GeoPoint {
        GeoPoint(lat: lat0 + y / k, lon: lon0 + x / (k * cos(lat0 * .pi / 180)))
    }

    func makeRoute() -> Route {
        var pts: [GeoPoint] = []
        for i in 0...6 { pts.append(pt(0, Double(i) * 50)) }      // 0..6, góc ở index 6
        for i in 1...6 { pts.append(pt(Double(i) * 50, 300)) }    // 7..12
        let steps = [
            RouteStep(maneuver: .straight, street: "Nguyễn Huệ", distanceM: 300, startIndex: 0),
            RouteStep(maneuver: .right, street: "Lê Lợi", distanceM: 300, startIndex: 6),
        ]
        let spans = [SpeedLimitSpan(start: 0, end: 6, kmh: 40), SpeedLimitSpan(start: 6, end: 12, kmh: 60)]
        return Route(points: pts, steps: steps, totalM: 600, durationS: 120, speedLimits: spans, source: .valhalla)
    }

    func testDistanceToTurnDecreasesAndManeuverRight() {
        let nav = Navigator(route: makeRoute(), destinationName: "Nhà")
        let a = nav.update(pt(0, 50), at: t0, speedMps: nil).info
        let b = nav.update(pt(0, 200), at: t0.addingTimeInterval(10), speedMps: 10).info
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertEqual(a!.distanceToTurnM, 250, accuracy: 3)
        XCTAssertEqual(b!.distanceToTurnM, 100, accuracy: 3)
        XCTAssertLessThan(b!.distanceToTurnM, a!.distanceToTurnM)
        XCTAssertEqual(a!.maneuver, .right)
        XCTAssertEqual(a!.nextStreet, "Lê Lợi")
        XCTAssertEqual(a!.currentStreet, "Nguyễn Huệ")
        XCTAssertEqual(a!.remainingKm, 0.55, accuracy: 0.005)
        XCTAssertEqual(a!.destination, "Nhà")
        XCTAssertGreaterThan(a!.eta, t0)
        // Sau khi rẽ: đang ở đường Lê Lợi, không còn bước rẽ nào nữa.
        let c = nav.update(pt(100, 300), at: t0.addingTimeInterval(30), speedMps: 10).info!
        XCTAssertEqual(c.currentStreet, "Lê Lợi")
        XCTAssertEqual(c.remainingKm, 0.2, accuracy: 0.005)
    }

    func testOffRouteAfterFiveSecondsAndThrottled() {
        let nav = Navigator(route: makeRoute(), destinationName: "Nhà")
        XCTAssertFalse(nav.update(pt(0, 100), at: t0, speedMps: 8).needsReroute)
        let off = pt(-100, 100)
        func at(_ s: Double) -> NavUpdate { nav.update(off, at: t0.addingTimeInterval(s), speedMps: 8) }
        let u1 = at(1)
        XCTAssertFalse(u1.needsReroute)
        XCTAssertEqual(u1.offRouteM, 100, accuracy: 3)
        XCTAssertFalse(at(4).needsReroute)
        XCTAssertTrue(at(6).needsReroute)     // lệch từ giây 1 → đủ 5 s
        XCTAssertFalse(at(7).needsReroute)
        XCTAssertFalse(at(15).needsReroute)   // mới 9 s kể từ lần trước
        XCTAssertTrue(at(16.5).needsReroute)
        // Quay lại tuyến thì hết lệch.
        let back = nav.update(pt(0, 150), at: t0.addingTimeInterval(17), speedMps: 8)
        XCTAssertFalse(back.needsReroute)
        XCTAssertLessThan(back.offRouteM, 5)
    }

    func testArrivalNearEnd() {
        let nav = Navigator(route: makeRoute(), destinationName: "Nhà")
        XCTAssertFalse(nav.update(pt(200, 300), at: t0, speedMps: 8).arrived)
        let u = nav.update(pt(285, 305), at: t0.addingTimeInterval(12), speedMps: 5)
        XCTAssertTrue(u.arrived)
        XCTAssertFalse(u.needsReroute)
    }

    func testSpeedLimitSpans() {
        let nav = Navigator(route: makeRoute(), destinationName: "Nhà")
        XCTAssertEqual(nav.update(pt(0, 120), at: t0, speedMps: nil).info?.speedLimit, 40)
        XCTAssertEqual(nav.update(pt(120, 300), at: t0.addingTimeInterval(20), speedMps: nil).info?.speedLimit, 60)
    }

    func testReplaceRouteResetsMatching() {
        let nav = Navigator(route: makeRoute(), destinationName: "Nhà")
        _ = nav.update(pt(200, 300), at: t0, speedMps: nil)
        nav.replaceRoute(makeRoute())
        let u = nav.update(pt(0, 60), at: t0.addingTimeInterval(1), speedMps: nil)
        XCTAssertEqual(u.passedIndex, 1)
        XCTAssertEqual(u.info!.distanceToTurnM, 240, accuracy: 3)
    }
}
