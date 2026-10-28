import CoreGraphics
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
    @Published var simulateNav = false { didSet { applySimulatedNav() } }

    let ui = DashUI()
    let photos = PhotoStore()
    let music = MusicController()
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

    func start() {
        ui.homeBarText = "ODO -- km"            // Link B (ODO) chưa làm
        photos.load()
        music.requestAccess()
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

    func replayWelcome() {
        ui.showWelcome(now: now)
        dirty = true
    }

    private func perform(_ actions: [DashUI.Action]) {
        for a in actions {
            switch a {
            case .nextTrack: music.next()
            case .previousTrack: music.previous()
            case .togglePlay: music.togglePlay()
            case .volume: break        // iOS không cho app tự chỉnh âm lượng hệ thống; chỉ hiện trên đồng hồ
            case .nextPhoto: photos.next(now: now)
            }
            dirty = true
        }
    }

    private func applySimulatedNav() {
        ui.nav = simulateNav
            ? NavInfo(maneuver: .right, distanceToTurnM: 450, nextStreet: "Lê Lợi", currentStreet: "Nguyễn Huệ",
                      destination: "Chợ Bến Thành", remainingKm: 7, eta: Date().addingTimeInterval(16 * 60), speedLimit: 60)
            : nil
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
    }

    private func close(_ why: String) {
        for stream in [ea?.inputStream as Stream?, ea?.outputStream as Stream?].compactMap({ $0 }) {
            stream.close()
            stream.remove(from: .main, forMode: .default)
        }
        ea = nil
        status = why
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
            case .showFrames:
                status = "Đồng hồ đang hiện màn hình app"
                if wasShowing {
                    press(.home, source: "xe (55 lần nữa = Home?)")
                } else {
                    ui.showWelcome(now: now)
                }
                dirty = true
            case .pause:
                status = "Đồng hồ tạm dừng (rời màn hình app / tắt máy)"
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
        let wantFrame = session.canSendFrame && outBuffer.isEmpty && (animating || dirty || t - lastFrameAt > keepAlive)
        let wantPreview = t - lastPreviewAt > (animating ? 0.1 : 0.5)
        guard wantFrame || wantPreview else { return }

        var input = DashRenderer.Input()
        input.width = session.screen.width
        input.height = session.screen.height
        let p = photos.current(now: t)
        input.photo = p.photo
        input.previousPhoto = p.previous
        input.photoFade = p.fade
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
