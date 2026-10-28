import CoreGraphics
import CoreLocation
import DashCore
import DashRender
import ExternalAccessory
import Foundation
import UIKit

/// Kết nối Link A qua ExternalAccessory (`com.garmin.navilite.data`), chạy LinkASession,
/// điều khiển giao diện (DashUI) bằng nút trên tay lái và gửi khung hình do DashRenderer vẽ.
/// Vẫn ghi log mọi khung xe gửi về để kiểm chứng nút Enter / ấn giữ / Home trên xe.
@MainActor
final class DashLink: NSObject, ObservableObject {
    static let protocolA = "com.garmin.navilite.data"

    /// Trạng thái kết nối với đồng hồ (hiện ở đầu tab Đồng hồ).
    enum Phase: Equatable { case none, handshake, ready, showing }

    struct LogLine: Identifiable {
        let id = UUID()
        let ms: Int
        let text: String
    }

    @Published private(set) var status = "Chưa thấy xe. Bật khoá điện, tắt app Y-Connect."
    @Published private(set) var partNumber = "—"
    @Published private(set) var speed: Int?
    @Published private(set) var lastButton = "—"
    @Published private(set) var framesSent = 0
    @Published private(set) var lastFrameKB: Double = 0
    @Published private(set) var lastRoundTripMs: Int?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var preview: UIImage?
    /// Chữ thanh dưới hiện tại (để màn xem trước vẽ giống đồng hồ).
    @Published private(set) var barText = ""
    @Published private(set) var phase: Phase = .none
    @Published private(set) var accessoryName = "NMAX Tech MAX"

    let ui = DashUI()
    let photos = PhotoStore()
    let music = MusicController()
    let settings = AppSettings()
    let location = LocationService()
    let ccu = CCULink()
    let history = HistoryStore()
    let toaster = Toaster()
    private(set) var navigation: NavigationController!
    private var lastWeatherAt: Date = .distantPast
    private var lastWeatherPlace = ""
    private var lastOdoKm: Double?
    private var lastFuelL: Double?
    private let renderer = DashRenderer()
    private let session = LinkASession()
    private var ea: EASession?
    private var reader = FrameReader()
    private var outBuffer: [UInt8] = []
    private var timer: Timer?
    private let started = Date()
    private var dirty = true
    private var lastFrameAt: TimeInterval = -10
    private var lastPreviewAt: TimeInterval = -10
    private var lastMusicPoll: TimeInterval = -10
    private var lastBarSent: String?
    private var buttonCount = 0

    private var now: TimeInterval { Date().timeIntervalSince(started) }

    override init() {
        super.init()
        let t0 = started
        navigation = NavigationController(ui: ui, settings: settings, clock: { Date().timeIntervalSince(t0) })
        navigation.onChange = { [weak self] in self?.dirty = true }
        navigation.onToast = { [weak self] text in self?.toaster.show(text) }
        settings.onProfileChange = { [weak self] in self?.pushProfile() }
    }

    /// Tên, lời chào và địa điểm đã lưu → giao diện đồng hồ (màn chào, menu giữ Enter).
    private func pushProfile() {
        ui.userName = settings.userName
        ui.greetingEnabled = settings.greetingEnabled
        ui.places = settings.places
        dirty = true
    }

    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        pushProfile()
        ui.homeBarText = settings.odometer.barText(odoKm: nil)
        photos.load()
        music.requestAccess()
        location.onUpdate = { [weak self] loc in self?.locationUpdated(loc) }
        location.start()
        ccu.onLog = { [weak self] line in self?.add("CCU: \(line)") }
        ccu.start()
        // Chỉ để chụp ảnh giao diện trên trình giả lập (CI)
        let env = ProcessInfo.processInfo.environment
        if env["YALINK_NAV"] == "1" { debugShowFakeTurn() }
        if env["YALINK_CONFIRM"] == "1" { navigation.debugShowConfirm() }
        if env["YALINK_SEED"] == "1" { history.seedDemo() }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(accessoryChanged), name: .EAAccessoryDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(accessoryChanged), name: .EAAccessoryDidDisconnect, object: nil)
        EAAccessoryManager.shared().registerForLocalNotifications()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        openIfAvailable()
    }

    // MARK: - Nút (từ xe hoặc từ màn xem trước)

    func press(_ button: DashUI.Button, source: String = "xem trước") {
        let actions = ui.press(button, now: now)
        add("\(source): \(button)")
        perform(actions)
        dirty = true
    }

    /// Xem thử màn chào trên màn hình xem trước (và đồng hồ nếu đang hiện); phát cả khi lời chào đang tắt.
    func replayWelcome() {
        ui.greetingEnabled = true
        ui.userName = settings.userName
        ui.showWelcome(now: now)
        dirty = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            self?.pushProfile()
        }
    }

    private func perform(_ actions: [DashUI.Action]) {
        for a in actions {
            switch a {
            case .stopNavigation: navigation.stop()
            case .navigate(let p): navigation.navigate(to: p)
            case .nextTrack: music.next()
            case .previousTrack: music.previous()
            case .togglePlay: music.togglePlay()
            case .volume: break        // iOS không cho app tự chỉnh âm lượng hệ thống; chỉ hiện trên đồng hồ
            case .nextPhoto: photos.next(now: now)
            }
            dirty = true
        }
    }

    private func locationUpdated(_ loc: CLLocation) {
        navigation.locationUpdated(loc)
        if ui.nav != nil || ui.mapOpen { dirty = true }
        refreshWeatherIfNeeded(loc)
    }

    /// Thời tiết: hỏi lại sau 10 phút, hoặc khi đổi khu vực.
    private func refreshWeatherIfNeeded(_ loc: CLLocation) {
        let place = location.placeName
        guard Date().timeIntervalSince(lastWeatherAt) > 600 || (place != lastWeatherPlace && !place.isEmpty) else { return }
        lastWeatherAt = Date()
        lastWeatherPlace = place
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        Task {
            if let w = try? await fetchWeather(lat: lat, lon: lon, place: place) {
                ui.weather = w
                dirty = true
            }
        }
    }

    /// Dữ liệu xe từ Link B vào giao diện; ODO đổi thì cập nhật chữ thanh dưới trang chủ.
    private func syncVehicle() {
        let d = ccu.data
        let coolant = d.coolantC, battery = d.batteryV
        if ui.vehicle.coolantC != coolant || ui.vehicle.batteryV != battery {
            ui.vehicle = VehicleInfo(coolantC: coolant, batteryV: battery)
            dirty = true
        }
        if d.odoKm != lastOdoKm || d.fuelUsedL != lastFuelL {
            lastFuelL = d.fuelUsedL
            history.record(odoKm: d.odoKm, fuelUsedL: d.fuelUsedL)
        }
        if d.odoKm != lastOdoKm {
            lastOdoKm = d.odoKm
            if let odo = d.odoKm { settings.odometer.sync(odoKm: odo) }
            ui.homeBarText = settings.odometer.barText(odoKm: d.odoKm)
        }
    }

    func resetTrip(_ n: Int) {
        guard let odo = ccu.data.odoKm else { return }
        if n == 1 { settings.odometer.resetTrip1(odoKm: odo) } else { settings.odometer.resetTrip2(odoKm: odo) }
        ui.homeBarText = settings.odometer.barText(odoKm: odo)
        dirty = true
    }

    func oilChanged() {
        guard let odo = ccu.data.odoKm else { return }
        settings.odometer.oilChanged(odoKm: odo)
        ui.homeBarText = settings.odometer.barText(odoKm: odo)
        dirty = true
    }

    func refreshBarText() {
        ui.homeBarText = settings.odometer.barText(odoKm: ccu.data.odoKm)
        dirty = true
    }

    /// Mở từ tiện ích Chia sẻ: yalink://share?text=…
    func handleOpen(_ url: URL) {
        guard url.scheme == "yalink",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value
        else { return }
        navigation.handleShared(text: text)
    }

    /// Dự phòng khi tiện ích không mở được app: nó chép chữ vào bộ nhớ tạm.
    func checkPasteboardForShare() {
        guard navigation.state == .idle, UIPasteboard.general.hasStrings,
              let s = UIPasteboard.general.string,
              s.contains("goo.gl/maps") || s.contains("maps.app.goo.gl") || s.contains("google.com/maps") else { return }
        UIPasteboard.general.string = ""
        navigation.handleShared(text: s)
    }

    /// Chỉ để chụp ảnh giao diện trên CI (YALINK_NAV=1): giả một chặng rẽ trên màn xem trước.
    private func debugShowFakeTurn() {
        ui.nav = NavInfo(maneuver: .right, distanceToTurnM: 450, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                         destination: "Chợ Bến Thành", remainingKm: 7, eta: Date().addingTimeInterval(16 * 60), speedLimit: 60)
        dirty = true
    }

    // MARK: - Kết nối

    @objc private func accessoryChanged(_ note: Notification) {
        Task { @MainActor in
            if let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory, note.name == .EAAccessoryDidDisconnect {
                add("ngắt: \(acc.name)")
                close("Xe đã ngắt kết nối")
            }
            openIfAvailable()
        }
    }

    private func openIfAvailable() {
        guard ea == nil else { return }
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(Self.protocolA) }) else { return }
        add("thấy: \(acc.name) · \(acc.manufacturer) · \(acc.protocolStrings.joined(separator: ", "))")
        accessoryName = acc.name.isEmpty ? "NMAX Tech MAX" : acc.name
        guard let s = EASession(accessory: acc, forProtocol: Self.protocolA) else {
            status = "Không mở được kết nối. App khác đang giữ? Tắt Y-Connect rồi tắt/mở khoá điện."
            return
        }
        ea = s
        reader = FrameReader()
        outBuffer = []
        lastBarSent = nil
        for stream in [s.inputStream as Stream?, s.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        status = "Đã nối \(acc.name), đang bắt tay…"
        phase = .handshake
    }

    private func close(_ why: String) {
        for stream in [ea?.inputStream as Stream?, ea?.outputStream as Stream?].compactMap({ $0 }) {
            stream.close()
            stream.remove(from: .main, forMode: .default)
        }
        ea = nil
        status = why
        phase = .none
    }

    // MARK: - Nhận

    fileprivate func readAvailable() {
        guard let input = ea?.inputStream else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            for frame in reader.append(Array(buf[0..<n])) { handle(frame) }
        }
    }

    private func handle(_ frame: Frame) {
        let wasShowing = session.showing
        let r = session.receive(frame, now: now)
        if frame.command != 80 && frame.command != 65 { add("← \(frame)") }   // ACK và tốc độ quá dày, không ghi
        send(r.send)
        if r.send.contains(where: { $0.command == 3 }) { lastBarSent = session.bottomBarText }
        for e in r.events {
            switch e {
            case .connected(let serial):
                status = "Bắt tay… (serial \(serial.prefix(4))…)"
            case .authenticated(let part, let w, let h):
                partNumber = "\(part) · \(w)×\(h)"
                status = "Sẵn sàng. Bấm HOME trên tay lái để hiện màn hình app."
                add("xác thực xong: \(part) \(w)×\(h)")
                phase = .ready
            case .showFrames:
                status = "Đồng hồ đang hiện màn hình app"
                phase = .showing
                if wasShowing {
                    press(.home, source: "xe (55 lần nữa = Home?)")
                } else {
                    ui.showWelcome(now: now)
                }
                dirty = true
            case .pause:
                status = "Đồng hồ tạm dừng (rời màn hình app / tắt máy)"
                phase = .ready
            case .buttonUp, .buttonDown:
                buttonCount += 1
                let name = e == .buttonUp ? "UP" : "DOWN"
                lastButton = "\(name) · lần \(buttonCount) · \(String(format: "%.2f", now)) s"
                press(e == .buttonUp ? .up : .down, source: "xe")
            case .speed(let v):
                if speed != v { speed = v }
            case .ack(_, let rtt):
                lastRoundTripMs = rtt
            case .other(let m):
                add("LỆNH KHÁC (ghi lại để dò nút Enter/giữ): \(m)")
            }
        }
    }

    // MARK: - Gửi

    private func send(_ frames: [Frame]) {
        for f in frames {
            if f.command != 0 { add("→ \(f)") }
            outBuffer += f.encoded()
        }
        flush()
    }

    fileprivate func flush() {
        guard let out = ea?.outputStream else { return }
        while !outBuffer.isEmpty && out.hasSpaceAvailable {
            let n = outBuffer.withUnsafeBufferPointer { out.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { break }
            outBuffer.removeFirst(n)
        }
    }

    private func onTick() {
        let t = now
        send(session.tick(now: t).send)
        perform(ui.tick(now: t))
        if photos.tick(now: t) { dirty = true }
        syncVehicle()
        if t - lastMusicPoll > 1 {
            lastMusicPoll = t
            let m = music.info
            if m != ui.music { ui.music = m; if ui.page == .music { dirty = true } }
        }

        // Chữ thanh dưới: chỉ gửi khi đổi (lệnh 3 nhỏ, không phải gửi lại cả khung)
        let bar = ui.bottomBarText(now: t)
        session.bottomBarText = bar
        if barText != bar { barText = bar }
        if session.showing && bar != lastBarSent {
            send([PhoneCommand.bottomBar(bar)])
            lastBarSent = bar
        }

        let animating = ui.isAnimating(now: t) || photos.isFading(now: t)
        let keepAlive: TimeInterval = ui.page == .music ? 1 : 2
        // Trang chủ chỉ cần tối đa 1 khung/giây; bản đồ đang mở thì gửi nhanh nhất có thể
        let minGap: TimeInterval = ui.mapOpen || animating ? 0 : 1
        let wantFrame = session.canSendFrame && outBuffer.isEmpty && t - lastFrameAt >= minGap
            && (animating || dirty || t - lastFrameAt > keepAlive)
        let wantPreview = t - lastPreviewAt > (animating ? 0.1 : 0.5)
        guard wantFrame || wantPreview else { return }

        var input = DashRenderer.Input()
        input.width = session.screen.width
        input.height = session.screen.height
        let p = photos.current(now: t)
        input.photo = p.photo
        input.previousPhoto = p.previous
        input.photoFade = p.fade
        if ui.mapOpen { input.map = navigation.mapScene() }
        guard let image = renderer.render(ui, now: t, input: input) else { return }

        if wantPreview {
            preview = UIImage(cgImage: image)
            lastPreviewAt = t
        }
        if wantFrame {
            let jpeg = ImageEncoder.jpeg(image, quality: 0.5)
            if let frame = session.makeMapFrame(jpeg: jpeg, now: t) {
                send([frame])
                framesSent += 1
                lastFrameKB = Double(jpeg.count) / 1024
                lastFrameAt = t
                dirty = false
            }
        }
    }

    // MARK: - Log

    private func add(_ text: String) {
        log.append(LogLine(ms: Int(now * 1000), text: text))
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    var logText: String {
        log.map { String(format: "%9.3f  ", Double($0.ms) / 1000) + $0.text }.joined(separator: "\n")
    }
}

extension DashLink: StreamDelegate {
    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        Task { @MainActor in
            switch eventCode {
            case .hasBytesAvailable: self.readAvailable()
            case .hasSpaceAvailable: self.flush()
            case .errorOccurred, .endEncountered: self.close("Mất kết nối với xe")
            default: break
            }
        }
    }
}
