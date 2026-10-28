import XCTest
@testable import DashCore

/// Luật nút bấm (chỉ UP / DOWN / Home, cửa sổ bấm nhiều lần 0,4 s) và chữ thanh dưới, đúng như mockup đã chốt.
final class DashUITests: XCTestCase {
    func testWheelCyclesPages() {
        let ui = DashUI()
        XCTAssertEqual(ui.page, .home)
        _ = press(ui, .down, at: 0)
        XCTAssertEqual(ui.page, .map)
        _ = press(ui, .down, at: 1)
        XCTAssertEqual(ui.page, .music, "xoay vòng: Bản đồ ↓ Nhạc")
        _ = press(ui, .up, at: 2)
        XCTAssertEqual(ui.page, .map, "Nhạc ↑ (xoay vòng) Bản đồ")
        _ = press(ui, .up, times: 2, at: 3)
        XCTAssertEqual(ui.page, .home, "Bản đồ: đúp ↑ về Home")
    }

    func testSinglePressWaitsForWindow() {
        let ui = DashUI()
        XCTAssertEqual(ui.press(.down, now: 0), [])
        XCTAssertEqual(ui.page, .home, "chưa hết 0,4 s: chưa biết là bấm đơn")
        _ = ui.tick(now: 0.3)
        XCTAssertEqual(ui.page, .home)
        _ = ui.tick(now: 0.5)
        XCTAssertEqual(ui.page, .map)
    }

    func testHomeDoublePressChangesPhoto() {
        let ui = DashUI()
        XCTAssertEqual(ui.press(.down, now: 0), [])
        XCTAssertEqual(ui.press(.down, now: 0.2), [.nextPhoto])
        XCTAssertEqual(ui.tick(now: 1), [])
        XCTAssertEqual(ui.page, .home, "đúp không xoay trang")
        XCTAssertEqual(press(ui, .up, times: 2, at: 5), [.nextPhoto], "đúp UP cũng đổi ảnh")
        XCTAssertEqual(ui.page, .home)
    }

    func testMusicDoublePress() {
        let ui = musicPage()
        XCTAssertEqual(ui.press(.up, now: 10), [])
        XCTAssertEqual(ui.press(.up, now: 10.2), [])
        XCTAssertEqual(ui.tick(now: 10.4), [], "còn trong cửa sổ: chờ xem có bấm lần 3 không")
        XCTAssertEqual(ui.tick(now: 10.7), [.nextTrack])
        XCTAssertEqual(ui.page, .music, "bấm đúp không đổi trang")
        XCTAssertEqual(press(ui, .down, times: 2, at: 12), [.previousTrack])
        XCTAssertEqual(ui.page, .music)
        _ = press(ui, .down, at: 13)
        XCTAssertEqual(ui.page, .home, "bấm đơn DOWN sau 0,4 s mới đổi trang (Nhạc ↓ Home)")
    }

    func testMusicTriplePressUpTogglesPlay() {
        let ui = musicPage()
        _ = ui.press(.up, now: 10)
        _ = ui.press(.up, now: 10.2)
        XCTAssertEqual(ui.press(.up, now: 10.4), [.togglePlay], "lần 3 chốt ngay")
        XCTAssertEqual(ui.flash?.target, .play)
        XCTAssertEqual(ui.tick(now: 11), [])
        XCTAssertEqual(ui.page, .music)
    }

    func testMusicTripleDownEntersVolumeMode() {
        let ui = musicPage()
        XCTAssertEqual(press(ui, .down, times: 3, at: 10, gap: 0.15), [])
        XCTAssertTrue(ui.volumeMode)
        XCTAssertEqual(ui.page, .music)
        XCTAssertEqual(ui.bottomBarText(now: 10.5), "Âm lượng · ▲▼ chỉnh")
        XCTAssertEqual(ui.press(.up, now: 10.6), [.volume(10)], "trong chế độ âm lượng bấm là chỉnh ngay")
        XCTAssertEqual(ui.press(.down, now: 10.7), [.volume(-10)])
        XCTAssertEqual(ui.press(.down, now: 10.8), [.volume(-10)], "bấm liên tiếp không bị coi là đúp")
        XCTAssertEqual(ui.volume, 50)
        XCTAssertEqual(ui.page, .music)
        _ = ui.tick(now: 12)
        XCTAssertTrue(ui.volumeMode, "mỗi lần chỉnh gia hạn 3 s")
        _ = ui.tick(now: 13.9)
        XCTAssertFalse(ui.volumeMode, "tự đóng sau 3 s")
        XCTAssertEqual(ui.bottomBarText(now: 14), "Đúp ▲▼ đổi bài · Ba lần ▲ phát/dừng")
    }

    func testVolumeClampsAndHomeClosesVolume() {
        let ui = musicPage()
        _ = press(ui, .down, times: 3, at: 10, gap: 0.1)
        for i in 0..<8 { _ = ui.press(.up, now: 11 + Double(i) * 0.1) }
        XCTAssertEqual(ui.volume, 100)
        _ = ui.press(.home, now: 12)
        XCTAssertFalse(ui.volumeMode)
        XCTAssertEqual(ui.page, .home)
    }

    func testEnterButtonsDoNothing() {
        let ui = DashUI()
        XCTAssertEqual(ui.press(.enter, now: 0), [])
        XCTAssertEqual(ui.press(.enterHold, now: 1), [])
        XCTAssertEqual(ui.page, .home)
        let music = musicPage()
        XCTAssertEqual(music.press(.enter, now: 10), [])
        XCTAssertEqual(music.press(.enterHold, now: 11), [])
        XCTAssertFalse(music.volumeMode)
    }

    func testMapShownImmediatelyWithZoomAndHint() {
        let ui = DashUI()
        _ = press(ui, .down, at: 0)
        XCTAssertEqual(ui.page, .map)
        XCTAssertTrue(ui.mapOpen, "không còn màn bìa")
        XCTAssertEqual(ui.bottomBarText(now: 1), "▲▼ thu phóng · đúp ▲ thoát")
        XCTAssertEqual(ui.bottomBarText(now: 4), "Chia sẻ vị trí từ Google Maps")
        _ = press(ui, .up, at: 5)
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom + 1, "UP phóng to")
        XCTAssertEqual(ui.bottomBarText(now: 6), "Thu phóng · 250 m")
        XCTAssertEqual(ui.bottomBarText(now: 8), "Chia sẻ vị trí từ Google Maps")
        _ = press(ui, .down, at: 9)
        _ = press(ui, .down, at: 10)
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom - 1)
        XCTAssertEqual(ui.page, .map, "đang ở bản đồ UP/DOWN không xoay bánh xe")
        for i in 0..<10 { _ = press(ui, .down, at: 20 + Double(i)) }
        XCTAssertEqual(ui.zoom, 0, "chặn ở mức xa nhất")
    }

    func testMapDoubleUpGoesHomeDoubleDownGoesMusic() {
        let ui = DashUI()
        _ = press(ui, .down, at: 0)
        XCTAssertEqual(press(ui, .up, times: 2, at: 5), [])
        XCTAssertEqual(ui.page, .home, "đúp UP: về Home")
        XCTAssertFalse(ui.mapOpen)
        _ = press(ui, .down, at: 10)
        XCTAssertEqual(ui.page, .map)
        _ = press(ui, .down, times: 2, at: 15)
        XCTAssertEqual(ui.page, .music, "đúp DOWN: đi tiếp bánh xe sang Nhạc")
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom, "đúp không thu phóng")
    }

    func testMapDoubleExitResetsZoomOnNextVisit() {
        let ui = DashUI()
        _ = press(ui, .down, at: 0)
        _ = press(ui, .up, at: 5)
        XCTAssertNotEqual(ui.zoom, DashUI.defaultZoom)
        _ = press(ui, .up, times: 2, at: 10)
        _ = press(ui, .down, at: 15)
        XCTAssertEqual(ui.page, .map)
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom)
    }

    func testHomeButtonGoesHomeFromAnyPage() {
        let music = musicPage()
        _ = music.press(.home, now: 10)
        XCTAssertEqual(music.page, .home)

        let ui = DashUI()
        _ = press(ui, .down, at: 0)
        _ = ui.press(.home, now: 5)
        XCTAssertEqual(ui.page, .home, "bản đồ: Home về trang Home ngay")
        XCTAssertFalse(ui.mapOpen)
        _ = ui.press(.home, now: 6)
        XCTAssertEqual(ui.page, .home)
    }

    func testHomeCancelsPendingPress() {
        let ui = musicPage()
        _ = ui.press(.up, now: 10)
        _ = ui.press(.home, now: 10.1)
        XCTAssertEqual(ui.tick(now: 11), [])
        XCTAssertEqual(ui.page, .home)
    }

    func testDifferentButtonResolvesPending() {
        let ui = DashUI()
        _ = ui.press(.down, now: 0)
        _ = ui.press(.up, now: 0.1)          // khác nút: lần DOWN chốt thành bấm đơn (Home → Bản đồ)
        XCTAssertEqual(ui.page, .map)
        _ = ui.tick(now: 1)
        XCTAssertEqual(ui.page, .map, "UP đơn trên bản đồ là phóng to, không xoay")
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom + 1)
    }

    func testWelcomeBlocksButtonsAndSetsBar() {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        ui.showWelcome(now: 0)
        XCTAssertEqual(ui.bottomBarText(now: 1), "Chúc thượng lộ bình an")
        XCTAssertEqual(ui.press(.up, now: 1), [])
        XCTAssertEqual(ui.press(.up, now: 1.1), [])
        XCTAssertEqual(ui.page, .home)
        XCTAssertEqual(ui.bottomBarText(now: 2.5), "ODO 3.214 km")
    }

    func testBottomBarTexts() {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        ui.nav = nav(distance: 300)
        XCTAssertEqual(ui.bottomBarText(now: 0), "ODO 3.214 km")
        ui.nav = nav(distance: 60)
        XCTAssertEqual(ui.bottomBarText(now: 0), "Rẽ phải vào Lê Lợi", "dưới 100 m nhắc rẽ ở mọi trang trừ bản đồ")
        _ = press(ui, .down, at: 1)
        XCTAssertEqual(ui.bottomBarText(now: 2), "▲▼ thu phóng · đúp ▲ thoát", "bản đồ: không nhắc rẽ")
        XCTAssertEqual(ui.bottomBarText(now: 6), "Nguyễn Huệ")
        _ = press(ui, .up, at: 7)
        XCTAssertEqual(ui.bottomBarText(now: 8), "Thu phóng · 250 m")
    }

    func testMapWithoutNavigationAsksToShare() {
        let ui = DashUI()
        _ = press(ui, .down, at: 0)
        XCTAssertEqual(ui.page, .map)
        XCTAssertEqual(ui.bottomBarText(now: 10), "Chia sẻ vị trí từ Google Maps")
        ui.nav = nav(distance: 800)
        XCTAssertEqual(ui.bottomBarText(now: 10), "Nguyễn Huệ", "có chuyến đi: hiện tên đường đang chạy")
    }

    func testMusicBarHintsGestures() {
        let ui = musicPage()
        let text = ui.bottomBarText(now: 10)
        XCTAssertEqual(text, "Đúp ▲▼ đổi bài · Ba lần ▲ phát/dừng")
        XCTAssertLessThanOrEqual(text.count, 40)
    }

    func testStartNavigationShowsMapAtOnce() {
        let ui = DashUI()
        ui.startNavigation(nav(distance: 800), now: 0)
        XCTAssertEqual(ui.page, .map)
        XCTAssertTrue(ui.mapOpen)
        XCTAssertEqual(ui.bottomBarText(now: 1), "▲▼ thu phóng · đúp ▲ thoát")
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

    // MARK: - Màn chào

    func testGreetingDisabledSkipsWelcome() {
        let ui = DashUI()
        ui.greetingEnabled = false
        ui.homeBarText = "ODO 3.214 km"
        ui.showWelcome(now: 5)
        XCTAssertFalse(ui.inWelcome(5))
        XCTAssertEqual(ui.page, .home)
        XCTAssertEqual(ui.bottomBarText(now: 5), "ODO 3.214 km")
        XCTAssertEqual(press(ui, .up, times: 2, at: 5.1), [.nextPhoto], "nút dùng được ngay")
        XCTAssertEqual(ui.sinceWelcomeEnd(5), 0, "hiệu ứng trượt vào chạy từ đầu")
    }

    func testWelcomeFromMapGoesHome() {
        let ui = DashUI()
        _ = press(ui, .down, at: 0)
        XCTAssertEqual(ui.page, .map)
        ui.showWelcome(now: 10)
        XCTAssertEqual(ui.page, .home)
        XCTAssertFalse(ui.mapOpen)
        XCTAssertTrue(ui.inWelcome(11))
        XCTAssertFalse(ui.inWelcome(12.1))
    }

    func testSavedPlacesCodableRoundTrip() throws {
        let value = places()
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(SavedPlaces.self, from: data), value)
        XCTAssertEqual(value.home?.id, "NhàQuận 7")
        XCTAssertEqual(SavedPlaces(), SavedPlaces(home: nil, work: nil, favs: []))
    }

    // MARK: - Trợ giúp

    /// Bấm `times` lần `button` cách nhau `gap` giây từ `at`, rồi gọi tick sau cửa sổ chờ. Trả mọi hành động phát ra.
    @discardableResult
    private func press(_ ui: DashUI, _ button: DashUI.Button, times: Int = 1, at: TimeInterval,
                       gap: TimeInterval = 0.15) -> [DashUI.Action] {
        var actions: [DashUI.Action] = []
        var t = at
        for _ in 0..<times {
            actions += ui.press(button, now: t)
            t += gap
        }
        actions += ui.tick(now: t + DashUI.doublePressWindow + 0.1)
        return actions
    }

    private func places() -> SavedPlaces {
        SavedPlaces(home: SavedPlace(name: "Nhà", sub: "Quận 7", lat: 10.73, lon: 106.72),
                    work: SavedPlace(name: "Công ty", sub: "Bitexco, Q.1", lat: 10.77, lon: 106.70),
                    favs: [SavedPlace(name: "Cà phê Bờ Hồ", sub: "Q.1", lat: 10.78, lon: 106.69),
                           SavedPlace(name: "Sân vận động Thống Nhất", sub: "Q.10", lat: 10.76, lon: 106.66)])
    }

    private func musicPage() -> DashUI {
        let ui = DashUI()
        _ = press(ui, .up, at: 0)            // từ Home lên Nhạc (bấm đơn: chờ hết cửa sổ rồi mới xoay)
        XCTAssertEqual(ui.page, .music)
        return ui
    }

    private func nav(distance: Double) -> NavInfo {
        NavInfo(maneuver: .right, distanceToTurnM: distance, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                destination: "Chợ Bến Thành", remainingKm: 7, eta: Date(timeIntervalSince1970: 0), speedLimit: 60)
    }
}
