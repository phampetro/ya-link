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

    func testMapCoverWithoutNavigationAsksToShare() {
        let ui = DashUI()
        _ = ui.press(.down, now: 0)
        XCTAssertEqual(ui.page, .map)
        XCTAssertEqual(ui.bottomBarText(now: 1), "Chia sẻ vị trí từ Google Maps")
        ui.nav = nav(distance: 800)
        XCTAssertEqual(ui.bottomBarText(now: 1), "Nguyễn Huệ", "có chuyến đi: hiện tên đường đang chạy")
    }

    func testMusicBarHintsVolume() {
        let ui = musicPage()
        XCTAssertEqual(ui.bottomBarText(now: 10), "Giữ Enter để tăng/giảm âm lượng")
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

    // MARK: - Menu bản đồ

    func testHoldEnterOpensMapMenuOnlyWhenMapOpen() {
        let ui = mapPage(open: false)
        _ = ui.press(.enterHold, now: 1)
        XCTAssertNil(ui.menu, "màn bìa: giữ Enter không mở menu")
        _ = ui.press(.enter, now: 2)
        XCTAssertTrue(ui.mapOpen)
        XCTAssertEqual(ui.press(.enterHold, now: 3), [])
        XCTAssertEqual(ui.menu, MapMenu(level: .main, index: 0))
        XCTAssertEqual(ui.bottomBarText(now: 3.5), "▲▼ chọn · Enter xác nhận · Home thoát")
    }

    func testHoldEnterOnMusicStillOpensVolume() {
        let ui = musicPage()
        _ = ui.press(.enterHold, now: 5)
        XCTAssertTrue(ui.volumeMode)
        XCTAssertNil(ui.menu)
    }

    func testMenuItemsDependOnNavigation() {
        let ui = mapPage(open: true)
        ui.places = places()
        _ = ui.press(.enterHold, now: 3)
        XCTAssertEqual(ui.menuItems().map { $0.kind }, [.home, .work, .favorites])
        _ = ui.press(.home, now: 4)
        XCTAssertNil(ui.menu)
        ui.nav = nav(distance: 800)
        _ = ui.press(.enterHold, now: 5)
        XCTAssertEqual(ui.menuItems().map { $0.kind }, [.stop, .home, .work, .favorites])
        XCTAssertTrue(ui.menuItems()[0].danger)
        XCTAssertEqual(ui.menuItems()[3].sub, "2 nơi")
        XCTAssertTrue(ui.menuItems()[3].chevron)
    }

    func testMenuSelectionIsCyclic() {
        let ui = mapPage(open: true)
        _ = ui.press(.enterHold, now: 3)                       // không chỉ đường: 3 dòng
        _ = ui.press(.up, now: 3.1)
        XCTAssertEqual(ui.menu?.index, 2, "UP ở dòng đầu: xuống dòng cuối")
        _ = ui.press(.down, now: 3.2)
        XCTAssertEqual(ui.menu?.index, 0, "DOWN ở dòng cuối: về dòng đầu")
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom, "menu mở: UP/DOWN không thu phóng")
    }

    func testMenuStopNavigation() {
        let ui = mapPage(open: true)
        ui.nav = nav(distance: 800)
        _ = ui.press(.enterHold, now: 3)
        XCTAssertEqual(ui.press(.enter, now: 4), [.stopNavigation])
        XCTAssertNil(ui.menu)
        XCTAssertNil(ui.nav)
        XCTAssertTrue(ui.mapOpen, "bản đồ vẫn mở")
        XCTAssertEqual(ui.bottomBarText(now: 5), "Đã dừng chỉ đường")
        XCTAssertNotEqual(ui.bottomBarText(now: 6.6), "Đã dừng chỉ đường", "ghi chú hết sau 2,5 s")
    }

    func testMenuNavigateHomeWorkAndFavourite() {
        let ui = mapPage(open: true)
        ui.places = places()
        _ = ui.press(.enterHold, now: 3)
        XCTAssertEqual(ui.press(.enter, now: 4), [.navigate(places().home!)], "dòng đầu = Về nhà")
        XCTAssertNil(ui.menu)
        XCTAssertEqual(ui.bottomBarText(now: 4.5), "Đi tới Nhà")

        _ = ui.press(.enterHold, now: 10)
        _ = ui.press(.down, now: 10.1)
        XCTAssertEqual(ui.press(.enter, now: 10.2), [.navigate(places().work!)])
        XCTAssertEqual(ui.bottomBarText(now: 10.5), "Đi tới Công ty")

        _ = ui.press(.enterHold, now: 20)
        _ = ui.press(.up, now: 20.1)                           // xoay vòng tới "Yêu thích"
        XCTAssertEqual(ui.press(.enter, now: 20.2), [])
        XCTAssertEqual(ui.menu?.level, .favorites)
        XCTAssertEqual(ui.menu?.index, 1, "vào danh sách yêu thích: chọn sẵn nơi đầu tiên")
        XCTAssertEqual(ui.menuItems().map { $0.label }, ["Quay lại", "Cà phê Bờ Hồ", "Sân vận động Thống Nhất"])
        _ = ui.press(.down, now: 20.3)
        XCTAssertEqual(ui.press(.enter, now: 20.4), [.navigate(places().favs[1])])
        XCTAssertNil(ui.menu)
        XCTAssertEqual(ui.bottomBarText(now: 20.5), "Đi tới Sân vận động Thống Nhất")
    }

    func testMenuMissingHomeOrWorkShowsNote() {
        let ui = mapPage(open: true)                           // chưa đặt nơi nào
        _ = ui.press(.enterHold, now: 3)
        XCTAssertEqual(ui.press(.enter, now: 4), [])
        XCTAssertNil(ui.menu)
        XCTAssertEqual(ui.bottomBarText(now: 4.5), "Chưa đặt nhà")
        _ = ui.press(.enterHold, now: 10)
        _ = ui.press(.down, now: 10.1)
        XCTAssertEqual(ui.press(.enter, now: 10.2), [])
        XCTAssertEqual(ui.bottomBarText(now: 10.5), "Chưa đặt công ty")
        XCTAssertNotEqual(ui.bottomBarText(now: 12.8), "Chưa đặt công ty")
    }

    func testMenuHomeGoesBackOneLevelThenClosesAndMapStaysOpen() {
        let ui = mapPage(open: true)
        ui.places = places()
        _ = ui.press(.enterHold, now: 3)
        _ = ui.press(.up, now: 3.1)
        _ = ui.press(.enter, now: 3.2)
        XCTAssertEqual(ui.menu?.level, .favorites)
        _ = ui.press(.home, now: 4)
        XCTAssertEqual(ui.menu, MapMenu(level: .main, index: 0), "Home: về menu chính")
        _ = ui.press(.home, now: 5)
        XCTAssertNil(ui.menu, "Home lần 2: đóng menu")
        XCTAssertTrue(ui.mapOpen)
        XCTAssertEqual(ui.page, .map)
        // "Quay lại" trong danh sách yêu thích cũng về menu chính
        _ = ui.press(.enterHold, now: 6)
        _ = ui.press(.up, now: 6.1)
        _ = ui.press(.enter, now: 6.2)
        _ = ui.press(.up, now: 6.3)                            // dòng "Quay lại"
        XCTAssertEqual(ui.press(.enter, now: 6.4), [])
        XCTAssertEqual(ui.menu?.level, .main)
    }

    func testMenuAutoClosesAfterEightSecondsOfNoInput() {
        let ui = mapPage(open: true)
        _ = ui.press(.enterHold, now: 10)
        _ = ui.tick(now: 17.9)
        XCTAssertNotNil(ui.menu)
        _ = ui.press(.down, now: 17.9)                         // bấm lại: đếm lại 8 s
        _ = ui.tick(now: 25)
        XCTAssertNotNil(ui.menu)
        _ = ui.tick(now: 26)
        XCTAssertNil(ui.menu)
        XCTAssertTrue(ui.mapOpen)
    }

    func testFavouritesEmptyListHasNoSelectableFavourite() {
        let ui = mapPage(open: true)
        ui.places = SavedPlaces(home: places().home, work: nil, favs: [])
        _ = ui.press(.enterHold, now: 3)
        _ = ui.press(.up, now: 3.1)
        _ = ui.press(.enter, now: 3.2)
        XCTAssertEqual(ui.menu?.index, 0)
        XCTAssertEqual(ui.menuItems().map { $0.kind }, [.back, .empty])
        XCTAssertTrue(ui.menuItems()[1].off)
        _ = ui.press(.down, now: 3.3)
        XCTAssertEqual(ui.press(.enter, now: 3.4), [])
        XCTAssertEqual(ui.menu?.level, .favorites, "dòng 'Chưa có yêu thích' không làm gì")
    }

    func testMenuHiddenByArrival() {
        let ui = mapPage(open: true)
        ui.nav = nav(distance: 20)
        _ = ui.press(.enterHold, now: 3)
        ui.arrive(now: 4)
        XCTAssertNil(ui.menu)
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
        XCTAssertEqual(ui.press(.enter, now: 5.1), [.nextPhoto], "nút dùng được ngay")
        XCTAssertEqual(ui.sinceWelcomeEnd(5), 0, "hiệu ứng trượt vào chạy từ đầu")
    }

    func testWelcomeFromMapGoesHome() {
        let ui = mapPage(open: true)
        ui.showWelcome(now: 10)
        XCTAssertEqual(ui.page, .home)
        XCTAssertFalse(ui.mapOpen)
        XCTAssertNil(ui.menu)
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

    private func mapPage(open: Bool) -> DashUI {
        let ui = DashUI()
        _ = ui.press(.down, now: 0)
        XCTAssertEqual(ui.page, .map)
        if open { _ = ui.press(.enter, now: 1) }
        return ui
    }

    private func places() -> SavedPlaces {
        SavedPlaces(home: SavedPlace(name: "Nhà", sub: "Quận 7", lat: 10.73, lon: 106.72),
                    work: SavedPlace(name: "Công ty", sub: "Bitexco, Q.1", lat: 10.77, lon: 106.70),
                    favs: [SavedPlace(name: "Cà phê Bờ Hồ", sub: "Q.1", lat: 10.78, lon: 106.69),
                           SavedPlace(name: "Sân vận động Thống Nhất", sub: "Q.10", lat: 10.76, lon: 106.66)])
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
