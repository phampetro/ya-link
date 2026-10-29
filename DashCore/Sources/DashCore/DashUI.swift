import Foundation

/// Trạng thái và luật điều khiển giao diện trên đồng hồ (theo mockup design/dash/home.html).
/// Không vẽ gì: bộ vẽ (DashRender) đọc trạng thái này. Mọi hàm nhận `now` để test được.
///
/// Đồng hồ xe nuốt Enter và giữ Enter: app chỉ nhận UP, DOWN và Home. Luật điều khiển: các lần bấm cùng một nút
/// trong 0,4 s được đếm (1, 2, 3); chốt khi hết cửa sổ (`tick`) hoặc khi đủ 3 lần.
///   Bánh xe menu: Nhạc (UP) · Home · Bản đồ (DOWN), xoay vòng.
///   Home: 1 lần đổi ảnh nền · 2 lần xoay bánh xe (UP về phía Nhạc, DOWN về phía Bản đồ) · 3 lần không làm gì
///   Nhạc: 1 lần UP bài sau, DOWN bài trước · 2 lần xoay bánh xe · 3 lần UP chế độ âm lượng, 3 lần DOWN phát/dừng
///     (chế độ âm lượng: UP/DOWN ±10 % bấm là chỉnh ngay, tự đóng sau 3 s, Home đóng)
///   Bản đồ (hiện ngay khi chọn trang): 1 lần UP phóng to, DOWN thu nhỏ · 2 lần xoay bánh xe (UP Home, DOWN Nhạc)
///     · 3 lần mở menu bản đồ tự vẽ (Dừng chỉ đường / Về nhà / Đến công ty / Yêu thích)
///   Menu bản đồ: 1 lần UP/DOWN chọn (xoay vòng) · 2 lần xác nhận · Home quay lại/đóng · tự đóng sau 8 s
///   Home: đóng chế độ âm lượng/menu trước, không thì về trang Home từ mọi trang
/// `.enter` và `.enterHold` giữ lại cho khớp API nhưng không làm gì.
public final class DashUI {
    public enum Page: Int, CaseIterable { case music = 0, home = 1, map = 2 }
    public enum Button { case up, down, enter, enterHold, home }
    public enum Action: Equatable {
        case nextTrack, previousTrack, togglePlay, volume(Int), nextPhoto
        /// Người dùng chọn "Dừng chỉ đường" trong menu bản đồ (app dừng dẫn đường thật).
        case stopNavigation
        /// Người dùng chọn Nhà / Công ty / một nơi yêu thích (app tính tuyến và dẫn đường tới đó).
        case navigate(SavedPlace)
    }

    public static let menuTimeout: TimeInterval = 8
    public static let noteDuration: TimeInterval = 2.5
    public static let menuVisibleRows = 4
    public static let doublePressWindow: TimeInterval = 0.4
    public static let wheelDuration: TimeInterval = 0.6
    public static let welcomeDuration: TimeInterval = 2.0
    public static let zoomScales: [Double] = [0.22, 0.4, 0.6, 0.85, 1.3, 2.0]
    public static let zoomLabels = ["2 km", "1 km", "600 m", "400 m", "250 m", "150 m"]
    public static let defaultZoom = 3

    // Dữ liệu app đưa vào
    public var nav: NavInfo?
    public var music: MusicInfo?
    public var vehicle = VehicleInfo()
    public var weather: WeatherInfo?
    /// Chữ thanh dưới ở trang chủ (ODO / TRIP 1 / TRIP 2 / OIL do app tính).
    public var homeBarText = ""
    /// Nhà, Công ty, Yêu thích (app lưu, đưa vào đây để menu bản đồ dùng).
    public var places = SavedPlaces()
    /// Tên người dùng hiện ở màn chào (rỗng: chỉ có lời chào).
    public var userName = ""
    /// Tắt: `showWelcome` bỏ màn chào và vào thẳng Home.
    public var greetingEnabled = true
    /// Ánh màu nhẹ ở mép khung theo màu trang (bật/tắt trong Cài đặt).
    public var edgeGlow = true

    // Trạng thái
    public private(set) var rotation = 1          // bước bánh xe, không chia dư (để xoay vòng mượt)
    private var rotationFrom = 1.0
    private var rotationAt: TimeInterval = -100
    /// Bản đồ hiện ngay khi đang ở trang Bản đồ (không còn màn bìa).
    public var mapOpen: Bool { page == .map }
    /// Lần cuối vào/ra trang Bản đồ (cho hiệu ứng bánh xe trượt ra/vào).
    public private(set) var mapToggledAt: TimeInterval = -100
    public private(set) var zoom = DashUI.defaultZoom
    public private(set) var volumeMode = false
    public var volume = 60
    public private(set) var welcomeStart: TimeInterval?
    private var mapHintUntil: TimeInterval = -100
    private var zoomHintUntil: TimeInterval = -100
    private var volumeUntil: TimeInterval = -100
    /// Menu bản đồ (3 lần bấm ở trang Bản đồ); nil khi đóng.
    public private(set) var menu: MapMenu?
    public private(set) var menuChangedAt: TimeInterval = -100
    private var menuUntil: TimeInterval = -100
    private var noteText = ""
    private var noteUntil: TimeInterval = -100
    private var pending: (button: Button, count: Int, at: TimeInterval)?
    public private(set) var flash: (target: FlashTarget, at: TimeInterval)?
    public enum FlashTarget: Equatable { case next, previous, play }

    public init() {}

    public var page: Page { Page(rawValue: ((rotation % 3) + 3) % 3)! }

    // MARK: - Nút

    public func press(_ button: Button, now: TimeInterval) -> [Action] {
        if inWelcome(now) { return [] }
        switch button {
        case .enter, .enterHold:
            return []

        case .up, .down:
            let dir = button == .up ? -1 : 1
            if menu != nil { menuUntil = now + Self.menuTimeout }
            if volumeMode {
                volume = max(0, min(100, volume - dir * 10))
                volumeUntil = now + 3
                return [.volume(-dir * 10)]
            }
            var actions: [Action] = []
            var count = 1
            if let p = pending {
                if p.button == button && now - p.at <= Self.doublePressWindow {
                    count = p.count + 1
                } else {
                    actions += resolve(p, now: now)       // lần bấm trước đã chốt (khác nút hoặc quá 0,4 s)
                }
            }
            if count >= 3 {
                pending = nil
                actions += resolve((button: button, count: count, at: now), now: now)
            } else {
                pending = (button: button, count: count, at: now)
            }
            return actions

        case .home:
            pending = nil
            if menu != nil { menuBack(now: now); return [] }
            if volumeMode { volumeMode = false; return [] }
            let delta = Page.home.rawValue - page.rawValue          // -1, 0, +1 (chỉ có 3 trang)
            if delta != 0 { rotate(by: delta, now: now) }
            return []
        }
    }

    /// Gọi định kỳ: chốt lần bấm sau 0,4 s, đóng âm lượng sau 3 s, về Home sau khi báo tới nơi.
    public func tick(now: TimeInterval) -> [Action] {
        var actions: [Action] = []
        if let p = pending, now - p.at > Self.doublePressWindow {
            pending = nil
            actions += resolve(p, now: now)
        }
        if volumeMode && now > volumeUntil { volumeMode = false }
        if menu != nil && now > menuUntil { closeMenu(now: now) }
        if let a = arrivedAt, now - a >= Self.arrivalDuration {
            arrivedAt = nil
            if page != .home { rotate(by: Page.home.rawValue - page.rawValue, now: now) }
        }
        return actions
    }

    /// Chốt một chuỗi bấm `count` lần của `button` theo trang (hoặc menu) hiện tại. Tối đa 3 lần (đủ 3 thì chốt ngay).
    private func resolve(_ p: (button: Button, count: Int, at: TimeInterval), now: TimeInterval) -> [Action] {
        let up = p.button == .up
        let dir = up ? -1 : 1
        if menu != nil { return resolveMenu(up: up, count: p.count, now: now) }
        switch page {
        case .home:
            switch p.count {
            case 1: return [.nextPhoto]
            case 2:
                rotate(by: dir, now: now)
                return []
            default: return []
            }
        case .music:
            switch p.count {
            case 1:
                flash = (up ? FlashTarget.next : FlashTarget.previous, now)
                return [up ? Action.nextTrack : Action.previousTrack]
            case 2:
                rotate(by: dir, now: now)
                return []
            default:
                if up {
                    volumeMode = true
                    volumeUntil = now + 3
                    return []
                }
                flash = (FlashTarget.play, now)
                return [.togglePlay]
            }
        case .map:
            switch p.count {
            case 1:
                setZoom(zoom - dir, now: now)       // UP phóng to, DOWN thu nhỏ
                return []
            case 2:
                rotate(by: dir, now: now)           // UP về Home, DOWN sang Nhạc
                return []
            default:
                setMenu(MapMenu(level: .main, index: 0), now: now)
                return []
            }
        }
    }

    /// Đồng hồ vừa cho hiện màn hình app (lệnh 55 lần đầu): màn chào 2 s rồi vào Home.
    /// `greetingEnabled == false`: bỏ màn chào, vào thẳng Home (hiệu ứng trượt vào chạy ngay).
    public func showWelcome(now: TimeInterval) {
        welcomeStart = greetingEnabled ? now : now - Self.welcomeDuration
        mapToggledAt = -100
        volumeMode = false
        pending = nil
        menu = nil
        menuChangedAt = now
        if page != .home { rotation += Page.home.rawValue - page.rawValue; rotationFrom = Double(rotation) }
    }

    /// Bắt đầu dẫn đường (chia sẻ từ Google Maps): xoay sang Bản đồ, hiện bản đồ ngay.
    public func startNavigation(_ info: NavInfo, now: TimeInterval) {
        nav = info
        arrivedAt = nil
        pending = nil
        menu = nil
        menuChangedAt = now
        if page != .map {
            rotate(by: Page.map.rawValue - page.rawValue, now: now)
        } else {
            zoom = Self.defaultZoom
            mapHintUntil = now + 3
        }
    }

    public static let arrivalDuration: TimeInterval = 4
    public private(set) var arrivedAt: TimeInterval?
    public private(set) var arrivedDestination = ""

    /// Tới nơi: hiện "Đã tới nơi" 4 s, bỏ chuyến đi, rồi tự về trang chủ (gọi `tick`).
    public func arrive(now: TimeInterval) {
        arrivedDestination = nav?.destination ?? ""
        arrivedAt = now
        nav = nil
        if menu != nil { pending = nil; closeMenu(now: now) }
    }

    public func showingArrival(_ now: TimeInterval) -> Bool {
        arrivedAt.map { now - $0 < Self.arrivalDuration } ?? false
    }

    public func cancelNavigation() {
        nav = nil
    }

    // MARK: - Menu bản đồ

    /// Các dòng của menu đang mở (rỗng nếu menu đóng).
    public func menuItems() -> [MapMenu.Item] {
        guard let m = menu else { return [] }
        switch m.level {
        case .favorites:
            var items = [MapMenu.Item(kind: .back, label: "Quay lại", sub: nil, icon: .back)]
            if places.favs.isEmpty {
                items.append(MapMenu.Item(kind: .empty, label: "Chưa có yêu thích", sub: nil, icon: .star, off: true))
            } else {
                for (i, f) in places.favs.enumerated() {
                    items.append(MapMenu.Item(kind: .favorite(i), label: f.name, sub: f.sub, icon: .star))
                }
            }
            return items
        case .main:
            var items: [MapMenu.Item] = []
            if nav != nil {
                items.append(MapMenu.Item(kind: .stop, label: "Dừng chỉ đường", sub: nil, icon: .stop, danger: true))
            }
            items.append(MapMenu.Item(kind: .home, label: "Về nhà", sub: places.home?.sub ?? "Chưa đặt", icon: .home,
                                      off: places.home == nil))
            items.append(MapMenu.Item(kind: .work, label: "Đến công ty", sub: places.work?.sub ?? "Chưa đặt", icon: .work,
                                      off: places.work == nil))
            items.append(MapMenu.Item(kind: .favorites, label: "Yêu thích",
                                      sub: places.favs.isEmpty ? "Chưa có" : "\(places.favs.count) nơi", icon: .star,
                                      chevron: true))
            return items
        }
    }

    /// Dòng đầu tiên trong cửa sổ 4 dòng nhìn thấy (dòng chọn nằm thứ 2 khi cuộn).
    public static func menuWindowStart(index: Int, count: Int) -> Int {
        max(0, min(count - menuVisibleRows, index - 1))
    }

    private func setMenu(_ m: MapMenu?, now: TimeInterval) {
        menu = m
        menuChangedAt = now
        menuUntil = now + Self.menuTimeout
    }

    private func closeMenu(now: TimeInterval) {
        menu = nil
        menuChangedAt = now
    }

    private func setNote(_ text: String, now: TimeInterval) {
        noteText = text
        noteUntil = now + Self.noteDuration
    }

    /// Trong menu: 1 lần UP/DOWN chọn (xoay vòng), 2 lần xác nhận, 3 lần không làm gì.
    private func resolveMenu(up: Bool, count: Int, now: TimeInterval) -> [Action] {
        guard let m = menu else { return [] }
        switch count {
        case 1:
            let n = menuItems().count
            guard n > 0 else { return [] }
            var next = m
            next.index = (((m.index + (up ? -1 : 1)) % n) + n) % n
            setMenu(next, now: now)
            return []
        case 2:
            return selectMenuItem(now: now)
        default:
            return []
        }
    }

    private func menuBack(now: TimeInterval) {
        if let m = menu, m.level == .favorites {
            setMenu(MapMenu(level: .main, index: 0), now: now)
        } else {
            closeMenu(now: now)
        }
    }

    private func selectMenuItem(now: TimeInterval) -> [Action] {
        let items = menuItems()
        guard let m = menu, m.index >= 0, m.index < items.count else { return [] }
        switch items[m.index].kind {
        case .stop:
            nav = nil
            closeMenu(now: now)
            setNote("Đã dừng chỉ đường", now: now)
            return [.stopNavigation]
        case .home:
            return go(places.home, missing: "Chưa đặt nhà", now: now)
        case .work:
            return go(places.work, missing: "Chưa đặt công ty", now: now)
        case .favorites:
            setMenu(MapMenu(level: .favorites, index: places.favs.isEmpty ? 0 : 1), now: now)
            return []
        case .favorite(let i):
            guard places.favs.indices.contains(i) else { return [] }
            return go(places.favs[i], missing: "", now: now)
        case .back:
            menuBack(now: now)
            return []
        case .empty:
            return []
        }
    }

    private func go(_ place: SavedPlace?, missing: String, now: TimeInterval) -> [Action] {
        closeMenu(now: now)
        guard let p = place else {
            setNote(missing, now: now)
            return []
        }
        setNote("Đi tới \(p.name)", now: now)
        return [.navigate(p)]
    }

    private func rotate(by steps: Int, now: TimeInterval) {
        let wasMap = page == .map
        rotationFrom = wheelPosition(now: now)
        rotation += steps
        rotationAt = now
        volumeMode = false
        if (page == .map) != wasMap { mapToggledAt = now }
        if page == .map {
            zoom = Self.defaultZoom
            mapHintUntil = now + 3
        }
    }

    private func setZoom(_ z: Int, now: TimeInterval) {
        zoom = max(0, min(Self.zoomScales.count - 1, z))
        zoomHintUntil = now + 2
    }

    // MARK: - Đọc cho bộ vẽ

    public func inWelcome(_ now: TimeInterval) -> Bool {
        guard let s = welcomeStart else { return false }
        return now - s < Self.welcomeDuration
    }

    /// Thời gian từ lúc hết màn chào (cho hiệu ứng vào Home), nil nếu chưa từng chào.
    public func sinceWelcomeEnd(_ now: TimeInterval) -> TimeInterval? {
        welcomeStart.map { now - $0 - Self.welcomeDuration }
    }

    /// Vị trí bánh xe (số thực) có làm mượt, chậm dần cuối.
    public func wheelPosition(now: TimeInterval) -> Double {
        let k = min(1, max(0, (now - rotationAt) / Self.wheelDuration))
        let e = 1 - pow(1 - k, 3)
        return rotationFrom + (Double(rotation) - rotationFrom) * e
    }

    /// Còn hiệu ứng đang chạy (cần gửi khung liên tục) không.
    public func isAnimating(now: TimeInterval) -> Bool {
        now - rotationAt < Self.wheelDuration + 0.05
            || now - mapToggledAt < 0.7
            || (welcomeStart.map { now - $0 < Self.welcomeDuration + 1.2 } ?? false)
            || (flash.map { now - $0.at < 0.45 } ?? false)
            || menu != nil
            || now - menuChangedAt < 0.6
    }

    public func bottomBarText(now: TimeInterval) -> String {
        if inWelcome(now) { return "Chúc thượng lộ bình an" }
        if showingArrival(now) { return "Đã tới \(arrivedDestination)" }
        if let n = nav, n.distanceToTurnM < 100, !mapOpen { return n.maneuver.prompt(n.nextStreet) }
        switch page {
        case .music: return volumeMode ? "Âm lượng · +/- chỉnh" : "+/- đổi bài · 3×+ âm lượng · 3×- phát/dừng"
        case .home:
            if let street = nav?.currentStreet, !street.isEmpty { return street }   // đang chỉ đường: tên đường thay cho ODO/Trip
            return homeBarText
        case .map:
            if menu != nil { return "+/- lướt · đúp: chọn · Home thoát" }
            if now < noteUntil { return noteText }
            if now < zoomHintUntil { return "Thu phóng · \(Self.zoomLabels[zoom])" }
            if now < mapHintUntil { return "+/- thu phóng · 3 lần: menu" }
            return nav?.currentStreet ?? "Chia sẻ vị trí từ Google Maps"
        }
    }

    // MARK: - Định dạng dùng chung

    /// Làm tròn khoảng cách: > 1 km: 0,1 km · 100 m – 1 km: 50 m · < 100 m: 10 m.
    public static func formatDistance(_ meters: Double) -> (value: String, unit: String) {
        let m50 = (meters / 50).rounded() * 50
        if meters >= 1000 || m50 >= 1000 {
            return (String(format: "%.1f", (meters / 100).rounded() / 10).replacingOccurrences(of: ".", with: ","), "km")
        }
        if meters >= 100 { return ("\(Int(m50))", "m") }
        return ("\(Int((meters / 10).rounded() * 10))", "m")
    }

    /// Mức chú ý theo khoảng cách tới chỗ rẽ: ≥ 500 m bình thường, 100–500 m vàng, < 100 m đỏ.
    public static func turnUrgency(_ meters: Double) -> Level {
        meters < 100 ? .bad : meters < 500 ? .warn : .normal
    }

    public enum Level: Equatable { case normal, warn, bad }

    public static func coolantLevel(_ c: Int) -> Level { c >= 110 ? .bad : c >= 103 ? .warn : .normal }
    public static func batteryLevel(_ v: Double) -> Level {
        (v < 11.8 || v > 15.0) ? .bad : (v < 12.2 || v > 14.6) ? .warn : .normal
    }

    public static func greeting(hour: Int) -> String {
        hour < 11 ? "Chào buổi sáng" : hour < 14 ? "Chào buổi trưa" : hour < 18 ? "Chào buổi chiều" : "Chào buổi tối"
    }
}

/// Một nơi đã lưu (Nhà, Công ty hoặc yêu thích).
public struct SavedPlace: Equatable, Codable, Identifiable {
    public var id: String { name + sub }
    public var name: String
    public var sub: String
    public var lat: Double
    public var lon: Double
    public init(name: String, sub: String, lat: Double, lon: Double) {
        self.name = name
        self.sub = sub
        self.lat = lat
        self.lon = lon
    }
    private enum CodingKeys: String, CodingKey { case name, sub, lat, lon }
}

public struct SavedPlaces: Equatable, Codable {
    public var home: SavedPlace?
    public var work: SavedPlace?
    public var favs: [SavedPlace]
    public init(home: SavedPlace? = nil, work: SavedPlace? = nil, favs: [SavedPlace] = []) {
        self.home = home
        self.work = work
        self.favs = favs
    }
}

/// Trạng thái menu bản đồ (3 lần bấm ở trang Bản đồ). Dòng hiển thị lấy từ `DashUI.menuItems()`.
public struct MapMenu: Equatable {
    public enum Level: Equatable { case main, favorites }
    public enum Icon: Equatable { case stop, home, work, star, back }
    public enum Kind: Equatable { case stop, home, work, favorites, favorite(Int), back, empty }

    public struct Item: Equatable {
        public var kind: Kind
        public var label: String
        public var sub: String?
        public var icon: Icon
        /// Mờ (chưa đặt / chưa có).
        public var off: Bool
        /// Đỏ (Dừng chỉ đường).
        public var danger: Bool
        /// Có mũi tên › (mở danh sách con).
        public var chevron: Bool
        public init(kind: Kind, label: String, sub: String?, icon: Icon, off: Bool = false, danger: Bool = false,
                    chevron: Bool = false) {
            self.kind = kind
            self.label = label
            self.sub = sub
            self.icon = icon
            self.off = off
            self.danger = danger
            self.chevron = chevron
        }
    }

    public var level: Level
    public var index: Int
    public init(level: Level, index: Int) {
        self.level = level
        self.index = index
    }
}

public struct NavInfo: Equatable {
    public enum Maneuver: String, CaseIterable {
        case right, left, straight, uturn, roundabout
        public func prompt(_ street: String) -> String {
            switch self {
            case .right: return "Rẽ phải vào \(street)"
            case .left: return "Rẽ trái vào \(street)"
            case .straight: return "Đi thẳng vào \(street)"
            case .uturn: return "Quay đầu"
            case .roundabout: return "Vào vòng xoay, ra \(street)"
            }
        }
    }
    public var maneuver: Maneuver
    public var distanceToTurnM: Double
    public var nextStreet: String
    public var currentStreet: String
    public var destination: String
    public var remainingKm: Double
    public var eta: Date
    public var speedLimit: Int?

    public init(maneuver: Maneuver, distanceToTurnM: Double, nextStreet: String, currentStreet: String,
                destination: String, remainingKm: Double, eta: Date, speedLimit: Int? = nil) {
        self.maneuver = maneuver
        self.distanceToTurnM = distanceToTurnM
        self.nextStreet = nextStreet
        self.currentStreet = currentStreet
        self.destination = destination
        self.remainingKm = remainingKm
        self.eta = eta
        self.speedLimit = speedLimit
    }
}

public struct MusicInfo: Equatable {
    public var title: String
    public var artist: String
    public var duration: TimeInterval
    public var position: TimeInterval
    public var playing: Bool
    public init(title: String, artist: String, duration: TimeInterval, position: TimeInterval, playing: Bool) {
        self.title = title
        self.artist = artist
        self.duration = duration
        self.position = position
        self.playing = playing
    }
}

public struct VehicleInfo: Equatable {
    public var coolantC: Int?
    public var batteryV: Double?
    public init(coolantC: Int? = nil, batteryV: Double? = nil) {
        self.coolantC = coolantC
        self.batteryV = batteryV
    }
}

public struct WeatherInfo: Equatable {
    public enum Kind: String { case sun, cloud, rain, storm, night }
    public var tempC: Int
    public var kind: Kind
    public var label: String
    public var place: String
    public init(tempC: Int, kind: Kind, label: String, place: String) {
        self.tempC = tempC
        self.kind = kind
        self.label = label
        self.place = place
    }
}
