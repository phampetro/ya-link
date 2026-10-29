import CoreGraphics
import DashCore
@testable import DashRender
import XCTest

/// Bản đồ vector: một ô giả tự dựng (luôn chạy) và ô thật tải từ OpenFreeMap (bỏ qua nếu không có mạng).
/// Ảnh chụp lưu cùng thư mục snapshots với SnapshotTests, tên "16-map-*" (ô giả) và "17-map-live-*" (ô thật).
/// Mặc định bản đồ nghiêng 3D (mapTilt) bật, như app.
final class MapTests: XCTestCase {
    static let center = MapPoint(lat: 10.7769, lon: 106.7009)           // Q.1, TP.HCM
    static let route: [MapPoint] = [
        MapPoint(lat: 10.7769, lon: 106.7009), MapPoint(lat: 10.7779, lon: 106.7009), MapPoint(lat: 10.7789, lon: 106.7009),
        MapPoint(lat: 10.7789, lon: 106.7030), MapPoint(lat: 10.7789, lon: 106.7060), MapPoint(lat: 10.7789, lon: 106.7100),
    ]

    private func ui(zoom: Int, tilt: Bool = true) -> DashUI {
        let ui = DashUI()
        ui.mapTilt = tilt
        ui.homeBarText = "ODO 3.214 km"
        ui.vehicle = VehicleInfo(coolantC: 92, batteryV: 12.8)
        ui.nav = NavInfo(maneuver: .right, distanceToTurnM: 250, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                         destination: "Chợ Bến Thành", remainingKm: 7, eta: Date(timeIntervalSince1970: 1_761_641_000),
                         speedLimit: 60)
        _ = ui.press(.down, now: 0)
        _ = ui.press(.down, now: 0.15)
        _ = ui.tick(now: 0.7)                     // chốt bấm đúp: sang trang Bản đồ (hiện ngay)
        var t = 2.0
        let steps = zoom - DashUI.defaultZoom
        for _ in 0..<abs(steps) {
            _ = ui.press(steps > 0 ? .up : .down, now: t)
            t += 0.6
            _ = ui.tick(now: t)                   // chốt bấm đơn: thu phóng
        }
        return ui
    }

    /// Tên đường dọc tuyến thử: đi bắc trên "Nguyễn Huệ", rẽ đông sang "Lê Thánh Tôn".
    static let spans = [StreetSpan(start: 0, end: 2, name: "Nguyễn Huệ"), StreetSpan(start: 2, end: 5, name: "Lê Thánh Tôn")]

    /// `route: []` là không dẫn đường (bản đồ chỉ có xe, nhãn đường quanh xe).
    @discardableResult
    private func render(_ name: String, store: TileStore, zoom: Int, tilt: Bool = true,
                        maxKB: Double = 25, save: Bool = true, route: [MapPoint] = MapTests.route,
                        spans: [StreetSpan] = []) throws -> CGImage {
        var input = DashRenderer.Input()
        input.date = Date(timeIntervalSince1970: 1_761_640_000)
        input.map = MapScene(center: Self.center, headingDeg: 0, route: route, passedIndex: 0,
                             destination: route.last, store: store, streetSpans: spans)
        let image = try XCTUnwrap(DashRenderer().render(ui(zoom: zoom, tilt: tilt), now: 10, input: input), name)
        let jpg = ImageEncoder.jpeg(image, quality: 0.5)
        if save {
            try Data(ImageEncoder.png(image)).write(to: SnapshotTests.out.appendingPathComponent("\(name).png"))
            try Data(jpg).write(to: SnapshotTests.out.appendingPathComponent("\(name).jpg"))
        }
        let kb = Double(jpg.count) / 1024
        print(String(format: "SNAPSHOT %-26@ JPEG %5.1f KB", name as NSString, kb))
        XCTAssertLessThan(kb, maxKB, name)
        return image
    }

    private func pixels(_ image: CGImage, x: Range<Int>, y: Range<Int>) -> [UInt8] {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return [] }
        let bpp = image.bitsPerPixel / 8
        var out: [UInt8] = []
        for yy in y {
            for xx in x {
                let o = yy * image.bytesPerRow + xx * bpp
                for k in 0..<3 { out.append(ptr[o + k]) }
            }
        }
        return out
    }

    private func whole(_ image: CGImage) -> [UInt8] { pixels(image, x: 0..<480, y: 0..<234) }

    /// Ô giả tại (14, 13048, 7698): đường chính, đường nhỏ, nước, công viên, nhà, và lớp `transportation_name`
    /// (6 đường có tên đi qua vùng nhìn thấy quanh xe). Các ô lân cận để trống (không tải mạng, ảnh không đổi giữa hai lần vẽ).
    /// `withNames: false` bỏ lớp tên đường (để so sánh có/không có nhãn).
    static func fakeStore(withNames: Bool = true, cross: Bool = false, only: Set<String>? = nil) -> TileStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-tiles-\(UUID().uuidString)")
        let store = TileStore(cacheDirectory: dir, session: URLSession(configuration: .ephemeral))
        func line(_ cls: String, _ pts: [(Int, Int)], name: String? = nil) -> MVTFeature {
            var p: [String: MVTValue] = ["class": .string(cls)]
            if let n = name { p["name"] = .string(n) }
            return MVTFeature(kind: .line, properties: p, geometry: [pts.map { MVTPoint(x: $0.0, y: $0.1) }])
        }
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ props: [String: MVTValue] = [:]) -> MVTFeature {
            MVTFeature(kind: .polygon, properties: props,
                       geometry: [[MVTPoint(x: x, y: y), MVTPoint(x: x + w, y: y), MVTPoint(x: x + w, y: y + h),
                                   MVTPoint(x: x, y: y + h), MVTPoint(x: x, y: y)]])
        }
        var named: [MVTFeature] = [
            line("primary", [(327, 0), (327, 4096)], name: "Nguyễn Huệ"),
            line("primary", [(0, 2457), (4096, 2457)], name: "Lê Lợi"),
            line("secondary", [(0, 1700), (4096, 1900)], name: "Pasteur"),
            line("secondary", [(700, 0), (700, 4096)], name: "Nam Kỳ Khởi Nghĩa"),
            line("tertiary", [(1500, 0), (1500, 4096)], name: "Hai Bà Trưng"),
            line("minor", [(0, 2900), (4096, 2900)], name: "Hẻm 12"),
        ]
        if cross {
            // Phố cụt gặp tuyến thử: một bên trái đoạn đi bắc (cách xe 107 m), một phố đi lên bắc từ đoạn đi đông (bên trái)
            named.append(line("secondary", [(313, 2330), (0, 2330)], name: "Tôn Đản"))
            named.append(line("secondary", [(500, 2133), (500, 1500)], name: "Mạc Đĩnh Chi"))
        }
        if let keep = only { named = named.filter { keep.contains($0.properties["name"]?.stringValue ?? "") } }
        var roads: [MVTFeature] = named
        for k in stride(from: 0, to: 4096, by: 260) {
            roads.append(line("minor", [(k, 0), (k, 4096)]))
            roads.append(line("minor", [(0, k + 120), (4096, k + 120)]))
        }
        var buildings: [MVTFeature] = []
        for gx in stride(from: 40, to: 3000, by: 260) { for gy in stride(from: 2500, to: 3400, by: 260) { buildings.append(rect(gx, gy, 180, 180)) } }
        var layers: [String: MVTLayer] = [
            "transportation": MVTLayer(name: "transportation", features: roads),
            "water": MVTLayer(name: "water", features: [rect(0, 3600, 4096, 496)]),
            "park": MVTLayer(name: "park", features: [rect(800, 1000, 700, 500)]),
            "building": MVTLayer(name: "building", features: buildings),
        ]
        if withNames { layers["transportation_name"] = MVTLayer(name: "transportation_name", features: named) }
        let tile = MVTTile(layers: layers)
        for dy in -2...2 { for dx in -2...2 { store.insertForTesting(MVTTile(), z: 14, x: 13048 + dx, y: 7698 + dy) } }
        store.insertForTesting(tile, z: 14, x: 13048, y: 7698)
        return store
    }

    func testFakeTileAllZooms() throws {
        let store = Self.fakeStore()
        for zoom in 0..<DashUI.zoomScales.count {
            try render("16-map-fake-z\(zoom)", store: store, zoom: zoom)
        }
    }

    /// Phẳng và nghiêng ở zoom 3, 4 và 5.
    func testTiltedVersusFlatSnapshots() throws {
        let store = Self.fakeStore()
        let flat3 = try render("16-map-flat-z3", store: store, zoom: 3, tilt: false)
        let tilt3 = try render("16-map-tilt-z3", store: store, zoom: 3)
        XCTAssertNotEqual(whole(flat3), whole(tilt3), "bản đồ nghiêng phải khác bản đồ phẳng")
        try render("16-map-flat-z4", store: store, zoom: 4, tilt: false)
        let tilt4 = try render("16-map-tilt-z4", store: store, zoom: 4)
        let tilt5 = try render("16-map-tilt-z5", store: store, zoom: 5)
        // Phần bản đồ (trên thanh dưới) của ảnh nghiêng ở zoom 4 và 5 phải khác nhau
        XCTAssertNotEqual(pixels(tilt4, x: 0..<480, y: 0..<186), pixels(tilt5, x: 0..<480, y: 0..<186))

        // Mũi tên vị trí còn nguyên, nằm trên thanh dưới (y < 186), cả khi phẳng lẫn nghiêng
        for image in [flat3, tilt3, tilt4, tilt5] {
            let p = pixels(image, x: 238..<239, y: 157..<158)
            XCTAssertTrue(p.count == 3 && p.allSatisfy { $0 > 225 }, "mũi tên bị che")
        }
    }

    /// Tên đường phải hiện khi KHÔNG dẫn đường (route rỗng; khi nghiêng lẫn khi phẳng): cùng cảnh có và không có lớp
    /// `transportation_name` phải khác nhau ở vùng nhìn thấy, và ảnh có nhãn vẫn nhỏ gọn, mũi tên còn nguyên.
    func testStreetLabelsAppearWhenTilted() throws {
        for zoom in [3, 4, 5] {
            let withNames = try render("16-map-labels-tilt-z\(zoom)", store: Self.fakeStore(), zoom: zoom, route: [])
            let without = try render("tmp", store: Self.fakeStore(withNames: false), zoom: zoom, save: false, route: [])
            XCTAssertNotEqual(pixels(withNames, x: 50..<430, y: 66..<180), pixels(without, x: 50..<430, y: 66..<180),
                              "zoom \(zoom): nghiêng phải có tên đường")
            let p = pixels(withNames, x: 238..<239, y: 157..<158)
            XCTAssertTrue(p.count == 3 && p.allSatisfy { $0 > 225 }, "mũi tên bị che")
            let flatNames = try render("tmp", store: Self.fakeStore(), zoom: zoom, tilt: false, save: false, route: [])
            let flatNone = try render("tmp", store: Self.fakeStore(withNames: false), zoom: zoom, tilt: false, save: false, route: [])
            XCTAssertNotEqual(pixels(flatNames, x: 50..<430, y: 14..<180), pixels(flatNone, x: 50..<430, y: 14..<180),
                              "zoom \(zoom): bản đồ phẳng phải có tên đường")
        }
        // Dưới zoom 2 chưa có tên đường
        let low = try render("tmp", store: Self.fakeStore(), zoom: 1, save: false, route: [])
        let lowNone = try render("tmp", store: Self.fakeStore(withNames: false), zoom: 1, save: false, route: [])
        XCTAssertEqual(whole(low), whole(lowNone))
    }

    // MARK: - Dẫn đường: tên đường phía trước

    /// Đang dẫn đường: nhãn "Tên · khoảng cách" hiện ở cả bên trái và bên phải tuyến (so ảnh có/không có tên đường),
    /// không có chữ nào nằm trên nét tuyến, mũi tên còn nguyên, ảnh vẫn nhỏ gọn.
    func testAheadLabelsAppearLeftAndRightOfRoute() throws {
        for zoom in [1, 2, 3] {
            let withNames = try render("16-map-ahead-tilt-z\(zoom)", store: Self.fakeStore(cross: true), zoom: zoom,
                                       spans: Self.spans)
            let without = try render("tmp", store: Self.fakeStore(withNames: false, cross: true), zoom: zoom, save: false,
                                     spans: Self.spans)
            // Tuyến đi bắc thẳng đứng ở x = 238 (đoạn dưới góc rẽ); nhãn nằm hai bên, mép nhãn cách nét tuyến >= ~10 px
            XCTAssertNotEqual(pixels(withNames, x: 20..<220, y: 66..<182), pixels(without, x: 20..<220, y: 66..<182),
                              "zoom \(zoom): thiếu nhãn bên trái tuyến")
            XCTAssertNotEqual(pixels(withNames, x: 256..<470, y: 66..<182), pixels(without, x: 256..<470, y: 66..<182),
                              "zoom \(zoom): thiếu nhãn bên phải tuyến")
            // Dải giữa nét tuyến (x 236–240), ngay phía trên mũi tên: giống hệt khi có và không có nhãn
            XCTAssertEqual(pixels(withNames, x: 236..<241, y: 136..<143), pixels(without, x: 236..<241, y: 136..<143),
                           "zoom \(zoom): có chữ đè lên nét tuyến")
            let p = pixels(withNames, x: 238..<239, y: 157..<158)
            XCTAssertTrue(p.count == 3 && p.allSatisfy { $0 > 225 }, "mũi tên bị che")
            // Phẳng cũng vậy
            let flat = try render("tmp", store: Self.fakeStore(cross: true), zoom: zoom, tilt: false, save: false, spans: Self.spans)
            let flatNone = try render("tmp", store: Self.fakeStore(withNames: false, cross: true), zoom: zoom, tilt: false,
                                      save: false, spans: Self.spans)
            XCTAssertNotEqual(whole(flat), whole(flatNone), "zoom \(zoom): bản đồ phẳng phải có nhãn đường phía trước")
            XCTAssertEqual(pixels(flat, x: 236..<241, y: 136..<143), pixels(flatNone, x: 236..<241, y: 136..<143),
                           "zoom \(zoom): phẳng, có chữ đè lên nét tuyến")
        }
    }

    /// Đang dẫn đường thì không còn tên đường quanh xe: với tên đường không cắt tuyến (Pasteur, Hẻm 12) ảnh có và không có
    /// lớp tên phải giống hệt nhau, ở mọi mức zoom (cả zoom 3–5 là nơi trước đây hiện nhãn quanh xe).
    func testGenericStreetLabelsGoneWhileNavigating() throws {
        for zoom in 0...5 {
            let a = try render("tmp", store: Self.fakeStore(only: ["Pasteur", "Hẻm 12"]), zoom: zoom, save: false,
                               spans: Self.spans)
            let b = try render("tmp", store: Self.fakeStore(withNames: false, only: ["Pasteur", "Hẻm 12"]), zoom: zoom,
                               save: false, spans: Self.spans)
            XCTAssertEqual(whole(a), whole(b), "zoom \(zoom): còn nhãn đường quanh xe khi dẫn đường")
        }
    }

    /// Zoom 0 (xa nhất) được phép bỏ nhãn, nhưng không được lỗi hay phình ảnh.
    func testAheadLabelsAtWidestZoomStayCompact() throws {
        try render("16-map-ahead-tilt-z0", store: Self.fakeStore(cross: true), zoom: 0, spans: Self.spans)
    }

    /// Phép chiếu phối cảnh và nhãn phải đủ nhanh để gửi liên tục cho đồng hồ.
    func testTiltedRenderIsFast() throws {
        let store = Self.fakeStore()
        var input = DashRenderer.Input()
        input.map = MapScene(center: Self.center, headingDeg: 20, route: Self.route, passedIndex: 0,
                             destination: Self.route.last, store: store)
        for zoom in [3, 4, 5] {
            let u = ui(zoom: zoom)
            _ = DashRenderer().render(u, now: 10, input: input)           // khởi động (font, cache)
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 { _ = DashRenderer().render(u, now: 10, input: input) }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) / 5 * 1000
            print(String(format: "RENDER tilt zoom %d: %.1f ms/frame", zoom, ms))
            XCTAssertLessThan(ms, 250, "zoom \(zoom): vẽ quá chậm")
        }
    }

    func testClippingBehindCamera() {
        let line = [GP(u: 0, d: -300), GP(u: 60, d: 0), GP(u: 60, d: 100)]
        let pieces = MapRenderer.clipLine(line, near: -120)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(pieces[0].allSatisfy { $0.d >= -120 - 1e-9 })
        XCTAssertEqual(pieces[0].first?.d ?? 0, -120, accuracy: 1e-9)
        XCTAssertEqual(MapRenderer.clipLine([GP(u: 0, d: -500), GP(u: 5, d: -200)], near: -120).count, 0)

        let square = [GP(u: -50, d: -200), GP(u: 50, d: -200), GP(u: 50, d: 50), GP(u: -50, d: 50)]
        let clipped = MapRenderer.clipPolygon(square, near: -120)
        XCTAssertEqual(clipped.count, 4)
        XCTAssertTrue(clipped.allSatisfy { $0.d >= -120 - 1e-9 })
        XCTAssertEqual(MapRenderer.clipPolygon(square, near: -1000).count, 4)
    }

    func testPerspectiveKeepsScaleAtArrowAndShrinksAhead() {
        let scene = MapScene(center: Self.center, headingDeg: 0, route: [], passedIndex: 0, destination: nil,
                             store: Self.fakeStore())
        let v = MapRenderer.makeView(scene, zoomIndex: 3, tilt: true)
        let o = v.project(GP(u: 0, d: 0))
        XCTAssertEqual(o.x, 238, accuracy: 1e-9)
        XCTAssertEqual(o.y, 160, accuracy: 1e-9)
        XCTAssertEqual(v.scale(0), 1, accuracy: 1e-9)
        XCTAssertLessThan(v.scale(200), 1)
        XCTAssertLessThan(v.project(GP(u: 0, d: 100)).y, 160)               // phía trước nằm cao hơn
        let wNear = v.project(GP(u: 50, d: 50)).x - v.project(GP(u: 0, d: 50)).x
        let wFar = v.project(GP(u: 50, d: 400)).x - v.project(GP(u: 0, d: 400)).x
        XCTAssertLessThan(wFar, wNear)                                      // xa thì hẹp lại
        let flat = MapRenderer.makeView(scene, zoomIndex: 3, tilt: false)
        let f = flat.project(GP(u: 30, d: 40))
        XCTAssertEqual(f.x, 268, accuracy: 1e-9)
        XCTAssertEqual(f.y, 120, accuracy: 1e-9)
    }

    func testRotatedHeadingKeepsDirectionUp() throws {
        let store = Self.fakeStore()
        var input = DashRenderer.Input()
        input.map = MapScene(center: Self.center, headingDeg: 90, route: Self.route, passedIndex: 0,
                             destination: Self.route.last, store: store)
        let image = try XCTUnwrap(DashRenderer().render(ui(zoom: 3), now: 10, input: input))
        try Data(ImageEncoder.png(image)).write(to: SnapshotTests.out.appendingPathComponent("16-map-fake-heading90.png"))
    }

    /// Tải ô thật từ OpenFreeMap (kiểm chứng bộ giải mã MVT trên dữ liệu thật). Không có mạng thì bỏ qua.
    func testLiveTiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-tiles-\(UUID().uuidString)")
        let store = TileStore(cacheDirectory: dir)
        let loaded = expectation(description: "ô trung tâm")
        loaded.assertForOverFulfill = false
        store.onTileLoaded = {
            if store.tile(z: 14, x: 13048, y: 7698) != nil { loaded.fulfill() }
        }
        store.prefetch(around: Self.center, z: 14, radius: 1)
        _ = store.tile(z: 14, x: 13048, y: 7698)
        if XCTWaiter.wait(for: [loaded], timeout: 40) != .completed {
            throw XCTSkip("Không tải được ô bản đồ từ OpenFreeMap (không có mạng?)")
        }
        let tile = try XCTUnwrap(store.tile(z: 14, x: 13048, y: 7698))
        let counts = tile.layers.map { "\($0.key)=\($0.value.features.count)" }.sorted().joined(separator: " ")
        print("LIVE-TILE layers: \(counts)")
        XCTAssertNotNil(tile.layers["transportation"], "ô thật phải có lớp đường")
        XCTAssertGreaterThan(tile.layers["transportation"]?.features.count ?? 0, 50)
        XCTAssertNotNil(tile.layers["building"], "ô thật phải có lớp nhà")
        Thread.sleep(forTimeInterval: 4)    // chờ các ô lân cận
        for zoom in [0, 2, 3, 4, 5] {
            try render("17-map-live-z\(zoom)", store: store, zoom: zoom, maxKB: 40)
        }
        try render("17-map-live-flat-z3", store: store, zoom: 3, tilt: false, maxKB: 40)
    }
}
