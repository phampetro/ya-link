import XCTest
@testable import DashCore

/// Luật nút bấm (chỉ UP / DOWN / Home, cửa sổ bấm 1/2/3 lần 0,4 s), menu bản đồ và chữ thanh dưới, đúng như mockup đã chốt.
final class DashUITests: XCTestCase {
    // MARK: - Cuộc gọi

    func testCallBarHasHighestPriorityOnEveryPage() {
        let ui = DashUI()
        ui.showWelcome(now: 0)
        ui.callState = .ringing
        XCTAssertEqual(ui.bottomBarText(now: 0.5), "Chúc thượng lộ bình an", "màn chào vẫn trên cuộc gọi")
        ui.homeBarText = "ODO 100"
        XCTAssertEqual(ui.bottomBarText(now: 10), "Có cuộc gọi đến")
        ui.callState = .active
        XCTAssertEqual(ui.bottomBarText(now: 10), "Đang trong cuộc gọi")
        ui.callState = .ringing
        _ = ui.press(.home, now: 20)
        _ = ui.press(.home, now: 20.2)                                // đúp Home: xoay sang trang kế
        _ = ui.tick(now: 23)
        XCTAssertEqual(ui.bottomBarText(now: 24), "Có cuộc gọi đến", "trang khác vẫn báo cuộc gọi")
        ui.nav = NavInfo(maneuver: .right, distanceToTurnM: 50, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                         destination: "Chợ", remainingKm: 1, eta: Date(), speedLimit: nil)
        XCTAssertEqual(ui.bottomBarText(now: 50), "Có cuộc gọi đến", "trên cả nhắc rẽ")
        ui.callState = .none
        XCTAssertNotEqual(ui.bottomBarText(now: 50), "Có cuộc gọi đến")
        XCTAssertNotEqual(ui.bottomBarText(now: 50), "Đang trong cuộc gọi")
    }

    // MARK: - Trang Home

    func testHomeSinglePressChangesPhoto() {
        let ui = DashUI()
        XCTAssertEqual(ui.press(.down, now: 0), [])
        XCTAssertEqual(ui.tick(now: 0.3), [], "chưa hết 0,4 s: chưa biết là bấm đơn")
        XCTAssertEqual(ui.tick(now: 0.5), [.nextPhoto])
        XCTAssertEqual(ui.page, .home, "bấm đơn không xoay bánh xe")
        XCTAssertEqual(press(ui, .up, at: 5), [.nextPhoto], "UP đơn cũng đổi ảnh")
        XCTAssertEqual(ui.page, .home)
    }

    func testHomeDoublePressRotatesWheel() {
        let ui = DashUI()
        XCTAssertEqual(press(ui, .down, times: 2, at: 0), [])
        XCTAssertEqual(ui.page, .map, "đúp DOWN: về phía Bản đồ")
        _ = ui.press(.home, now: 5)
        XCTAssertEqual(ui.page, .home)
        XCTAssertEqual(press(ui, .up, times: 2, at: 10), [])
        XCTAssertEqual(ui.page, .music, "đúp UP: về phía Nhạc")
    }

    func testHomeTriplePressDoesNothing() {
        let ui = DashUI()
        XCTAssertEqual(press(ui, .up, times: 3, at: 0), [])
        XCTAssertEqual(ui.page, .home)
        XCTAssertEqual(press(ui, .down, times: 3, at: 5), [])
        XCTAssertEqual(ui.page, .home)
        XCTAssertFalse(ui.volumeMode)
        XCTAssertNil(ui.menu)
    }

    func testWheelCyclesPages() {
        let ui = DashUI()
        XCTAssertEqual(ui.page, .home)
        _ = press(ui, .down, times: 2, at: 0)
        XCTAssertEqual(ui.page, .map)
        _ = press(ui, .down, times: 2, at: 5)
        XCTAssertEqual(ui.page, .music, "xoay vòng: Bản đồ, đúp DOWN sang Nhạc")
        _ = press(ui, .up, times: 2, at: 10)
        XCTAssertEqual(ui.page, .map, "xoay vòng: Nhạc, đúp UP sang Bản đồ")
        _ = press(ui, .up, times: 2, at: 15)
        XCTAssertEqual(ui.page, .home, "Bản đồ: đúp UP về Home")
    }

    func testDifferentButtonResolvesPending() {
        let ui = DashUI()
        XCTAssertEqual(ui.press(.down, now: 0), [])
        XCTAssertEqual(ui.press(.up, now: 0.1), [.nextPhoto], "khác nút: lần DOWN chốt thành bấm đơn")
        XCTAssertEqual(ui.tick(now: 1), [.nextPhoto])
        XCTAssertEqual(ui.page, .home)
    }

    func testPressesApartAreSeparateSingles() {
        let ui = DashUI()
        XCTAssertEqual(ui.press(.down, now: 0), [])
        XCTAssertEqual(ui.press(.down, now: 0.6), [.nextPhoto], "quá 0,4 s: không phải đúp")
        XCTAssertEqual(ui.tick(now: 1.2), [.nextPhoto])
        XCTAssertEqual(ui.page, .home)
    }

    // MARK: - Trang Nhạc

    func testMusicSinglePressChangesTrack() {
        let ui = musicPage()
        XCTAssertEqual(ui.press(.up, now: 10), [])
        XCTAssertEqual(ui.tick(now: 10.3), [], "còn trong cửa sổ")
        XCTAssertEqual(ui.tick(now: 10.5), [.nextTrack])
        XCTAssertEqual(ui.flash?.target, .next)
        XCTAssertEqual(ui.page, .music)
        XCTAssertEqual(press(ui, .down, at: 12), [.previousTrack])
        XCTAssertEqual(ui.flash?.target, .previous)
        XCTAssertEqual(ui.page, .music)
    }

    func testMusicDoublePressRotatesWheel() {
        let ui = musicPage()
        XCTAssertEqual(press(ui, .down, times: 2, at: 10), [])
        XCTAssertEqual(ui.page, .home, "đúp DOWN: Nhạc ↓ Home")
        let other = musicPage()
        XCTAssertEqual(press(other, .up, times: 2, at: 10), [])
        XCTAssertEqual(other.page, .map, "đúp UP: Nhạc ↑ Bản đồ (xoay vòng)")
    }

    func testMusicTripleUpEntersVolumeMode() {
        let ui = musicPage()
        XCTAssertEqual(ui.press(.up, now: 10), [])
        XCTAssertEqual(ui.press(.up, now: 10.15), [])
        XCTAssertEqual(ui.press(.up, now: 10.3), [], "lần 3 chốt ngay")
        XCTAssertTrue(ui.volumeMode)
        XCTAssertEqual(ui.page, .music)
        XCTAssertEqual(ui.bottomBarText(now: 10.5), "Âm lượng · +/- chỉnh")
        XCTAssertEqual(ui.press(.up, now: 10.6), [.volume(10)], "trong chế độ âm lượng bấm là chỉnh ngay")
        XCTAssertEqual(ui.press(.down, now: 10.7), [.volume(-10)])
        XCTAssertEqual(ui.press(.down, now: 10.8), [.volume(-10)], "bấm liên tiếp không bị coi là đúp")
        XCTAssertEqual(ui.volume, 50)
        XCTAssertEqual(ui.page, .music)
        _ = ui.tick(now: 12)
        XCTAssertTrue(ui.volumeMode, "mỗi lần chỉnh gia hạn 3 s")
        _ = ui.tick(now: 13.9)
        XCTAssertFalse(ui.volumeMode, "tự đóng sau 3 s không bấm")
        XCTAssertEqual(ui.tick(now: 14), [], "không còn lần bấm treo")
        XCTAssertEqual(ui.bottomBarText(now: 14), "+/- đổi bài · 3×+ âm lượng · 3×- phát/dừng")
    }

    func testMusicTripleDownTogglesPlay() {
        let ui = musicPage()
        _ = ui.press(.down, now: 10)
        _ = ui.press(.down, now: 10.15)
        XCTAssertEqual(ui.press(.down, now: 10.3), [.togglePlay], "lần 3 chốt ngay")
        XCTAssertEqual(ui.flash?.target, .play)
        XCTAssertFalse(ui.volumeMode)
        XCTAssertEqual(ui.tick(now: 11), [])
        XCTAssertEqual(ui.page, .music)
    }

    func testVolumeClampsAndHomeClosesVolumeOnly() {
        let ui = musicPage()
        _ = press(ui, .up, times: 3, at: 10, gap: 0.1)
        XCTAssertTrue(ui.volumeMode)
        for i in 0..<8 { _ = ui.press(.up, now: 11 + Double(i) * 0.1) }
        XCTAssertEqual(ui.volume, 100)
        XCTAssertEqual(ui.press(.home, now: 12), [])
        XCTAssertFalse(ui.volumeMode)
        XCTAssertEqual(ui.page, .music, "Home đóng âm lượng trước, chưa về Home")
        _ = ui.press(.home, now: 13)
        XCTAssertEqual(ui.page, .home)
    }

    func testMusicBarHintFitsAndMentionsGestures() {
        let ui = musicPage()
        let text = ui.bottomBarText(now: 10)
        XCTAssertEqual(text, "+/- đổi bài · 3×+ âm lượng · 3×- phát/dừng")
        XCTAssertLessThanOrEqual(text.count, 42)
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
        let map = mapPage()
        XCTAssertEqual(map.press(.enterHold, now: 10), [])
        XCTAssertNil(map.menu)
    }

    // MARK: - Trang Bản đồ

    func testMapShownImmediatelyWithZoomAndHint() {
        let ui = mapPage()
        XCTAssertTrue(ui.mapOpen, "không còn màn bìa")
        XCTAssertEqual(ui.bottomBarText(now: 1), "+/- thu phóng · 3 lần: menu")
        XCTAssertEqual(ui.bottomBarText(now: 5), "Chia sẻ vị trí từ Google Maps")
        XCTAssertEqual(press(ui, .up, at: 6), [])
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom + 1, "UP đơn phóng to")
        XCTAssertEqual(ui.bottomBarText(now: 7), "Thu phóng · 400 m")
        XCTAssertEqual(ui.bottomBarText(now: 9), "Chia sẻ vị trí từ Google Maps")
        _ = press(ui, .down, at: 10)
        _ = press(ui, .down, at: 11)
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom - 1, "DOWN đơn thu nhỏ")
        XCTAssertEqual(ui.page, .map, "UP/DOWN đơn không xoay bánh xe")
        for i in 0..<10 { _ = press(ui, .down, at: 20 + Double(i) * 2) }
        XCTAssertEqual(ui.zoom, 0, "chặn ở mức xa nhất")
        for i in 0..<10 { _ = press(ui, .up, at: 60 + Double(i) * 2) }
        XCTAssertEqual(ui.zoom, DashUI.zoomScales.count - 1, "chặn ở mức gần nhất")
    }

    func testMapDoubleUpGoesHomeDoubleDownGoesMusic() {
        let ui = mapPage()
        XCTAssertEqual(press(ui, .up, times: 2, at: 5), [])
        XCTAssertEqual(ui.page, .home, "đúp UP: về Home")
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom, "đúp không thu phóng")
        _ = press(ui, .down, times: 2, at: 10)
        XCTAssertEqual(ui.page, .map)
        _ = press(ui, .down, times: 2, at: 15)
        XCTAssertEqual(ui.page, .music, "đúp DOWN: đi tiếp bánh xe sang Nhạc")
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom)
    }

    func testMapLeavingResetsZoomOnNextVisit() {
        let ui = mapPage()
        _ = press(ui, .up, at: 5)
        XCTAssertNotEqual(ui.zoom, DashUI.defaultZoom)
        _ = press(ui, .up, times: 2, at: 10)
        _ = press(ui, .down, times: 2, at: 15)
        XCTAssertEqual(ui.page, .map)
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom)
    }

    func testMapTriplePressOpensMenu() {
        let ui = mapPage(navigating: true, saved: places())
        XCTAssertEqual(ui.press(.down, now: 5), [])
        XCTAssertEqual(ui.press(.down, now: 5.15), [])
        XCTAssertNil(ui.menu)
        XCTAssertEqual(ui.press(.down, now: 5.3), [], "lần 3 mở menu ngay")
        XCTAssertEqual(ui.menu, MapMenu(level: .main, index: 0))
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom, "ba lần không thu phóng")
        XCTAssertEqual(ui.page, .map)
        XCTAssertEqual(ui.bottomBarText(now: 6), "+/- lướt · đúp: chọn · Home thoát")
        XCTAssertEqual(ui.tick(now: 7), [])
        XCTAssertNotNil(ui.menu)
    }

    // MARK: - Menu bản đồ

    func testMenuItemsDependOnNavigationAndPlaces() {
        let idle = mapPage(saved: places())
        openMenu(idle, at: 5)
        XCTAssertEqual(idle.menuItems().map { $0.label }, ["Về nhà", "Đến công ty", "Yêu thích"],
                       "'Dừng chỉ đường' chỉ có khi đang dẫn đường")
        XCTAssertEqual(idle.menuItems().map { $0.sub ?? "" }, ["Quận 7", "Bitexco, Q.1", "2 nơi"])
        let driving = mapPage(navigating: true, saved: places())
        openMenu(driving, at: 5)
        XCTAssertEqual(driving.menuItems().map { $0.label }, ["Dừng chỉ đường", "Về nhà", "Đến công ty", "Yêu thích"])
        XCTAssertTrue(driving.menuItems()[0].danger)
        let empty = mapPage()
        openMenu(empty, at: 5)
        XCTAssertTrue(empty.menuItems()[0].off, "chưa đặt nhà: mờ")
        XCTAssertEqual(empty.menuItems()[2].sub, "Chưa có")
        XCTAssertEqual(DashUI().menuItems(), [], "menu đóng: không có dòng")
    }

    func testMenuSinglePressMovesSelectionCyclically() {
        let ui = mapPage(navigating: true, saved: places())
        openMenu(ui, at: 5)
        XCTAssertEqual(ui.menu?.index, 0)
        XCTAssertEqual(press(ui, .down, at: 6), [])
        XCTAssertEqual(ui.menu?.index, 1)
        _ = press(ui, .up, at: 7)
        _ = press(ui, .up, at: 8)
        XCTAssertEqual(ui.menu?.index, 3, "UP từ dòng đầu xoay vòng xuống dòng cuối")
        _ = press(ui, .down, at: 9)
        XCTAssertEqual(ui.menu?.index, 0, "DOWN từ dòng cuối xoay vòng lên dòng đầu")
        XCTAssertEqual(ui.zoom, DashUI.defaultZoom, "trong menu 1 lần không thu phóng")
        XCTAssertEqual(ui.page, .map)
    }

    func testMenuTriplePressDoesNothing() {
        let ui = mapPage(navigating: true, saved: places())
        openMenu(ui, at: 5)
        XCTAssertEqual(press(ui, .down, times: 3, at: 7), [])
        XCTAssertEqual(ui.menu, MapMenu(level: .main, index: 0))
        XCTAssertEqual(ui.page, .map)
        XCTAssertNotNil(ui.nav)
    }

    func testMenuDoublePressSelectsStopNavigation() {
        let ui = mapPage(navigating: true, saved: places())
        openMenu(ui, at: 5)
        XCTAssertEqual(press(ui, .up, times: 2, at: 7), [.stopNavigation])
        XCTAssertNil(ui.nav)
        XCTAssertNil(ui.menu)
        XCTAssertEqual(ui.page, .map, "dừng chỉ đường ở lại bản đồ")
        XCTAssertEqual(ui.bottomBarText(now: 8), "Đã dừng chỉ đường")
        XCTAssertEqual(ui.bottomBarText(now: 12), "Chia sẻ vị trí từ Google Maps")
    }

    func testMenuNavigatesToHomeWorkAndFavourite() {
        let saved = places()
        let ui = mapPage(saved: saved)
        openMenu(ui, at: 5)
        XCTAssertEqual(press(ui, .up, times: 2, at: 7), [.navigate(saved.home!)])
        XCTAssertNil(ui.menu)
        XCTAssertEqual(ui.bottomBarText(now: 8), "Đi tới Nhà")
        XCTAssertEqual(ui.bottomBarText(now: 12), "Chia sẻ vị trí từ Google Maps", "ghi chú hết sau 2,5 s")

        let work = mapPage(saved: saved)
        openMenu(work, at: 5)
        _ = press(work, .down, at: 7)
        XCTAssertEqual(press(work, .down, times: 2, at: 9), [.navigate(saved.work!)])
        XCTAssertEqual(work.bottomBarText(now: 10), "Đi tới Công ty")

        let fav = mapPage(saved: saved)
        openMenu(fav, at: 5)
        _ = press(fav, .up, at: 7)                                   // xoay vòng tới "Yêu thích"
        XCTAssertEqual(fav.menuItems()[fav.menu?.index ?? 0].label, "Yêu thích")
        XCTAssertEqual(press(fav, .up, times: 2, at: 9), [], "mở danh sách yêu thích")
        XCTAssertEqual(fav.menu, MapMenu(level: .favorites, index: 1))
        XCTAssertEqual(fav.menuItems().map { $0.label }, ["Quay lại", "Cà phê Bờ Hồ", "Sân vận động Thống Nhất"])
        _ = press(fav, .down, at: 11)
        XCTAssertEqual(press(fav, .down, times: 2, at: 13), [.navigate(saved.favs[1])])
        XCTAssertNil(fav.menu)
        XCTAssertEqual(fav.bottomBarText(now: 14), "Đi tới Sân vận động Thống Nhất")
    }

    func testMenuSelectingMissingPlacesShowsNotes() {
        let ui = mapPage()
        openMenu(ui, at: 5)
        XCTAssertEqual(press(ui, .up, times: 2, at: 7), [], "chưa đặt nhà: không dẫn đường")
        XCTAssertNil(ui.menu)
        XCTAssertEqual(ui.bottomBarText(now: 8), "Chưa đặt nhà")

        openMenu(ui, at: 20)
        _ = press(ui, .down, at: 22)
        XCTAssertEqual(press(ui, .down, times: 2, at: 24), [])
        XCTAssertEqual(ui.bottomBarText(now: 25), "Chưa đặt công ty")
    }

    func testMenuEmptyFavouritesAndBackItem() {
        let ui = mapPage()
        openMenu(ui, at: 5)
        _ = press(ui, .up, at: 7)                                    // tới "Yêu thích"
        _ = press(ui, .up, times: 2, at: 9)
        XCTAssertEqual(ui.menu?.level, .favorites)
        XCTAssertEqual(ui.menuItems().map { $0.label }, ["Quay lại", "Chưa có yêu thích"])
        XCTAssertEqual(ui.menu?.index, 0, "danh sách trống: chọn dòng đầu")
        _ = press(ui, .down, at: 11)
        XCTAssertEqual(ui.menu?.index, 1)
        XCTAssertEqual(press(ui, .down, times: 2, at: 13), [], "dòng 'Chưa có yêu thích' không làm gì")
        XCTAssertEqual(ui.menu?.level, .favorites)
        _ = press(ui, .up, at: 15)                                   // lên "Quay lại"
        XCTAssertEqual(ui.menu?.index, 0)
        _ = press(ui, .up, times: 2, at: 17)
        XCTAssertEqual(ui.menu, MapMenu(level: .main, index: 0), "'Quay lại' về menu chính")
    }

    func testHomeButtonBacksOutOfMenuWithoutLeavingMap() {
        let ui = mapPage(saved: places())
        openMenu(ui, at: 5)
        _ = press(ui, .up, at: 7)
        _ = press(ui, .up, times: 2, at: 9)
        XCTAssertEqual(ui.menu?.level, .favorites)
        XCTAssertEqual(ui.press(.home, now: 11), [])
        XCTAssertEqual(ui.menu, MapMenu(level: .main, index: 0), "Home: lùi một cấp")
        XCTAssertEqual(ui.page, .map)
        XCTAssertEqual(ui.press(.home, now: 12), [])
        XCTAssertNil(ui.menu, "Home lần nữa: đóng menu")
        XCTAssertEqual(ui.page, .map, "bản đồ vẫn hiện")
        XCTAssertEqual(ui.press(.home, now: 13), [])
        XCTAssertEqual(ui.page, .home, "không còn menu: Home về trang Home")
    }

    func testMenuAutoClosesAfterEightSeconds() {
        let ui = mapPage(saved: places())
        openMenu(ui, at: 5)                          // mở lúc 5,3
        _ = ui.tick(now: 12)
        XCTAssertNotNil(ui.menu)
        _ = ui.tick(now: 13.4)
        XCTAssertNil(ui.menu, "8 s không bấm: tự đóng")
        XCTAssertEqual(ui.page, .map)

        openMenu(ui, at: 20)
        _ = press(ui, .down, at: 26)                 // bấm gia hạn
        _ = ui.tick(now: 33)
        XCTAssertNotNil(ui.menu, "mỗi lần bấm gia hạn 8 s")
        _ = ui.tick(now: 40)
        XCTAssertNil(ui.menu)
    }

    func testArrivalClosesMenu() {
        let ui = DashUI()
        ui.startNavigation(nav(distance: 20), now: 0)
        openMenu(ui, at: 5)
        ui.arrive(now: 10)
        XCTAssertNil(ui.menu)
        XCTAssertNil(ui.nav)
    }

    // MARK: - Nút Home

    func testHomeButtonGoesHomeFromAnyPage() {
        let music = musicPage()
        _ = music.press(.home, now: 10)
        XCTAssertEqual(music.page, .home)

        let ui = mapPage()
        _ = ui.press(.home, now: 5)
        XCTAssertEqual(ui.page, .home, "bản đồ không menu: Home về trang Home ngay")
        _ = ui.press(.home, now: 6)
        XCTAssertEqual(ui.page, .home)
    }

    func testHomeCancelsPendingPress() {
        let ui = musicPage()
        _ = ui.press(.up, now: 10)
        _ = ui.press(.home, now: 10.1)
        XCTAssertEqual(ui.tick(now: 11), [], "lần bấm treo bị huỷ")
        XCTAssertEqual(ui.page, .home)
    }

    // MARK: - Màn chào, thanh dưới, dẫn đường

    func testWelcomeBlocksButtonsAndSetsBar() {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        ui.showWelcome(now: 0)
        XCTAssertEqual(ui.bottomBarText(now: 1), "Chúc thượng lộ bình an")
        XCTAssertEqual(ui.press(.up, now: 1), [])
        XCTAssertEqual(ui.press(.up, now: 1.1), [])
        XCTAssertEqual(ui.tick(now: 1.9), [])
        XCTAssertEqual(ui.page, .home)
        XCTAssertEqual(ui.bottomBarText(now: 2.5), "ODO 3.214 km")
    }

    func testBottomBarTexts() {
        let ui = DashUI()
        ui.homeBarText = "ODO 3.214 km"
        XCTAssertEqual(ui.bottomBarText(now: 0), "ODO 3.214 km", "không chỉ đường: chữ mặc định của trang chủ")
        ui.nav = nav(distance: 300)
        XCTAssertEqual(ui.bottomBarText(now: 0), "Nguyễn Huệ", "đang chỉ đường: tên đường thay cho ODO")
        ui.nav = nav(distance: 60)
        XCTAssertEqual(ui.bottomBarText(now: 0), "Rẽ phải vào Lê Lợi", "dưới 100 m nhắc rẽ ở mọi trang trừ bản đồ")
        _ = press(ui, .down, times: 2, at: 1)
        XCTAssertEqual(ui.bottomBarText(now: 2), "+/- thu phóng · 3 lần: menu", "bản đồ: không nhắc rẽ")
        XCTAssertEqual(ui.bottomBarText(now: 6), "Nguyễn Huệ")
        _ = press(ui, .up, at: 7)
        XCTAssertEqual(ui.bottomBarText(now: 8), "Thu phóng · 250 m")
    }

    func testMapWithoutNavigationAsksToShare() {
        let ui = mapPage()
        XCTAssertEqual(ui.bottomBarText(now: 10), "Chia sẻ vị trí từ Google Maps")
        ui.nav = nav(distance: 800)
        XCTAssertEqual(ui.bottomBarText(now: 10), "Nguyễn Huệ", "có chuyến đi: hiện tên đường đang chạy")
    }

    func testStartNavigationShowsMapAtOnce() {
        let ui = DashUI()
        ui.startNavigation(nav(distance: 800), now: 0)
        XCTAssertEqual(ui.page, .map)
        XCTAssertTrue(ui.mapOpen)
        XCTAssertEqual(ui.bottomBarText(now: 1), "+/- thu phóng · 3 lần: menu")
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
        XCTAssertEqual(press(ui, .up, at: 5.1), [.nextPhoto], "nút dùng được ngay")
        XCTAssertEqual(ui.sinceWelcomeEnd(5), 0, "hiệu ứng trượt vào chạy từ đầu")
    }

    func testWelcomeFromMapGoesHome() {
        let ui = mapPage()
        ui.showWelcome(now: 10)
        XCTAssertEqual(ui.page, .home)
        XCTAssertFalse(ui.mapOpen)
        XCTAssertTrue(ui.inWelcome(11))
        XCTAssertFalse(ui.inWelcome(12.1))
    }

    func testWelcomeClosesMenu() {
        let ui = mapPage()
        openMenu(ui, at: 5)
        ui.showWelcome(now: 10)
        XCTAssertNil(ui.menu)
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
        _ = press(ui, .up, times: 2, at: 0)  // từ Home đúp UP lên Nhạc
        XCTAssertEqual(ui.page, .music)
        return ui
    }

    /// Trang Bản đồ (đúp DOWN từ Home); `navigating`: có chuyến đi; `saved`: nơi đã lưu của app.
    private func mapPage(navigating: Bool = false, saved: SavedPlaces = SavedPlaces()) -> DashUI {
        let ui = DashUI()
        ui.places = saved
        if navigating { ui.nav = nav(distance: 800) }
        _ = press(ui, .down, times: 2, at: 0)
        XCTAssertEqual(ui.page, .map)
        return ui
    }

    /// Mở menu bản đồ bằng 3 lần bấm tại `at`.
    private func openMenu(_ ui: DashUI, at: TimeInterval) {
        XCTAssertEqual(press(ui, .up, times: 3, at: at), [])
        XCTAssertNotNil(ui.menu)
    }

    private func nav(distance: Double) -> NavInfo {
        NavInfo(maneuver: .right, distanceToTurnM: distance, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                destination: "Chợ Bến Thành", remainingKm: 7, eta: Date(timeIntervalSince1970: 0), speedLimit: 60)
    }
}
