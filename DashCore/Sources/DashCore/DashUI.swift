import Foundation

/// Trạng thái và luật điều khiển giao diện trên đồng hồ (theo mockup design/dash/home.html).
/// Không vẽ gì: bộ vẽ (DashRender) đọc trạng thái này. Mọi hàm nhận `now` để test được.
///
/// Đồng hồ xe nuốt Enter và giữ Enter: app chỉ nhận UP, DOWN và Home. Luật điều khiển (cửa sổ bấm nhiều lần 0,4 s):
///   Bánh xe menu: Nhạc (UP) · Home · Bản đồ (DOWN), xoay vòng. Home từ mọi trang về trang Home.
///   Home: 1 lần UP/DOWN xoay bánh xe · đúp UP hoặc DOWN đổi ảnh nền
///   Nhạc: 1 lần xoay · đúp UP bài sau · đúp DOWN bài trước · ba lần UP phát/dừng · ba lần DOWN chế độ âm lượng
///     (UP/DOWN ±10 % bấm là chỉnh ngay, tự đóng sau 3 s)
///   Bản đồ (hiện ngay khi chọn trang): 1 lần UP phóng to, DOWN thu nhỏ · đúp UP về Home · đúp DOWN sang Nhạc
/// `.enter` và `.enterHold` giữ lại cho khớp API nhưng không làm gì.
public final class DashUI {
    public enum Page: Int, CaseIterable { case music = 0, home = 1, map = 2 }
    public enum Button { case up, down, enter, enterHold, home }
    public enum Action: Equatable {
        case nextTrack, previousTrack, togglePlay, volume(Int), nextPhoto
        /// Không còn được phát ra (menu bản đồ do đồng hồ lo); giữ để code app còn biên dịch.
        case stopNavigation
        /// Không còn được phát ra; giữ để code app còn biên dịch.
        case navigate(SavedPlace)
    }

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
    /// Nhà, Công ty, Yêu thích (app lưu; DashUI không dùng).
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
            if count >= maxPresses(for: page) {
                pending = nil
                actions += resolve((button: button, count: count, at: now), now: now)
            } else {
                pending = (button: button, count: count, at: now)
            }
            return actions

        case .home:
            pending = nil
            volumeMode = false
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
        if let a = arrivedAt, now - a >= Self.arrivalDuration {
            arrivedAt = nil
            if page != .home { rotate(by: Page.home.rawValue - page.rawValue, now: now) }
        }
        return actions
    }

    /// Số lần bấm tối đa có nghĩa ở từng trang (đủ số này thì chốt ngay, khỏi chờ).
    private func maxPresses(for page: Page) -> Int {
        switch page {
        case .music: return 3
        case .home, .map: return 2
        }
    }

    /// Chốt một chuỗi bấm `count` lần của `button` theo trang hiện tại.
    private func resolve(_ p: (button: Button, count: Int, at: TimeInterval), now: TimeInterval) -> [Action] {
        let up = p.button == .up
        let dir = up ? -1 : 1
        switch page {
        case .home:
            if p.count >= 2 { return [.nextPhoto] }
            rotate(by: dir, now: now)
            return []
        case .music:
            switch p.count {
            case 1:
                rotate(by: dir, now: now)
                return []
            case 2:
                flash = (up ? FlashTarget.next : FlashTarget.previous, now)
                return [up ? Action.nextTrack : Action.previousTrack]
            default:
                if up {
                    flash = (FlashTarget.play, now)
                    return [.togglePlay]
                }
                volumeMode = true
                volumeUntil = now + 3
                return []
            }
        case .map:
            if p.count >= 2 {
                rotate(by: dir, now: now)       // đúp UP về Home, đúp DOWN sang Nhạc
            } else {
                setZoom(zoom - dir, now: now)
            }
            return []
        }
    }

    /// Đồng hồ vừa cho hiện màn hình app (lệnh 55 lần đầu): màn chào 2 s rồi vào Home.
    /// `greetingEnabled == false`: bỏ màn chào, vào thẳng Home (hiệu ứng trượt vào chạy ngay).
    public func showWelcome(now: TimeInterval) {
        welcomeStart = greetingEnabled ? now : now - Self.welcomeDuration
        mapToggledAt = -100
        volumeMode = false
        pending = nil
        if page != .home { rotation += Page.home.rawValue - page.rawValue; rotationFrom = Double(rotation) }
    }

    /// Bắt đầu dẫn đường (chia sẻ từ Google Maps): xoay sang Bản đồ, hiện bản đồ ngay.
    public func startNavigation(_ info: NavInfo, now: TimeInterval) {
        nav = info
        arrivedAt = nil
        pending = nil
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
    }

    public func showingArrival(_ now: TimeInterval) -> Bool {
        arrivedAt.map { now - $0 < Self.arrivalDuration } ?? false
    }

    public func cancelNavigation() {
        nav = nil
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
    }

    public func bottomBarText(now: TimeInterval) -> String {
        if inWelcome(now) { return "Chúc thượng lộ bình an" }
        if showingArrival(now) { return "Đã tới \(arrivedDestination)" }
        if let n = nav, n.distanceToTurnM < 100, !mapOpen { return n.maneuver.prompt(n.nextStreet) }
        switch page {
        case .music: return volumeMode ? "Âm lượng · ▲▼ chỉnh" : "Đúp ▲▼ đổi bài · Ba lần ▲ phát/dừng"
        case .home: return homeBarText
        case .map:
            if now < zoomHintUntil { return "Thu phóng · \(Self.zoomLabels[zoom])" }
            if now < mapHintUntil { return "▲▼ thu phóng · đúp ▲ thoát" }
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
