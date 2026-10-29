import XCTest
@testable import DashCore

/// Tên đường phía trước khi chỉ đường: hình học giả (mét phẳng quanh gốc 10°N, 106°E).
final class AheadStreetsTests: XCTestCase {
    private let lat0 = 10.0
    private let lon0 = 106.0

    private func pt(_ x: Double, _ y: Double) -> GeoPoint {
        GeoPoint(lat: lat0 + y / 111_194.93, lon: lon0 + x / (111_194.93 * cos(lat0 * .pi / 180)))
    }

    private func road(_ name: String, _ pts: [(Double, Double)], tier: Int = 1) -> AheadRoad {
        AheadRoad(name: name, points: pts.map { pt($0.0, $0.1) }, tier: tier)
    }

    /// Tuyến đi thẳng hướng bắc dọc x = 0, từ y = 0 tới 1000, mỗi 100 m một điểm.
    private var north: [GeoPoint] { (0...10).map { pt(0, Double($0) * 100) } }

    private let mainSpans = [StreetSpan(start: 0, end: 4, name: "Main"), StreetSpan(start: 5, end: 10, name: "Next Rd")]

    private func roads() -> [AheadRoad] {
        [
            road("Left A", [(-100, 200), (0, 200)]),
            road("Left A", [(-100, 250), (0, 250)]),          // trùng tên, xa hơn: phải bị bỏ
            road("Left B", [(-120, 350), (0, 350)]),
            road("Left C", [(-100, 520), (0, 520)]),          // thứ 3 bên trái: vượt mức 2
            road("Right A", [(0, 150), (120, 150)]),
            road("Right B", [(0, 420), (100, 420)]),
            road("Right C", [(0, 560), (100, 560)]),          // thứ 3 bên phải: vượt mức 2
            road("Main", [(-100, 300), (100, 300)]),          // tên đường đang đi
            road("Shallow", [(-5, 600 - 150), (5, 600 + 150)]),   // cắt rất nhọn (~2°): song song
            road("Overlap", [(-3, 100), (3, 200), (-3, 300), (3, 400), (-3, 500)]),
            road("Service Lane", [(-100, 480), (0, 480)], tier: 3),
            road("", [(-100, 130), (0, 130)]),                // không tên
        ]
    }

    func testFullSetOfFiveLabelsInOrder() {
        let out = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: mainSpans, roads: roads())
        XCTAssertEqual(out.count, 5, "tối đa 5 nhãn")
        XCTAssertEqual(out.map { $0.name }, ["Next Rd", "Right A", "Left A", "Left B", "Right B"])
        XCTAssertEqual(out.map { $0.side }, [.straight, .right, .left, .left, .right])
        let expected = [500.0, 150, 200, 350, 420]
        for (l, d) in zip(out, expected) { XCTAssertEqual(l.distanceM, d, accuracy: 1.5, l.name) }
        // Nhãn đi thẳng: neo ở điểm tuyến bắt đầu đoạn đường mới
        XCTAssertEqual(out[0].anchor.lat, pt(0, 500).lat, accuracy: 1e-6)
        // Giao lộ nằm trên tuyến (x ≈ 0)
        XCTAssertEqual(out[2].anchor.lon, pt(0, 0).lon, accuracy: 2e-6)
        XCTAssertTrue([1, 2].contains(out[2].routeIndex), "giao lộ y = 200 nằm ở chỗ nối đoạn 1 và 2")
    }

    func testNearestFirstAndMaxTwoPerSide() {
        let own = [StreetSpan(start: 0, end: 10, name: "Main")]
        let out = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: own, roads: roads())
        XCTAssertEqual(out.filter { $0.side == .left }.map { $0.name }, ["Left A", "Left B"])
        XCTAssertEqual(out.filter { $0.side == .right }.map { $0.name }, ["Right A", "Right B"])
        XCTAssertEqual(out.filter { $0.side == .straight }.count, 0, "tên đường không đổi: không có nhãn đi thẳng")
        XCTAssertFalse(out.contains { $0.name == "Left C" || $0.name == "Right C" })
    }

    func testExcludesOwnStreetParallelServiceAndUnnamed() {
        let out = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: mainSpans, roads: roads())
        for banned in ["Main", "Shallow", "Overlap", "Service Lane", ""] {
            XCTAssertFalse(out.contains { $0.name == banned }, "không được có '\(banned)'")
        }
    }

    func testDeduplicatesByNameKeepingNearest() {
        let out = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: [], roads: roads())
        let a = out.filter { $0.name == "Left A" }
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].distanceM, 200, accuracy: 1.5)
    }

    func testSideIsRelativeToDirectionOfTravel() {
        // Tuyến đi hướng đông: phía bắc là bên trái, phía nam là bên phải
        let east = (0...10).map { pt(Double($0) * 100, 0) }
        let rs = [road("North St", [(200, 0), (200, 100)]), road("South St", [(400, -100), (400, 0)])]
        let out = AheadStreets.compute(route: east, passedIndex: 0, car: pt(0, 0), streetSpans: [], roads: rs)
        XCTAssertEqual(out.map { $0.name }, ["North St", "South St"])
        XCTAssertEqual(out.map { $0.side }, [.left, .right])
        XCTAssertEqual(out[0].distanceM, 200, accuracy: 1.5)
        XCTAssertEqual(out[1].distanceM, 400, accuracy: 1.5)
    }

    func testTeeJunctionSlightlyShortOfRouteStillCounts() {
        // Đường chữ T kết thúc cách tuyến 3 m (lệch hình học): vẫn bắt được nhờ kéo dài đầu đường
        let rs = [road("Short T", [(-90, 300), (-3, 300)])]
        let out = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: [], roads: rs)
        XCTAssertEqual(out.map { $0.name }, ["Short T"])
        XCTAssertEqual(out.first?.side, .left)
    }

    func testStraightAheadOnlyWhenNameChanges() {
        let same = [StreetSpan(start: 0, end: 10, name: "Main")]
        XCTAssertNil(AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: same, roads: [])
            .first { $0.side == .straight })
        let changed = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: mainSpans, roads: [])
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].name, "Next Rd")
        XCTAssertEqual(changed[0].side, .straight)
        XCTAssertEqual(changed[0].distanceM, 500, accuracy: 1.5)
        // Đã sang đoạn "Next Rd": không còn đổi tên phía trước
        XCTAssertTrue(AheadStreets.compute(route: north, passedIndex: 6, car: pt(0, 600), streetSpans: mainSpans, roads: []).isEmpty)
        // Tên giống tên đang đi (đoạn bị chia đôi) thì bỏ qua, lấy tên khác kế tiếp
        let split = [StreetSpan(start: 0, end: 2, name: "Main"), StreetSpan(start: 3, end: 5, name: "Main"),
                      StreetSpan(start: 6, end: 10, name: "Far Rd")]
        let far = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: split, roads: [])
        XCTAssertEqual(far.first?.name, "Far Rd")
        XCTAssertEqual(far.first?.distanceM ?? 0, 600, accuracy: 1.5)
    }

    func testDistancesStartFromCarNotFromRouteIndex() {
        // Xe đã đi 30 m trên đoạn đầu: giao lộ ở y = 200 cách 170 m
        let out = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 30), streetSpans: mainSpans, roads: roads())
        let a = out.first { $0.name == "Left A" }
        XCTAssertEqual(a?.distanceM ?? 0, 170, accuracy: 1.5)
        XCTAssertEqual(out.first { $0.side == .straight }?.distanceM ?? 0, 470, accuracy: 1.5)
    }

    func testCrossingsAlreadyPassedAreIgnored() {
        // Xe ở y = 350 (đoạn 3): Left A, Right A và Left B (ngay tại xe) đã qua
        let out = AheadStreets.compute(route: north, passedIndex: 3, car: pt(0, 350), streetSpans: mainSpans, roads: roads())
        XCTAssertFalse(out.contains { ["Left A", "Right A", "Left B"].contains($0.name) })
        XCTAssertEqual(out.first { $0.name == "Right B" }?.distanceM ?? 0, 70, accuracy: 1.5)
        XCTAssertEqual(out.first { $0.name == "Left C" }?.distanceM ?? 0, 170, accuracy: 1.5)
    }

    func testLookAheadWindowLimitsCrossings() {
        let out = AheadStreets.compute(route: north, passedIndex: 0, car: pt(0, 0), streetSpans: [], roads: roads(), lookAheadM: 200)
        XCTAssertFalse(out.contains { $0.name == "Left B" || $0.name == "Right B" })
    }

    func testDegenerateInputs() {
        XCTAssertTrue(AheadStreets.compute(route: [], passedIndex: 0, streetSpans: [], roads: roads()).isEmpty)
        XCTAssertTrue(AheadStreets.compute(route: [pt(0, 0)], passedIndex: 0, streetSpans: [], roads: roads()).isEmpty)
        // passedIndex ngoài phạm vi: kẹp lại, không văng lỗi
        _ = AheadStreets.compute(route: north, passedIndex: 99, car: nil, streetSpans: mainSpans, roads: roads())
        _ = AheadStreets.compute(route: north, passedIndex: -5, car: nil, streetSpans: mainSpans, roads: roads())
    }

    func testDistanceTextUsesTurnCardRounding() {
        let a = pt(0, 0)
        XCTAssertEqual(AheadLabel(name: "x", side: .left, distanceM: 150, anchor: a, routeIndex: 0).distanceText, "150 m")
        XCTAssertEqual(AheadLabel(name: "x", side: .left, distanceM: 43, anchor: a, routeIndex: 0).distanceText, "40 m")
        XCTAssertEqual(AheadLabel(name: "x", side: .left, distanceM: 1230, anchor: a, routeIndex: 0).distanceText, "1,2 km")
    }
}
