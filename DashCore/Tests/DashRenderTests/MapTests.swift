import CoreGraphics
import DashCore
@testable import DashRender
import XCTest

/// Bản đồ vector: một ô giả tự dựng (luôn chạy) và ô thật tải từ OpenFreeMap (bỏ qua nếu không có mạng).
/// Ảnh chụp lưu cùng thư mục snapshots với SnapshotTests, tên "16-map-fake-*" và "17-map-live-*".
final class MapTests: XCTestCase {
    static let center = MapPoint(lat: 10.7769, lon: 106.7009)           // Q.1, TP.HCM
    static let route: [MapPoint] = [
        MapPoint(lat: 10.7769, lon: 106.7009), MapPoint(lat: 10.7779, lon: 106.7009), MapPoint(lat: 10.7789, lon: 106.7009),
        MapPoint(lat: 10.7789, lon: 106.7030), MapPoint(lat: 10.7789, lon: 106.7060), MapPoint(lat: 10.7789, lon: 106.7100),
    ]

    private func ui(zoom: Int) -> DashUI {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        ui.vehicle = VehicleInfo(coolantC: 92, batteryV: 12.8)
        ui.nav = NavInfo(maneuver: .right, distanceToTurnM: 250, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                         destination: "Chợ Bến Thành", remainingKm: 7, eta: Date(timeIntervalSince1970: 1_761_641_000),
                         speedLimit: 60)
        _ = ui.press(.down, now: 0)
        _ = ui.press(.enter, now: 1)
        var t = 2.0
        let steps = zoom - DashUI.defaultZoom
        for _ in 0..<abs(steps) { _ = ui.press(steps > 0 ? .up : .down, now: t); t += 0.1 }
        return ui
    }

    private func render(_ name: String, store: TileStore, zoom: Int, maxKB: Double = 25) throws {
        var input = DashRenderer.Input()
        input.date = Date(timeIntervalSince1970: 1_761_640_000)
        input.map = MapScene(center: Self.center, headingDeg: 0, route: Self.route, passedIndex: 0,
                             destination: Self.route.last, store: store)
        let image = try XCTUnwrap(DashRenderer().render(ui(zoom: zoom), now: 10, input: input), name)
        try Data(ImageEncoder.png(image)).write(to: SnapshotTests.out.appendingPathComponent("\(name).png"))
        let jpg = ImageEncoder.jpeg(image, quality: 0.5)
        try Data(jpg).write(to: SnapshotTests.out.appendingPathComponent("\(name).jpg"))
        let kb = Double(jpg.count) / 1024
        print(String(format: "SNAPSHOT %-22@ JPEG %5.1f KB", name as NSString, kb))
        XCTAssertLessThan(kb, maxKB, name)
    }

    /// Ô giả tại (14, 13048, 7698): đường chính, đường nhỏ, nước, công viên, nhà.
    private func fakeStore() -> TileStore {
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
        var roads: [MVTFeature] = [
            line("primary", [(327, 0), (327, 4096)], name: "Nguyễn Huệ"),
            line("primary", [(0, 2457), (4096, 2457)], name: "Lê Lợi"),
            line("secondary", [(0, 1700), (4096, 1900)], name: "Pasteur"),
        ]
        for k in stride(from: 0, to: 4096, by: 260) {
            roads.append(line("minor", [(k, 0), (k, 4096)]))
            roads.append(line("minor", [(0, k + 120), (4096, k + 120)]))
        }
        var buildings: [MVTFeature] = []
        for gx in stride(from: 40, to: 3000, by: 260) { for gy in stride(from: 2500, to: 3400, by: 260) { buildings.append(rect(gx, gy, 180, 180)) } }
        let tile = MVTTile(layers: [
            "transportation": MVTLayer(name: "transportation", features: roads),
            "water": MVTLayer(name: "water", features: [rect(0, 3600, 4096, 496)]),
            "park": MVTLayer(name: "park", features: [rect(800, 1000, 700, 500)]),
            "building": MVTLayer(name: "building", features: buildings),
        ])
        store.insertForTesting(tile, z: 14, x: 13048, y: 7698)
        return store
    }

    func testFakeTileAllZooms() throws {
        let store = fakeStore()
        for zoom in 0..<DashUI.zoomScales.count {
            try render("16-map-fake-z\(zoom)", store: store, zoom: zoom)
        }
    }

    func testRotatedHeadingKeepsDirectionUp() throws {
        let store = fakeStore()
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
        Thread.sleep(forTimeInterval: 4)    // chờ các ô lân cận
        for zoom in [0, 2, 3, 4, 5] {
            try render("17-map-live-z\(zoom)", store: store, zoom: zoom, maxKB: 40)
        }
    }
}
