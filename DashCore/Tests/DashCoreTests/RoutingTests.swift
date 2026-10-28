import XCTest
@testable import DashCore

/// Polyline, đọc JSON Valhalla (route, trace_attributes) và Google Routes v2.
final class RoutingTests: XCTestCase {
    private let pts = [
        GeoPoint(lat: 10.77689, lon: 106.70092),
        GeoPoint(lat: 10.77701, lon: 106.70150),
        GeoPoint(lat: 10.77750, lon: 106.70210),
        GeoPoint(lat: 10.77812, lon: 106.70188),
        GeoPoint(lat: 10.77900, lon: 106.70100),
    ]

    private func json(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o) }

    private func assertPoints(_ a: [GeoPoint], _ b: [GeoPoint], _ acc: Double, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, line: line)
        for (p, q) in zip(a, b) {
            XCTAssertEqual(p.lat, q.lat, accuracy: acc, line: line)
            XCTAssertEqual(p.lon, q.lon, accuracy: acc, line: line)
        }
    }

    func testGoogleDocumentedExample() {
        let d = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        assertPoints(d, [GeoPoint(lat: 38.5, lon: -120.2), GeoPoint(lat: 40.7, lon: -120.95),
                         GeoPoint(lat: 43.252, lon: -126.453)], 1e-9)
        XCTAssertEqual(Polyline.encode(d, precision: 5), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    }

    func testRoundTripPrecision6() {
        let p = pts + [GeoPoint(lat: -33.865143, lon: 151.2099), GeoPoint(lat: 0, lon: 0)]
        assertPoints(Polyline.decode(Polyline.encode(p, precision: 6), precision: 6), p, 1e-7)
        XCTAssertTrue(Polyline.decode("", precision: 6).isEmpty)
    }

    func testValhallaManeuverMapping() {
        XCTAssertEqual(Valhalla.maneuver(type: 10), .right)
        XCTAssertEqual(Valhalla.maneuver(type: 15), .left)
        XCTAssertEqual(Valhalla.maneuver(type: 13), .uturn)
        XCTAssertEqual(Valhalla.maneuver(type: 26), .roundabout)
        XCTAssertEqual(Valhalla.maneuver(type: 8), .straight)
    }

    func testParseValhallaRoute() throws {
        let m: [[String: Any]] = [
            ["type": 1, "street_names": ["Lê Lợi"], "length": 0.5, "begin_shape_index": 0],
            ["type": 10, "street_names": ["Nguyễn Huệ"], "length": 0.3, "begin_shape_index": 2],
            ["type": 15, "length": 0.4, "begin_shape_index": 3],
            ["type": 4, "length": 0.0, "begin_shape_index": 4],
        ]
        let o: [String: Any] = ["trip": [
            "legs": [["shape": Polyline.encode(pts, precision: 6), "maneuvers": m] as [String: Any]],
            "summary": ["length": 1.2, "time": 300],
        ] as [String: Any]]
        let r = try Valhalla.parseRoute(json(o))
        XCTAssertEqual(r.source, .valhalla)
        assertPoints(r.points, pts, 1e-7)
        XCTAssertEqual(r.steps.map(\.maneuver), [.straight, .right, .left, .straight])
        XCTAssertEqual(r.steps.map(\.street), ["Lê Lợi", "Nguyễn Huệ", "", ""])
        XCTAssertEqual(r.steps.map(\.startIndex), [0, 2, 3, 4])
        XCTAssertEqual(r.steps[1].distanceM, 300, accuracy: 1e-6)
        XCTAssertEqual(r.totalM, 1200, accuracy: 1e-6)
        XCTAssertEqual(r.durationS, 300, accuracy: 1e-9)
    }

    func testParseGoogle() throws {
        func step(_ dist: Int, _ man: String, _ text: String, _ p: [GeoPoint]) -> [String: Any] {
            ["distanceMeters": dist,
             "navigationInstruction": ["maneuver": man, "instructions": text],
             "polyline": ["encodedPolyline": Polyline.encode(p, precision: 5)]]
        }
        let steps = [
            step(400, "DEPART", "Đi về hướng đông", Array(pts[0...2])),
            step(300, "TURN_RIGHT", "Rẽ phải vào Đường Lê Lợi\nĐi qua nhà hàng", Array(pts[2...3])),
            step(200, "UTURN_LEFT", "Quay đầu", Array(pts[3...4])),
        ]
        let o: [String: Any] = ["routes": [[
            "distanceMeters": 900, "duration": "180s",
            "polyline": ["encodedPolyline": Polyline.encode(pts, precision: 5)],
            "legs": [["steps": steps]],
        ] as [String: Any]]]
        let r = try GoogleRoutes.parse(json(o))
        XCTAssertEqual(r.source, .google)
        assertPoints(r.points, pts, 1e-6)
        XCTAssertEqual(r.steps.map(\.maneuver), [.straight, .right, .uturn])
        XCTAssertEqual(r.steps.map(\.street), ["", "Đường Lê Lợi", ""])
        XCTAssertEqual(r.steps.map(\.startIndex), [0, 2, 3])
        XCTAssertEqual(r.steps.map(\.distanceM), [400, 300, 200])
        XCTAssertEqual(r.totalM, 900)
        XCTAssertEqual(r.durationS, 180)
        XCTAssertEqual(GoogleRoutes.maneuver("ROUNDABOUT_LEFT"), .roundabout)
        XCTAssertEqual(GoogleRoutes.maneuver("TURN_SHARP_LEFT"), .left)
        XCTAssertEqual(GoogleRoutes.street(from: "Turn right onto Main St"), "Main St")
    }

    func testParseTraceEdges() throws {
        let edges: [[String: Any]] = [
            ["speed_limit": 50, "length": 0.2, "begin_shape_index": 0, "end_shape_index": 2],
            ["speed_limit": 50, "length": 0.1, "begin_shape_index": 2, "end_shape_index": 3],
            ["length": 0.1, "begin_shape_index": 3, "end_shape_index": 4],
            ["speed_limit": 40, "length": 0.3, "begin_shape_index": 4, "end_shape_index": 6],
        ]
        let t = try Valhalla.parseTrace(json(["edges": edges]))
        XCTAssertEqual(t.matchedLengthKm, 0.7, accuracy: 1e-9)
        XCTAssertEqual(t.limits, [SpeedLimitSpan(start: 0, end: 3, kmh: 50), SpeedLimitSpan(start: 4, end: 6, kmh: 40)])
    }

    func testParseTraceMatchedPoints() throws {
        let o: [String: Any] = [
            "edges": [["speed_limit": 50, "length": 0.2], ["speed_limit": 60, "length": 0.3]],
            "matched_points": [["edge_index": 0], ["edge_index": 0], ["edge_index": 1], ["edge_index": 1]],
        ]
        let t = try Valhalla.parseTrace(json(o))
        XCTAssertEqual(t.matchedLengthKm, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.limits, [SpeedLimitSpan(start: 0, end: 1, kmh: 50), SpeedLimitSpan(start: 2, end: 3, kmh: 60)])
    }

    func testRequestBodies() throws {
        let v = try JSONSerialization.jsonObject(with: Valhalla.routeRequestBody(from: pts[0], to: pts[4], via: [pts[2]])) as? [String: Any]
        XCTAssertEqual(v?["costing"] as? String, "motor_scooter")
        XCTAssertEqual((v?["locations"] as? [Any])?.count, 3)
        let g = try JSONSerialization.jsonObject(with: GoogleRoutes.requestBody(from: pts[0], to: pts[4])) as? [String: Any]
        XCTAssertEqual(g?["travelMode"] as? String, "TWO_WHEELER")
        XCTAssertNil(g?["intermediates"])
    }
}
