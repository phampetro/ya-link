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

    private func shot(_ name: String, _ ui: DashUI, now: TimeInterval, photo: CGImage? = SnapshotTests.samplePhoto,
                      maxKB: Double = 20) throws {
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
        if let d = distance {
            ui.nav = NavInfo(maneuver: .right, distanceToTurnM: d, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                             destination: "Chợ Bến Thành", remainingKm: 7, eta: Date(timeIntervalSince1970: 1_761_641_000),
                             speedLimit: 60)
        }
        return ui
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
    }

    func testMusic() throws {
        let ui = filled()
        _ = ui.press(.up, now: 0)
        try shot("07-music", ui, now: 10)
        _ = ui.press(.enterHold, now: 10)
        _ = ui.press(.up, now: 10.1)
        try shot("08-music-volume", ui, now: 10.2)
        let none = DashUI()
        _ = none.press(.up, now: 0)
        try shot("09-music-empty", none, now: 10)
    }

    func testWheelMidRotation() throws {
        let ui = filled()
        _ = ui.press(.down, now: 0)
        try shot("10-wheel-rotating", ui, now: 0.2)
    }

    func testMap() throws {
        let ui = filled()
        _ = ui.press(.down, now: 0)
        try shot("11-map-cover", ui, now: 10)
        try shot("12-map-cover-no-nav", filledMapCover(), now: 10)
        _ = ui.press(.enter, now: 10)
        try shot("13-map-open", ui, now: 11)
        _ = ui.press(.down, now: 12); _ = ui.press(.down, now: 12.1); _ = ui.press(.down, now: 12.2)
        try shot("14-map-zoom-out", ui, now: 13)
        ui.nav?.distanceToTurnM = 300
        _ = ui.press(.up, now: 14); _ = ui.press(.up, now: 14.1); _ = ui.press(.up, now: 14.2); _ = ui.press(.up, now: 14.3)
        try shot("15-map-zoom-in-warn", ui, now: 15)
    }

    private func filledMapCover() -> DashUI {
        let ui = filled(nav: nil)
        _ = ui.press(.down, now: 0)
        return ui
    }
}
