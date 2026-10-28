import CoreGraphics
import DashCore
@testable import DashRender
import XCTest

/// Vẽ từng màn hình ra PNG (để xem) và JPEG (để đo dung lượng gửi lên đồng hồ), lưu ở DashCore/snapshots/.
/// GitHub Actions tải thư mục này lên thành artifact "snapshots".
final class SnapshotTests: XCTestCase {
    static let out: URL = {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var report: [String] = []

    @discardableResult
    private func shot(_ name: String, _ ui: DashUI, now: TimeInterval, photo: CGImage? = SnapshotTests.samplePhoto,
                      maxKB: Double = 20) throws -> CGImage {
        var input = DashRenderer.Input()
        input.photo = photo
        input.date = Date(timeIntervalSince1970: 1_761_640_000)   // 15:26 giờ VN
        let image = try XCTUnwrap(DashRenderer().render(ui, now: now, input: input), name)
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 234)
        let png = ImageEncoder.png(image), jpg = ImageEncoder.jpeg(image, quality: 0.5)
        try Data(png).write(to: Self.out.appendingPathComponent("\(name).png"))
        try Data(jpg).write(to: Self.out.appendingPathComponent("\(name).jpg"))
        let kb = Double(jpg.count) / 1024
        print(String(format: "SNAPSHOT %-22@ JPEG %5.1f KB", name as NSString, kb))
        XCTAssertLessThan(kb, maxKB, "\(name): khung quá nặng cho đồng hồ")
        return image
    }

    /// Điểm ảnh RGB của một vùng (để so sánh vùng an toàn giữa hai khung).
    private func region(_ image: CGImage, x: Range<Int>, y: Range<Int>) -> [UInt8] {
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

    /// Ảnh nền mẫu: hoàng hôn trên đèo, màu phẳng (như bg-sample.svg).
    static let samplePhoto: CGImage? = {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: 480, height: 234, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: 234); c.scaleBy(x: 1, y: -1)
        func fill(_ rgb: (Double, Double, Double), _ pts: [CGPoint]) {
            c.setFillColor(CGColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1))
            c.addLines(between: pts); c.closePath(); c.fillPath()
        }
        fill((243, 166, 90), [CGPoint(x: 0, y: 0), CGPoint(x: 480, y: 0), CGPoint(x: 480, y: 234), CGPoint(x: 0, y: 234)])
        fill((233, 136, 90), [CGPoint(x: 0, y: 0), CGPoint(x: 480, y: 0), CGPoint(x: 480, y: 60), CGPoint(x: 0, y: 60)])
        c.setFillColor(CGColor(srgbRed: 1, green: 0.82, blue: 0.48, alpha: 1))
        c.fillEllipse(in: CGRect(x: 296, y: 84, width: 68, height: 68))
        fill((122, 74, 107), [CGPoint(x: 0, y: 140), CGPoint(x: 70, y: 96), CGPoint(x: 130, y: 128), CGPoint(x: 200, y: 82),
                              CGPoint(x: 270, y: 124), CGPoint(x: 340, y: 100), CGPoint(x: 410, y: 132), CGPoint(x: 480, y: 104),
                              CGPoint(x: 480, y: 234), CGPoint(x: 0, y: 234)])
        fill((78, 50, 86), [CGPoint(x: 0, y: 170), CGPoint(x: 90, y: 132), CGPoint(x: 170, y: 160), CGPoint(x: 250, y: 126),
                            CGPoint(x: 330, y: 158), CGPoint(x: 420, y: 136), CGPoint(x: 480, y: 152), CGPoint(x: 480, y: 234),
                            CGPoint(x: 0, y: 234)])
        fill((44, 31, 58), [CGPoint(x: 0, y: 200), CGPoint(x: 120, y: 170), CGPoint(x: 240, y: 192), CGPoint(x: 360, y: 166),
                            CGPoint(x: 480, y: 186), CGPoint(x: 480, y: 234), CGPoint(x: 0, y: 234)])
        return c.makeImage()
    }()

    private func filled(nav distance: Double? = 250) -> DashUI {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        ui.vehicle = VehicleInfo(coolantC: 92, batteryV: 12.8)
        ui.weather = WeatherInfo(tempC: 31, kind: .sun, label: "Nắng nhẹ", place: "Q.1")
        ui.music = MusicInfo(title: "Nơi này có anh", artist: "Sơn Tùng M-TP", duration: 260, position: 112, playing: true)
        ui.userName = "Trọng"
        ui.places = SavedPlaces(
            home: SavedPlace(name: "Nhà", sub: "Quận 7", lat: 10.73, lon: 106.72),
            work: SavedPlace(name: "Công ty", sub: "Bitexco, Q.1", lat: 10.77, lon: 106.70),
            favs: [SavedPlace(name: "Cà phê Bờ Hồ", sub: "Q.1", lat: 10.78, lon: 106.69),
                   SavedPlace(name: "Sân vận động Thống Nhất", sub: "Q.10", lat: 10.76, lon: 106.66)])
        if let d = distance {
            ui.nav = NavInfo(maneuver: .right, distanceToTurnM: d, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                             destination: "Chợ Bến Thành", remainingKm: 7, eta: Date(timeIntervalSince1970: 1_761_641_000),
                             speedLimit: 60)
        }
        return ui
    }

    /// Bấm `times` lần cách nhau 0,15 s từ `at` rồi chốt (tick) sau cửa sổ chờ. Trả về thời điểm sau khi chốt.
    @discardableResult
    private func tap(_ ui: DashUI, _ button: DashUI.Button, times: Int = 1, at: TimeInterval) -> TimeInterval {
        var t = at
        for _ in 0..<times {
            _ = ui.press(button, now: t)
            t += 0.15
        }
        t += DashUI.doublePressWindow + 0.1
        _ = ui.tick(now: t)
        return t
    }

    func testHome() throws {
        try shot("01-home", filled(), now: 100)
        try shot("02-home-no-nav", filled(nav: nil), now: 100)
        let warn = filled(nav: 60)
        warn.vehicle = VehicleInfo(coolantC: 112, batteryV: 11.9)
        warn.weather = WeatherInfo(tempC: 27, kind: .storm, label: "Dông", place: "Phường Bến Thành, Quận 1")
        try shot("03-home-warnings", warn, now: 100)
        let empty = DashUI()
        try shot("04-home-no-data", empty, now: 100, photo: nil)
    }

    func testWelcome() throws {
        let ui = filled()
        ui.showWelcome(now: 0)
        try shot("05-welcome", ui, now: 1)
        try shot("06-welcome-entry", ui, now: 2.5)
        try shot("06b-welcome-fade-out", ui, now: 2.25)
        let anonymous = filled()
        anonymous.userName = ""
        anonymous.vehicle = VehicleInfo()
        anonymous.showWelcome(now: 0)
        try shot("06c-welcome-no-name", anonymous, now: 1)
        let skipped = filled()
        skipped.greetingEnabled = false
        skipped.showWelcome(now: 0)
        try shot("06d-greeting-off-entry", skipped, now: 0.9)
    }

    func testMusic() throws {
        let ui = filled()
        tap(ui, .up, times: 2, at: 0)             // đúp UP: bánh xe sang Nhạc
        XCTAssertEqual(ui.page, .music)
        try shot("07-music", ui, now: 10)
        tap(ui, .up, times: 3, at: 10)            // ba lần UP: chế độ âm lượng
        XCTAssertTrue(ui.volumeMode)
        _ = ui.press(.up, now: 11.1)
        try shot("08-music-volume", ui, now: 11.2)
        let none = DashUI()
        tap(none, .up, times: 2, at: 0)
        try shot("09-music-empty", none, now: 10)
    }

    func testWheelMidRotation() throws {
        let ui = filled()
        _ = ui.press(.down, now: 0)
        _ = ui.press(.down, now: 0.15)
        _ = ui.tick(now: 0.6)                       // chốt bấm đúp: bánh xe bắt đầu xoay
        try shot("10-wheel-rotating", ui, now: 0.8)
    }

    func testMap() throws {
        let ui = filled()
        tap(ui, .down, times: 2, at: 0)
        XCTAssertEqual(ui.page, .map)
        try shot("11-map-open", ui, now: 10)
        var t = 12.0
        for _ in 0..<3 { t = tap(ui, .down, at: t) }
        try shot("14-map-zoom-out", ui, now: t)
        ui.nav?.distanceToTurnM = 300
        for _ in 0..<4 { t = tap(ui, .up, at: t) }
        try shot("15-map-zoom-in-warn", ui, now: t)
    }

    func testMapIdleArrowOnly() throws {
        let ui = filled(nav: nil)
        tap(ui, .down, times: 2, at: 0)
        try shot("16-map-idle-arrow", ui, now: 10)
        XCTAssertEqual(ui.bottomBarText(now: 10), "Chia sẻ vị trí từ Google Maps")
    }

    func testMapLeavesByDoubleUp() throws {
        let ui = filled()
        tap(ui, .down, times: 2, at: 0)
        let map = try shot("17-map-navigating", ui, now: 20)
        tap(ui, .up, times: 2, at: 20)
        XCTAssertEqual(ui.page, .home)
        let home = try shot("17b-home-after-map", ui, now: 22)
        XCTAssertNotEqual(region(map, x: 0..<480, y: 0..<186), region(home, x: 0..<480, y: 0..<186))
    }

    func testMapMenu() throws {
        let ui = filled()
        tap(ui, .down, times: 2, at: 0)
        let plain = try shot("17c-map-before-menu", ui, now: 20)
        tap(ui, .down, times: 3, at: 20)                   // ba lần: mở menu
        XCTAssertNotNil(ui.menu)
        let menu = try shot("18-map-menu", ui, now: 22)
        // Vùng an toàn: nút ＋/－ (x < 56) và thanh dưới (y ≥ 186) giống hệt khi không có menu
        XCTAssertEqual(region(menu, x: 0..<70, y: 68..<170), region(plain, x: 0..<70, y: 68..<170), "menu đè lên nút ＋/－")
        XCTAssertEqual(region(menu, x: 0..<480, y: 186..<234), region(plain, x: 0..<480, y: 186..<234), "menu đè lên thanh dưới")
        XCTAssertNotEqual(region(menu, x: 74..<406, y: 14..<170), region(plain, x: 74..<406, y: 14..<170), "menu phải hiện")

        var t = 22.0
        t = tap(ui, .up, at: t)                            // xoay vòng tới "Yêu thích"
        t = tap(ui, .up, times: 2, at: t)                  // đúp: mở danh sách yêu thích
        XCTAssertEqual(ui.menu?.level, .favorites)
        try shot("19-map-menu-favourites", ui, now: t)

        let long = filled()
        long.places.favs += [SavedPlace(name: "Bệnh viện Chợ Rẫy", sub: "Q.5", lat: 10.75, lon: 106.66),
                             SavedPlace(name: "Chợ Bến Thành", sub: "Q.1", lat: 10.77, lon: 106.69)]
        var u = 0.0
        u = tap(long, .down, times: 2, at: u)
        u = tap(long, .down, times: 3, at: u)
        u = tap(long, .up, at: u)
        u = tap(long, .up, times: 2, at: u)
        XCTAssertEqual(long.menu?.level, .favorites)
        for _ in 0..<3 { u = tap(long, .down, at: u) }     // dòng cuối: danh sách cuộn
        try shot("20-map-menu-scrolled", long, now: u)

        let idle = filled(nav: nil)
        var w = tap(idle, .down, times: 2, at: 0)
        w = tap(idle, .down, times: 3, at: w)
        XCTAssertNotNil(idle.menu)
        try shot("21-map-menu-no-nav", idle, now: w)
    }

    func testArrival() throws {
        let ui = filled(nav: 20)
        ui.startNavigation(ui.nav!, now: 0)
        ui.arrive(now: 10)
        try shot("22-arrival", ui, now: 11)
    }
}
