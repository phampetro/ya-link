import DashCore
import ExternalAccessory
import Foundation
import UIKit

/// Kết nối Link A qua ExternalAccessory (`com.garmin.navilite.data`) và chạy LinkASession.
/// Bản "dò xe" đầu tiên: bắt tay, hiện một màn hình thử, và GHI LOG mọi khung xe gửi về
/// (để kiểm chứng trên xe: nút Enter, ấn giữ, Home khi đang ở màn hình app — chưa có trong tài liệu).
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
    @Published private(set) var lastRoundTripMs: Int?
    @Published private(set) var log: [LogLine] = []

    private let session = LinkASession()
    private var ea: EASession?
    private var reader = FrameReader()
    private var outBuffer: [UInt8] = []
    private var timer: Timer?
    private let started = Date()
    private var dirty = true
    private var lastFrameAt: TimeInterval = -10
    private var buttonCount = 0

    private var now: TimeInterval { Date().timeIntervalSince(started) }

    func start() {
        session.bottomBarText = "Ya Link · thử kết nối"
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(accessoryChanged), name: .EAAccessoryDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(accessoryChanged), name: .EAAccessoryDidDisconnect, object: nil)
        EAAccessoryManager.shared().registerForLocalNotifications()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        openIfAvailable()
    }

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
        let r = session.receive(frame, now: now)
        if frame.command != 80 && frame.command != 65 { add("← \(frame)") }   // ACK và tốc độ quá dày, không ghi
        send(r.send)
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
                dirty = true
            case .pause:
                status = "Đồng hồ tạm dừng (rời màn hình app / tắt máy)"
            case .buttonUp, .buttonDown:
                buttonCount += 1
                lastButton = "\(e == .buttonUp ? "UP" : "DOWN") · lần \(buttonCount) · \(String(format: "%.2f", now)) s"
                add("NÚT \(e == .buttonUp ? "UP" : "DOWN")")
                dirty = true
            case .speed(let v):
                if speed != v { speed = v; dirty = true }
            case .ack(_, let rtt):
                lastRoundTripMs = rtt
            case .other(let m):
                add("lệnh khác: \(m)")
                dirty = true
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
        send(session.tick(now: now).send)
        // Màn hình thử: gửi lại khi có gì đổi, hoặc 2 s một lần để giữ kết nối
        guard session.canSendFrame, outBuffer.isEmpty, dirty || now - lastFrameAt > 2 else { return }
        let jpeg = TestScreen.render(width: session.screen.width, height: session.screen.height,
                                     speed: speed, lastButton: lastButton, frames: framesSent)
        if let frame = session.makeMapFrame(jpeg: jpeg, now: now) {
            send([frame])
            framesSent += 1
            lastFrameAt = now
            dirty = false
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
