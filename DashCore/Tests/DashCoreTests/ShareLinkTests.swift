import XCTest
@testable import DashCore

/// Chạy mọi vector trong share-links.json qua phần phân tích offline (không gọi mạng).
final class ShareLinkTests: XCTestCase {
    private func load() throws -> [[String: Any]] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: nil))
        let data = try Data(contentsOf: dir.appendingPathComponent("share-links.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["vectors"] as? [[String: Any]])
    }

    private func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    /// So một điểm với {lat, lng} trong vector.
    private func check(_ p: GeoPoint?, _ e: [String: Any], _ id: String) {
        guard let lat = num(e["lat"]), let lng = num(e["lng"]) else { return XCTFail("\(id): vector thiếu lat/lng") }
        guard let p = p else { return XCTFail("\(id): không ra toạ độ") }
        XCTAssertEqual(p.lat, lat, accuracy: 1e-9, id)
        XCTAssertEqual(p.lon, lng, accuracy: 1e-9, id)
    }

    func testShareLinkVectors() throws {
        let vectors = try load()
        XCTAssertFalse(vectors.isEmpty)
        var kinds = Set<String>()
        for v in vectors {
            let id = v["id"] as! String
            let text = (v["input"] as! [String: Any])["text"] as! String
            let e = v["expect"] as! [String: Any]
            let kind = e["kind"] as! String
            kinds.insert(kind)
            let url = ShareLink.firstURL(in: text)
            let got = url.flatMap { ShareLink.parse(url: $0, sharedText: text) }

            switch kind {
            case "coords":
                XCTAssertFalse(url.map(ShareLink.isShortLink) ?? true, id)
                check(got?.point, e, id)
                XCTAssertNil(got?.searchText, id)
                XCTAssertEqual(got?.stops ?? [], [], id)
                XCTAssertEqual(got?.name, e["name"] as? String, id)
            case "query":
                let d = try XCTUnwrap(got, id)
                XCTAssertNil(d.point, id)
                XCTAssertEqual(d.searchText, e["q"] as? String, id)
            case "directions":
                let d = try XCTUnwrap(got, id)
                let dest = e["destination"] as! [String: Any]
                if let q = dest["q"] as? String {
                    XCTAssertNil(d.point, "\(id): không được lấy toạ độ của điểm đi")
                    XCTAssertEqual(d.searchText, q, id)
                } else {
                    check(d.point, dest, id)
                    XCTAssertNil(d.searchText, id)
                    if let name = dest["name"] as? String { XCTAssertEqual(d.name, name, id) }
                }
                let stops = e["stops"] as! [[String: Any]]
                XCTAssertEqual(d.stops.count, stops.count, id)
                for (p, s) in zip(d.stops, stops) { check(p, s, id) }
            case "redirect":
                // Bước redirect cần mạng; vector không cho URL đích nên kiểm tra phần offline:
                // tìm đúng URL, nhận ra link rút gọn, link rút gọn không tự phân tích được.
                let then = e["then"] as! String
                let u = try XCTUnwrap(url, id)
                XCTAssertTrue(then.hasPrefix("GET \(u.absoluteString) "), "\(id): URL sai \(u)")
                XCTAssertTrue(ShareLink.isShortLink(u), id)
                XCTAssertNil(got, id)
                // Tên lấy từ dòng đầu của text chia sẻ khi URL đích không có tên.
                let name = text.split(separator: "\n").first.map(String.init)
                let after = ShareLink.parse(url: URL(string: "https://maps.google.com/?q=10.5,106.5")!, sharedText: text)
                XCTAssertEqual(after?.name, name, id)
            case "none":
                XCTAssertNil(got, id)
            default:
                XCTFail("\(id): kind lạ \(kind)")
            }
        }
        XCTAssertEqual(kinds, ["coords", "query", "directions", "redirect", "none"])
    }

    func testFirstURLAndShortLinks() {
        XCTAssertNil(ShareLink.firstURL(in: "Chợ Bến Thành\nQuận 1"))
        XCTAssertTrue(ShareLink.isShortLink(URL(string: "https://goo.gl/maps/xyz")!))
        XCTAssertFalse(ShareLink.isShortLink(URL(string: "https://goo.gl/other")!))
    }
}
