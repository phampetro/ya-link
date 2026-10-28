import XCTest
@testable import DashCore

/// Các kiểu link chia sẻ của Google / Apple Maps ngoài share-links.json (vẫn theo routing-options.md).
final class ShareLinkFormatsTests: XCTestCase {
    private func parse(_ s: String, text: String? = nil) -> SharedDestination? {
        ShareLink.parse(url: URL(string: s)!, sharedText: text)
    }

    private func assertPoint(_ d: SharedDestination?, _ lat: Double, _ lon: Double, line: UInt = #line) {
        guard let p = d?.point else { return XCTFail("không ra toạ độ", line: line) }
        XCTAssertEqual(p.lat, lat, accuracy: 1e-9, line: line)
        XCTAssertEqual(p.lon, lon, accuracy: 1e-9, line: line)
        XCTAssertNil(d?.searchText, line: line)
    }

    func testPlaceDataCoordsBeatViewport() {
        // Link thật sau khi mở link rút gọn: viewport @ khác chỗ thật; !3d!4d là địa điểm.
        let d = parse("https://www.google.com/maps/place/Ch%E1%BB%A3+B%E1%BA%BFn+Th%C3%A0nh/@10.7725,106.6980,17z/data=!3m1!4b1!4m6!3m5!1s0x31752f:0xabc!8m2!3d10.772456!4d106.698012!16s%2Fm%2F0bd3k?entry=ttu")
        assertPoint(d, 10.772456, 106.698012)
        XCTAssertEqual(d?.name, "Chợ Bến Thành")
    }

    func testPlaceWithMultipleDataCoordsTakesLast() {
        let d = parse("https://www.google.com/maps/place/X/@10.0,106.0,17z/data=!4m5!3m4!1s0x1:0x2!8m2!3d10.5!4d106.5!3d10.7!4d106.7")
        assertPoint(d, 10.7, 106.7)
    }

    func testPlaceNameIsCoordinates() {
        assertPoint(parse("https://www.google.com/maps/place/10.7725,106.6980"), 10.7725, 106.698)
        assertPoint(parse("https://www.google.com/maps/place/10.7725,106.6980/@10.77,106.69,17z"), 10.7725, 106.698)
        assertPoint(parse("https://www.google.com/maps/search/10.7725,106.6980"), 10.7725, 106.698)
        XCTAssertNil(parse("https://www.google.com/maps/place/10.7725,106.6980")?.name)
    }

    func testSearchPathTextIsSearchedNotViewport() {
        let d = parse("https://www.google.com/maps/search/Highlands+Coffee/@10.77,106.69,15z")
        XCTAssertNil(d?.point)
        XCTAssertEqual(d?.searchText, "Highlands Coffee")
    }

    func testQueryCoordinateForms() {
        assertPoint(parse("https://www.google.com/maps?q=10.7769,106.7009"), 10.7769, 106.7009)
        assertPoint(parse("https://maps.google.com/maps?ll=10.7769,106.7009&z=15"), 10.7769, 106.7009)
        assertPoint(parse("https://maps.google.com/?q=loc:10.7769,106.7009"), 10.7769, 106.7009)
        assertPoint(parse("https://maps.google.com/?q=-33.8568,151.2153"), -33.8568, 151.2153)
        assertPoint(parse("https://www.google.com/maps/dir/?api=1&destination=10.7769,106.7009"), 10.7769, 106.7009)
        assertPoint(parse("https://www.google.com/maps/dir?api=1&destination=10.7769%2C106.7009"), 10.7769, 106.7009)
        assertPoint(parse("https://maps.google.com/maps?daddr=10.7769,106.7009&saddr=10.7,106.6"), 10.7769, 106.7009)
    }

    func testDirApiWithTextDestinationIsSearch() {
        let d = parse("https://www.google.com/maps/dir/?api=1&destination=Ch%E1%BB%A3+B%E1%BA%BFn+Th%C3%A0nh")
        XCTAssertNil(d?.point)
        XCTAssertEqual(d?.searchText, "Chợ Bến Thành")
    }

    func testDirectionsTrailingSlash() {
        // Dấu / cuối đường dẫn không được biến thành điểm đến rỗng.
        let d = parse("https://www.google.com/maps/dir/Landmark+81/Ch%E1%BB%A3+L%E1%BB%9Bn/")
        XCTAssertEqual(d?.searchText, "Chợ Lớn")
        assertPoint(parse("https://www.google.com/maps/dir/10.7,106.6/10.8,106.7/"), 10.8, 106.7)
    }

    func testDirectionsDataCoordsOrderLngThenLat() {
        // data: mỗi điểm một khối `!1m5…!2m2!1d<lng>!2d<lat>`; điểm cuối = đến, điểm giữa = dừng.
        let d = parse("https://www.google.com/maps/dir/A/B/C/@10.77,106.68,13z/data=!4m14!4m13!1m5!1m1!1s0x1:0x2!2m2!1d106.60!2d10.70!1m5!1m1!1s0x3:0x4!2m2!1d106.7!2d10.8!1m5!1m1!1s0x5:0x6!2m2!1d106.65!2d10.75!3e9")
        assertPoint(d, 10.75, 106.65)
        XCTAssertEqual(d?.stops.count, 1)
        XCTAssertEqual(d?.stops.first?.lat ?? 0, 10.8, accuracy: 1e-9)
        XCTAssertEqual(d?.stops.first?.lon ?? 0, 106.7, accuracy: 1e-9)
    }

    func testAppleMaps() {
        let d = parse("https://maps.apple.com/place?coordinate=10.7725,106.6980&name=Ch%E1%BB%A3%20B%E1%BA%BFn%20Th%C3%A0nh")
        assertPoint(d, 10.7725, 106.698)
        XCTAssertEqual(d?.name, "Chợ Bến Thành")
    }

    func testRejects() {
        XCTAssertNil(parse("https://www.google.com/maps/@91.0,106.0,15z"))
        XCTAssertNil(parse("https://maps.google.com/?q=10.5,200.5"))
        XCTAssertNil(parse("https://example.com/maps/place/x/@10,106,15z"))
        XCTAssertNil(parse("https://www.google.com/search?q=10.5,106.5"))
    }

    func testShortLinkAndConsentUnwrap() {
        for u in ["https://maps.app.goo.gl/AbC123", "https://goo.gl/maps/AbC123", "https://MAPS.APP.GOO.GL/x?g_st=ic"] {
            XCTAssertTrue(ShareLink.isShortLink(URL(string: u)!), u)
        }
        let consent = URL(string: "https://consent.google.com/ml?continue=https://www.google.com/maps/place/X/@10,106,15z&gl=VN")!
        XCTAssertEqual(ShareLink.consentTarget(consent)?.host, "www.google.com")
        XCTAssertNil(ShareLink.consentTarget(URL(string: "https://www.google.com/maps")!))
    }

    func testShareSheetTextWithNameAddressAndShortLink() {
        let text = "Phố đi bộ Nguyễn Huệ\nNguyễn Huệ, Bến Nghé, Quận 1\nhttps://maps.app.goo.gl/AbC123?g_st=ic"
        XCTAssertEqual(ShareLink.firstURL(in: text)?.absoluteString, "https://maps.app.goo.gl/AbC123?g_st=ic")
        XCTAssertEqual(ShareLink.firstURL(in: "Xem https://maps.app.goo.gl/AbC123.")?.absoluteString,
                       "https://maps.app.goo.gl/AbC123")
    }
}
