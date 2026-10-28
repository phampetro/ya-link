import XCTest
@testable import DashCore

/// Luật nút bấm và chữ thanh dưới, đúng như mockup đã chốt.
final class DashUITests: XCTestCase {
    func testWheelCyclesPages() {
        let ui = DashUI()
        XCTAssertEqual(ui.page, .home)
        _ = ui.press(.down, now: 0)
        XCTAssertEqual(ui.page, .map)
        _ = ui.press(.down, now: 1)
        XCTAssertEqual(ui.page, .music, "xoay vòng: Bản đồ ↓ Nhạc")
        _ = ui.press(.up, now: 2)              // trang Nhạc: chờ 0,4 s xem có đúp không
        XCTAssertEqual(ui.page, .music)
        _ = ui.tick(now: 2.5)
        XCTAssertEqual(ui.page, .map, "Nhạc ↑ (xoay vòng) Bản đồ")
    }

    func testMusicDoublePress() {
        let ui = musicPage()
        XCTAssertEqual(ui.press(.up, now: 10), [])
        XCTAssertEqual(ui.press(.up, now: 10.2), [.nextTrack])
        XCTAssertEqual(ui.tick(now: 11), [])
        XCTAssertEqual(ui.page, .music, "bấm đúp không đổi trang")
        _ = ui.press(.down, now: 12)
        XCTAssertEqual(ui.press(.down, now: 12.3), [.previousTrack])
        _ = ui.press(.down, now: 13)
        _ = ui.tick(now: 13.5)
        XCTAssertEqual(ui.page, .home, "bấm đơn DOWN sau 0,4 s mới đổi trang (Nhạc ↓ Home)")
    }

    func testEnterAndVolume() {
        let ui = musicPage()
        XCTAssertEqual(ui.press(.enter, now: 10), [.togglePlay])
        _ = ui.press(.enterHold, now: 11)
        XCTAssertTrue(ui.volumeMode)
        XCTAssertEqual(ui.press(.up, now: 11.5), [.volume(10)])
        XCTAssertEqual(ui.press(.down, now: 11.6), [.volume(-10)])
        XCTAssertEqual(ui.volume, 60)
        XCTAssertEqual(ui.press(.enter, now: 12), [], "Enter khi đang chỉnh âm lượng: đóng, không phát/dừng")
        XCTAssertFalse(ui.volumeMode)
        _ = ui.press(.enterHold, now: 20)
        _ = ui.tick(now: 23.1)
        XCTAssertFalse(ui.volumeMode, "tự đóng sau 3 s")
    }

    func testHomeEnterChangesPhoto() {
        let ui = DashUI()
        XCTAssertEqual(ui.press(.enter, now: 0), [.nextPhoto])
    }

    func testMapOpenZoomAndHomeTwice() {
        let ui = DashUI()
        _ = ui.press(.down, now: 0)
        XCTAssertEqual(ui.page, .map)
        XCTAssertFalse(ui.mapOpen, "chưa Enter thì chỉ màn bìa")
        _ = ui.press(.enter, now: 1)
        XCTAssertTrue(ui.mapOpen)
        _ = ui.press(.up, now: 2)
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom + 1, "+ phóng to")
        _ = ui.press(.down, now: 2.1)
        _ = ui.press(.down, now: 2.2)
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom - 1)
        XCTAssertEqual(ui.page, .map, "khi mở bản đồ +/- không xoay menu")
        _ = ui.press(.home, now: 3)
        XCTAssertFalse(ui.mapOpen)
        XCTAssertEqual(ui.page, .map, "Home lần 1: về màn bìa")
        _ = ui.press(.home, now: 4)
        XCTAssertEqual(ui.page, .home, "Home lần 2: về trang chủ")
    }

    func testHomeFromMusic() {
        let ui = musicPage()
        _ = ui.press(.home, now: 10)
        XCTAssertEqual(ui.page, .home)
    }

    func testWelcomeBlocksButtonsAndSetsBar() {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        ui.showWelcome(now: 0)
        XCTAssertEqual(ui.bottomBarText(now: 1), "Chúc thượng lộ bình an")
        XCTAssertEqual(ui.press(.enter, now: 1), [])
        XCTAssertEqual(ui.bottomBarText(now: 2.5), "ODO 3.214 km")
    }

    func testBottomBarTexts() {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        ui.nav = nav(distance: 300)
        XCTAssertEqual(ui.bottomBarText(now: 0), "ODO 3.214 km")
        ui.nav = nav(distance: 60)
        XCTAssertEqual(ui.bottomBarText(now: 0), "Rẽ phải vào Lê Lợi", "dưới 100 m nhắc rẽ ở mọi trang")
        _ = ui.press(.down, now: 0)
        _ = ui.press(.enter, now: 1)
        XCTAssertEqual(ui.bottomBarText(now: 1.5), "+/- thu phóng · Home để thoát", "bản đồ mở: không nhắc rẽ")
        XCTAssertEqual(ui.bottomBarText(now: 5), "Nguyễn Huệ")
        _ = ui.press(.up, now: 6)
        XCTAssertEqual(ui.bottomBarText(now: 6.5), "Thu phóng · 250 m")
    }

    func testMusicBarIsSafetyText() {
        let ui = musicPage()
        XCTAssertEqual(ui.bottomBarText(now: 10), "LƯU Ý LÁI XE AN TOÀN")
    }

    func testStartNavigationOpensMap() {
        let ui = DashUI()
        ui.startNavigation(nav(distance: 800), now: 0)
        XCTAssertEqual(ui.page, .map)
        XCTAssertTrue(ui.mapOpen)
    }

    func testArrivalReturnsHome() {
        let ui = DashUI()
        ui.startNavigation(nav(distance: 20), now: 0)
        ui.arrive(now: 10)
        XCTAssertNil(ui.nav)
        XCTAssertEqual(ui.bottomBarText(now: 11), "Đã tới Chợ Bến Thành")
        _ = ui.tick(now: 14.5)
        XCTAssertEqual(ui.page, .home)
        XCTAssertFalse(ui.mapOpen)
    }

    func testDistanceFormatting() {
        let cases: [(Double, String)] = [(1840, "1,8 km"), (1260, "1,3 km"), (980, "1,0 km"), (960, "950 m"),
                                         (430, "450 m"), (120, "100 m"), (95, "100 m"), (90, "90 m"), (40, "40 m")]
        for (m, want) in cases {
            let f = DashUI.formatDistance(m)
            XCTAssertEqual("\(f.value) \(f.unit)", want, "\(m) m")
        }
        XCTAssertEqual(DashUI.turnUrgency(800), .normal)
        XCTAssertEqual(DashUI.turnUrgency(300), .warn)
        XCTAssertEqual(DashUI.turnUrgency(60), .bad)
    }

    func testWarningLevels() {
        XCTAssertEqual(DashUI.coolantLevel(92), .normal)
        XCTAssertEqual(DashUI.coolantLevel(105), .warn)
        XCTAssertEqual(DashUI.coolantLevel(112), .bad)
        XCTAssertEqual(DashUI.batteryLevel(12.8), .normal)
        XCTAssertEqual(DashUI.batteryLevel(12.0), .warn)
        XCTAssertEqual(DashUI.batteryLevel(11.5), .bad)
    }

    private func musicPage() -> DashUI {
        let ui = DashUI()
        _ = ui.press(.up, now: 0)            // từ Home lên Nhạc (Home không chờ đúp)
        XCTAssertEqual(ui.page, .music)
        return ui
    }

    private func nav(distance: Double) -> NavInfo {
        NavInfo(maneuver: .right, distanceToTurnM: distance, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                destination: "Chợ Bến Thành", remainingKm: 7, eta: Date(timeIntervalSince1970: 0), speedLimit: 60)
    }
}
