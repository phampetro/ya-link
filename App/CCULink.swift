import CoreBluetooth
import CoreLocation
import DashCore
import ExternalAccessory
import Foundation

/// Link B: đọc dữ liệu xe qua bộ CCU (docs/protocol/link-b-ccu.md).
/// 1. MFi `com.yconnect.data`: hỏi mã CCU + passkey, giữ phiên mở và đọc bỏ dữ liệu.
/// 2. BLE `YCCU_<mã>`: bật notify từng đặc tính một, ConnectAppId, AuthenticationV2 qua DDT V1, chờ `01 02 01`.
/// 3. Mỗi 10 s: khoá điện, danh sách ECU (tới khi có), dữ liệu xe 270, bộ đếm xăng. Trả lời ping.
/// Thiếu gì thì ghi log rồi chạy tiếp; logic byte nằm ở DashCore/CCUProtocol.swift.
@MainActor
final class CCULink: NSObject, ObservableObject {
    @Published private(set) var data = CCUVehicleData()
    /// Mã ECU của xe, lấy từ danh sách ECU xe trả về (không phải giá trị đoán).
    @Published private(set) var ecuId: UInt64?
    /// Câu tiếng Việt cho người dùng, ví dụ "Dữ liệu xe: đang chờ phản hồi (12 s)". Cập nhật mỗi giây.
    @Published private(set) var status: String = "Dữ liệu xe: đang kết nối…"
    /// Số gói nhận được từ CCU qua BLE (mọi đặc tính), để biết CCU có "nói" hay không.
    @Published private(set) var framesReceived = 0
    /// Mỗi bước đều gọi hàm này (app hiện trong log).
    var onLog: ((String) -> Void)?
    /// Xe bấm phím nhạc (cmd 279): 1 bài sau, 2 bài trước, 3 phát, 4 tạm dừng. App thực hiện rồi gọi `updateMusic(_:force:)`.
    var onMediaKey: ((UInt8) -> Void)?

    static let pollInterval: TimeInterval = 10
    static let ddtTimeout: TimeInterval = 5
    /// Lần đầu iOS có thể hiện hộp ghép đôi khi đọc đặc tính: cho lâu hơn.
    static let authTimeout: TimeInterval = 20

    // MFi
    private var ea: EASession?
    private var mfiReader = CCUMFiReader()
    private var mfiOut: [UInt8] = []
    private var credentials: CCUPasskey?
    private var askedAt: Date?
    private var askCount = 0
    private var mfiFramesLogged = 0

    // BLE
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var chars: [String: CBCharacteristic] = [:]
    private var ackChar: CBCharacteristic?
    private var notifyQueue: [CBCharacteristic] = []
    private var scanning = false
    private var authed = false
    private var authSent = false
    private var seq: UInt8 = 0
    private var ddtIds = DDTIdCounter()
    private var sender: DDTSender?
    private var senderLabel = ""
    private var senderStartedAt = Date()
    private var sendQueue: [(packet: [UInt8], label: String)] = []
    private var v1rx = DDTV1Receiver()
    private var v2rx = DDTV2Receiver()
    private var fuel = FuelMeter()
    private var ecuIds: [UInt64] = []
    private var lastPoll = Date.distantPast
    private var timer: Timer?
    private var started = false

    // Như app chính hãng: trạng thái điện thoại, bài hát, cuộc gọi
    private var lastPhoneStatus: PhoneStatusSnapshot?
    private var lastPhoneStatusAt = Date.distantPast
    private var musicInfo: MusicInfo?
    private var lastTrackKey: String?
    private var callState: DashUI.CallState = .none
    /// Đã gửi 308 = 1 cho cuộc gọi hiện tại chưa (để khi nghe máy không gửi lại).
    private var sentCallPresent = false

    // Thời tiết cho xe (cmd 3 → 4 + 10 × 5)
    /// App cung cấp vị trí cuối đã biết + tên khu vực (đã rút gọn, có thể rỗng).
    var lastFix: (() -> (lat: Double, lon: Double, place: String)?)?
    static let forecastCacheSeconds: TimeInterval = 600
    private var forecastCache: (lat: Double, lon: Double, at: Date, forecast: Weather.Forecast)?
    private var weatherTask: Task<Void, Never>?
    /// Chỉ gửi trạng thái điện thoại nhiều nhất mỗi 2 s.
    static let phoneStatusMinGap: TimeInterval = 2

    // Trạng thái hiển thị
    private var stage = "đang kết nối…"
    private var stageTimed = false
    private var stageFrames = false
    private var stageSince = Date()
    private var authSentAt = Date()
    private var authAttempts = 0
    private var probing = false
    private var authedAt: Date?
    private var diagLogged = 0
    private var ecuAsks = 0
    private var pingCount = 0
    private var lastNotifyStep = Date()
    private var lastMFiRetry = Date.distantPast
    private var lastBLETry = Date.distantPast
    private var connectRequestedAt = Date()
    private var connectedAt = Date()
    private var gotConnected = false
    private var accessorySignature = ""
    private var btState: CBManagerState = .unknown
    /// ECU đã thấy trên xe thử nghiệm (tài liệu); chỉ dùng thử khi xe không trả lời danh sách ECU.
    static let guessECU: UInt64 = 1248

    private let serviceUUID = CBUUID(string: CCUUUID.service)

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(accessoryChanged), name: .EAAccessoryDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(accessoryChanged), name: .EAAccessoryDidDisconnect, object: nil)
        EAAccessoryManager.shared().registerForLocalNotifications()
        central = CBCentralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        PhoneStatusProbe.enable()
        log("B: bắt đầu")
        lastMFiRetry = Date()
        openMFi()
    }

    // MARK: - Log / trạng thái

    private func log(_ text: String) {
        onLog?(text)
    }

    /// Đổi bước hiện tại. `timed`: hiện số giây đã chờ; `frames`: kèm số gói đã nhận.
    private func setStatus(_ text: String, timed: Bool = false, frames: Bool = false) {
        if stage == text && stageTimed == timed && stageFrames == frames { return }
        stage = text
        stageTimed = timed
        stageFrames = frames
        stageSince = Date()
        log("B: trạng thái: \(text)")
        publishStatus()
    }

    private func publishStatus() {
        var s = "Dữ liệu xe: " + stage
        if stageTimed { s += " (\(Int(Date().timeIntervalSince(stageSince))) s)" }
        if stageFrames { s += " · nhận \(framesReceived) gói" }
        if status != s { status = s }
    }

    private func hx(_ b: [UInt8]) -> String {
        b.prefix(64).hex + (b.count > 64 ? " …(\(b.count) B)" : "")
    }

    private func charName(_ key: String) -> String {
        switch key {
        case CCUUUID.cmdNotify: return "CMD"
        case CCUUUID.cmdWrite: return "CMD-ghi"
        case CCUUUID.ddtSendHandshake: return "DDT-bắt-tay"
        case CCUUUID.ddtSendControl: return "DDT-mở/đóng"
        case CCUUUID.ddtSendChunk: return "DDT-mẩu-gửi"
        case CCUUUID.ddtRecvAnnounce: return "DDT-báo-gói"
        case CCUUUID.ddtRecvChunk: return "DDT-mẩu-nhận"
        case CCUUUID.ddtV2Recv: return "DDT-V2"
        default: return key.hasPrefix(CCUUUID.ddtRecvAckPrefix) ? "DDT-ack" : key
        }
    }

    private func nextSeq() -> UInt8 {
        seq = seq &+ 1
        return seq
    }

    // MARK: - Hẹn giờ

    private func tick() {
        let now = Date()
        // Chưa có phiên MFi (phụ kiện chỉ hiện sau khi nối đồng hồ, hoặc mở lỗi): thử lại mỗi 3 s
        if ea == nil, now.timeIntervalSince(lastMFiRetry) >= 3 {
            lastMFiRetry = now
            openMFi()
        }
        // Hỏi lại passkey nếu chưa có trả lời; hết 5 lần thì đóng mở lại phiên
        if ea != nil, credentials == nil, let t = askedAt, now.timeIntervalSince(t) > 3 {
            if askCount < 5 {
                log("B: chưa có passkey, hỏi lại (lần \(askCount + 1))")
                askPasskey()
            } else if now.timeIntervalSince(t) > 6 {
                closeMFi("MFi không trả lời, mở lại phiên")
            }
        }
        if peripheral == nil, now.timeIntervalSince(lastBLETry) >= 2 {
            lastBLETry = now
            tryBLE()
        }
        // iOS không báo didConnect khi CCU đã nối sẵn với hệ thống: tự coi như đã nối
        if let p = peripheral, p.state == .connected, !gotConnected, now.timeIntervalSince(connectRequestedAt) > 3 {
            log("B: iOS báo đã nối nhưng chưa có didConnect, tự dò dịch vụ")
            handleConnected(p)
        }
        // Dò dịch vụ không có kết quả
        if let p = peripheral, p.state == .connected, gotConnected, chars.isEmpty, now.timeIntervalSince(connectedAt) > 10 {
            connectedAt = now
            log("B: 10 s chưa thấy đặc tính, dò lại dịch vụ")
            p.discoverServices([serviceUUID])
        }
        // Bật notify bị kẹt (callback không bao giờ tới): bỏ đặc tính đó, làm tiếp
        if !notifyQueue.isEmpty, now.timeIntervalSince(lastNotifyStep) > 4 {
            let c = notifyQueue.removeFirst()
            log("B: bật notify \(charName(c.uuid.uuidString.uppercased())) quá 4 s, bỏ qua")
            enableNextNotify()
        }
        let limit = senderLabel == "AuthenticationV2" ? Self.authTimeout : Self.ddtTimeout
        if sender != nil, now.timeIntervalSince(senderStartedAt) > limit {
            driveSender(.error("quá \(Int(limit)) s"))
        }
        // Xác thực không có kết quả: gửi lại; sau 2 lần vẫn hỏi thử dữ liệu
        if authSent, !authed, sender == nil, sendQueue.isEmpty, now.timeIntervalSince(authSentAt) > 10 {
            retryAuth()
        }
        if (authed || probing), now.timeIntervalSince(lastPoll) >= Self.pollInterval {
            poll()
        }
        diagnose(now)
        if authed { phoneStatusTick(now) }
        publishStatus()
    }

    // MARK: - Giống app chính hãng: giờ, ngôn ngữ, trạng thái điện thoại, bài hát, cuộc gọi

    /// Giờ (cmd 10): giây epoch địa phương = giây UTC + lệch múi giờ.
    private func sendTime(_ why: String) {
        let date = Date()
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let local = Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(offset)
        log("B: gửi giờ cho xe (\(why)): lệch múi giờ \(offset / 3600) h, giây địa phương \(local)")
        writeCmd(CCUCommand.time(seq: nextSeq(), epochLocal: local), label: "giờ 10")
    }

    private func sendLanguage(_ why: String) {
        log("B: gửi ngôn ngữ tiếng Việt cho xe (\(why))")
        writeCmd(CCUCommand.language(seq: nextSeq(), lang: CCUCommand.languageVietnamese), label: "ngôn ngữ 12")
    }

    /// Trạng thái điện thoại (cmd 316). Sóng di động: iOS không có API công khai nên luôn báo 5 vạch (đoán).
    private func sendPhoneStatus(_ s: PhoneStatusSnapshot, why: String) {
        lastPhoneStatus = s
        lastPhoneStatusAt = Date()
        let bytes = CCUCommand.phoneStatus(battery: s.battery, callVolume: s.callVolume, mediaVolume: s.mediaVolume,
                                           btAudio: s.btAudio, thermal: s.thermal, signalBars: s.signalBars)
        log("B: gửi trạng thái điện thoại (\(why)): pin \(s.battery.map { "\($0) %" } ?? "?") · "
            + "âm lượng media \(s.mediaVolume.map { "\($0) %" } ?? "?") · âm lượng gọi không rõ · "
            + "Bluetooth \(s.btAudio ? "có" : "không") · nhiệt \(s.thermal) · sóng \(s.signalBars) (giả định)")
        writeCmd(bytes, label: "trạng thái điện thoại 316")
    }

    /// Mỗi giây: đọc trạng thái, đổi thì gửi, nhưng cách nhau ít nhất 2 s.
    private func phoneStatusTick(_ now: Date) {
        let s = PhoneStatusProbe.read()
        guard s != lastPhoneStatus, now.timeIntervalSince(lastPhoneStatusAt) >= Self.phoneStatusMinGap else { return }
        sendPhoneStatus(s, why: "có thay đổi")
    }

    private static func trackKey(_ m: MusicInfo?) -> String {
        guard let m = m else { return "none" }
        return "\(m.artist)|\(m.album)|\(m.title)|\(m.playing)|\(Int(m.duration))"
    }

    /// App đưa bài đang phát vào (mỗi giây). Gửi cmd 278 khi đổi bài hoặc đổi phát / dừng (hoặc `force`).
    func updateMusic(_ info: MusicInfo?, force: Bool = false) {
        musicInfo = info
        guard authed else { return }
        if !force, Self.trackKey(info) == lastTrackKey { return }
        sendTrackInfo()
    }

    private func sendTrackInfo() {
        let m = musicInfo
        lastTrackKey = Self.trackKey(m)
        let state: UInt8 = m == nil ? CCUCommand.playStopped : (m!.playing ? CCUCommand.playPlaying : CCUCommand.playPaused)
        let packet = CCUCommand.trackInfo(artist: m?.artist ?? "", album: m?.album ?? "", title: m?.title ?? "",
                                          durationSeconds: Int(m?.duration ?? 0), playState: state, speedTenths: 10,
                                          positionSeconds: Int(m?.position ?? 0))
        if let m = m {
            log("B: gửi bài hát cho xe (278): \(m.title) · \(m.artist) · \(m.playing ? "đang phát" : "tạm dừng")")
        } else {
            log("B: gửi bài hát cho xe (278): không có bài, trạng thái dừng")
        }
        enqueueDDT(packet, label: "278 bài hát")
    }

    /// App đưa trạng thái cuộc gọi vào. Gửi cmd 308: 1 khi đang nói, 2 khi kết thúc; đổ chuông chỉ ghi log
    /// (tài liệu không có mã cho "đang đổ chuông").
    func updateCall(_ state: DashUI.CallState) {
        let previous = callState
        guard state != previous else { return }
        callState = state
        guard authed else { return }
        sendCallState(state, previous: previous)
    }

    private func sendCallState(_ state: DashUI.CallState, previous: DashUI.CallState) {
        switch state {
        case .ringing:
            // THÍ NGHIỆM: tài liệu không có mã đổ chuông. Đoán mã 1 (đổi ở CCUCommand.sendCallPresentWhenRinging).
            if CCUCommand.sendCallPresentWhenRinging {
                log("B: đang đổ chuông: gửi mã 1 (đoán, chưa có trong tài liệu)")
                writeCmd(CCUCommand.callState(inCall: true), label: "cuộc gọi đổ chuông 308 = 1 (đoán)")
                sentCallPresent = true
            } else {
                log("B: có cuộc gọi đến, chưa gửi cho xe (tài liệu không có mã đổ chuông)")
            }
        case .active:
            if sentCallPresent {
                log("B: đã nghe máy, xe đã được báo mã 1 cho cuộc gọi này, không gửi lại")
            } else {
                log("B: đang trong cuộc gọi, gửi cho xe (308 = 1)")
                writeCmd(CCUCommand.callState(inCall: true), label: "cuộc gọi 308 = 1")
                sentCallPresent = true
            }
        case .none:
            if previous == .none { return }
            log("B: cuộc gọi đã kết thúc\(previous == .ringing ? " (nhỡ / từ chối)" : ""), gửi cho xe (308 = 2)")
            writeCmd(CCUCommand.callState(inCall: false), label: "cuộc gọi 308 = 2")
            sentCallPresent = false
        }
    }

    /// Ngay sau khi xác thực được chấp nhận: giờ, ngôn ngữ, trạng thái điện thoại, bài hát, cuộc gọi (nếu đang nói).
    private func sendAfterAuth() {
        sendTime("sau xác thực")
        sendLanguage("sau xác thực")
        sendPhoneStatus(PhoneStatusProbe.read(), why: "sau xác thực")
        sendTrackInfo()
        sentCallPresent = false
        if callState != .none { sendCallState(callState, previous: .none) }
    }

    private func mediaKeyName(_ k: UInt8) -> String {
        switch k {
        case 1: return "bài sau"
        case 2: return "bài trước"
        case 3: return "phát"
        case 4: return "tạm dừng"
        default: return "mã \(k)"
        }
    }

    /// Ghi vào log vì sao chưa có dữ liệu (một lần ở mốc 15, 30, 60 s sau khi xác thực).
    private func diagnose(_ now: Date) {
        guard let t = authedAt, data.coolantC == nil || data.batteryV == nil || data.odoKm == nil else { return }
        let marks: [TimeInterval] = [15, 30, 60]
        guard diagLogged < marks.count, now.timeIntervalSince(t) >= marks[diagLogged] else { return }
        diagLogged += 1
        log("B: \(Int(marks[diagLogged - 1])) s sau xác thực vẫn thiếu dữ liệu: nhận \(framesReceived) gói, ECU \(ecuIds), "
            + "hàng đợi \(sendQueue.count), đang gửi \(sender != nil ? senderLabel : "không"), "
            + "ODO \(data.odoKm != nil) pin \(data.batteryV != nil) nước \(data.coolantC != nil)")
    }

    private func retryAuth() {
        guard let cred = credentials, peripheral != nil else { return }
        authAttempts += 1
        if authAttempts >= 3 && !probing {
            probing = true
            log("B: chưa thấy 01 02 01 sau \(authAttempts) lần, vẫn thử hỏi dữ liệu")
            poll()
        }
        if authAttempts > 8 {
            setStatus("CCU không trả lời xác thực")
            return
        }
        log("B: gửi lại xác thực (lần \(authAttempts + 1))")
        authSentAt = Date()
        enqueueDDT(CCUCommand.authenticationV2(code: cred.code, passkey: cred.passkey), label: "AuthenticationV2")
        setStatus("đang xác thực CCU", timed: true)
    }

    // MARK: - MFi

    @objc private func accessoryChanged(_ note: Notification) {
        Task { @MainActor in
            if note.name == .EAAccessoryDidDisconnect, let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory,
               let current = self.ea?.accessory, current.connectionID == acc.connectionID {
                self.closeMFi("MFi CCU ngắt")
            }
            self.openMFi()
        }
    }

    private func openMFi() {
        guard ea == nil else { return }
        let accessories = EAAccessoryManager.shared().connectedAccessories
        let sig = accessories.map { "\($0.name) [\($0.protocolStrings.joined(separator: ","))]" }.joined(separator: "; ")
        if sig != accessorySignature {
            accessorySignature = sig
            log("B: phụ kiện MFi hiện có: \(sig.isEmpty ? "(không có)" : sig)")
        }
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(CCUUUID.mfiProtocol) }) else {
            if credentials == nil { setStatus("chưa thấy bộ CCU") }
            return
        }
        log("B: thấy MFi \(acc.name) · \(acc.protocolStrings.joined(separator: ", "))")
        guard let s = EASession(accessory: acc, forProtocol: CCUUUID.mfiProtocol) else {
            setStatus("không mở được kết nối CCU (tắt app Y-Connect?)")
            return
        }
        ea = s
        mfiReader = CCUMFiReader()
        mfiOut = []
        askCount = 0
        mfiFramesLogged = 0
        for stream in [s.inputStream as Stream?, s.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        if credentials == nil { setStatus("đang hỏi mã CCU", timed: true) }
        askPasskey()
    }

    private func askPasskey() {
        askedAt = Date()
        askCount += 1
        let bytes = CCUMFiFrame.askPasskey.encoded()
        log("B: MFi → hỏi mã CCU [\(bytes.hex)] (lần \(askCount))")
        mfiOut += bytes
        flushMFi()
    }

    private func closeMFi(_ why: String) {
        for stream in [ea?.inputStream as Stream?, ea?.outputStream as Stream?].compactMap({ $0 }) {
            stream.close()
            stream.remove(from: .main, forMode: .default)
        }
        ea = nil
        mfiOut = []
        log("B: \(why)")
    }

    fileprivate func readMFi() {
        guard let input = ea?.inputStream else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            for frame in mfiReader.append(Array(buf[0..<n])) {
                if let p = CCUPasskey(answer: frame) {
                    let isNew = credentials != p
                    credentials = p
                    log("B: MFi ← mã CCU \(p.code), đã có passkey\(isNew ? "" : " (như cũ)")")
                    if peripheral == nil { setStatus("đang tìm CCU qua Bluetooth", timed: true) }
                    if peripheral != nil, notifyQueue.isEmpty, !chars.isEmpty, isNew || !authSent {
                        // Passkey đổi (xe tắt mở lại) hoặc vừa hỏi lại sau khi bị từ chối: xác thực lại
                        authSent = false
                        authed = false
                        notificationsReady()
                    }
                    tryBLE()
                } else if mfiFramesLogged < 40 {
                    mfiFramesLogged += 1
                    log("B: MFi ← \(frame)")
                }
            }
        }
    }

    fileprivate func flushMFi() {
        guard let out = ea?.outputStream else { return }
        while !mfiOut.isEmpty && out.hasSpaceAvailable {
            let n = mfiOut.withUnsafeBufferPointer { out.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { break }
            mfiOut.removeFirst(n)
        }
    }

    fileprivate func mfiStreamEnded() {
        closeMFi("MFi CCU đóng")
    }

    // MARK: - BLE: tìm và nối

    private func tryBLE() {
        guard let c = central, c.state == .poweredOn, let cred = credentials, peripheral == nil else { return }
        if stage == "chưa thấy bộ CCU" || stage == "đang hỏi mã CCU" { setStatus("đang tìm CCU qua Bluetooth", timed: true) }
        let wanted = CCUUUID.namePrefix + cred.code
        let known = c.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let p = known.first(where: { $0.name == wanted }) ?? known.first {
            log("B: CCU đã nối sẵn với iOS: \(p.name ?? "?")")
            connect(p)
            return
        }
        if !scanning {
            scanning = true
            c.scanForPeripherals(withServices: nil, options: nil)
            log("B: quét tìm \(wanted)")
            setStatus("đang tìm CCU qua Bluetooth", timed: true)
        }
    }

    private func connect(_ p: CBPeripheral) {
        guard let c = central else { return }
        if scanning {
            c.stopScan()
            scanning = false
        }
        peripheral = p
        gotConnected = false
        connectRequestedAt = Date()
        p.delegate = self
        c.connect(p, options: nil)
        log("B: nối BLE, trạng thái iOS \(p.state.rawValue)")
        setStatus("đang nối Bluetooth CCU", timed: true)
    }

    private func resetLink() {
        chars = [:]
        ackChar = nil
        notifyQueue = []
        authed = false
        authSent = false
        authedAt = nil
        authAttempts = 0
        probing = false
        diagLogged = 0
        ecuAsks = 0
        sender = nil
        sendQueue = []
        v1rx = DDTV1Receiver()
        v2rx = DDTV2Receiver()
        lastPhoneStatus = nil
        lastTrackKey = nil
    }

    fileprivate func handleState(_ state: CBManagerState) {
        btState = state
        switch state {
        case .poweredOn:
            log("B: Bluetooth bật")
            tryBLE()
        case .unauthorized:
            setStatus("chưa cho phép Bluetooth (vào Cài đặt iPhone)")
        case .poweredOff:
            setStatus("Bluetooth đang tắt")
            scanning = false
        default:
            log("B: Bluetooth trạng thái \(state.rawValue)")
        }
    }

    fileprivate func handleDiscover(_ p: CBPeripheral, name: String) {
        guard peripheral == nil, name.hasPrefix(CCUUUID.namePrefix) else { return }
        if let cred = credentials, name != CCUUUID.namePrefix + cred.code {
            log("B: thấy \(name) (khác mã \(cred.code)), vẫn thử")
        } else {
            log("B: thấy \(name)")
        }
        connect(p)
    }

    fileprivate func handleConnected(_ p: CBPeripheral) {
        guard p === peripheral else { return }
        resetLink()
        gotConnected = true
        connectedAt = Date()
        log("B: BLE đã nối, ghi tối đa \(p.maximumWriteValueLength(for: .withResponse)) B")
        p.discoverServices([serviceUUID])
        setStatus("đang dò dịch vụ CCU", timed: true)
    }

    fileprivate func handleFailedConnect(_ p: CBPeripheral, error: String) {
        guard p === peripheral else { return }
        log("B: nối BLE lỗi: \(error)")
        peripheral = nil
        gotConnected = false
        setStatus("nối Bluetooth CCU lỗi, đang thử lại")
    }

    fileprivate func handleDisconnected(_ p: CBPeripheral, error: String) {
        guard p === peripheral else { return }
        let wasAuthed = authed
        resetLink()
        gotConnected = false
        if wasAuthed, data.ignitionOn != false { Alerts.connectionLost() }
        setStatus(data.ignitionOn == false ? "xe đã tắt khoá điện, chờ xe bật lại" : "mất kết nối CCU, đang nối lại")
        log("B: BLE ngắt \(error)")
        // Passkey có thể đổi sau mỗi lần xe tắt mở: hỏi lại qua MFi
        if ea != nil { askPasskey() }
        // Lệnh connect của iOS không hết hạn: tự nối lại khi xe bật lại
        central?.connect(p, options: nil)
    }

    // MARK: - BLE: dịch vụ, đặc tính, notify

    fileprivate func handleServices(_ p: CBPeripheral, error: String?) {
        if let e = error { log("B: dò dịch vụ lỗi: \(e)") }
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            setStatus("CCU không có dịch vụ dữ liệu")
            return
        }
        p.discoverCharacteristics(nil, for: s)
    }

    fileprivate func handleCharacteristics(_ p: CBPeripheral, service: CBService, error: String?) {
        if let e = error { log("B: dò đặc tính lỗi: \(e)") }
        for c in service.characteristics ?? [] {
            let key = c.uuid.uuidString.uppercased()
            chars[key] = c
            if key.hasPrefix(CCUUUID.ddtRecvAckPrefix) { ackChar = c }
            log("B: đặc tính \(key) props \(c.properties.rawValue)")
        }
        if ackChar == nil { log("B: thiếu đặc tính ack 1A1A7A79…") }
        let notifyUUIDs: [String] = [CCUUUID.cmdNotify, CCUUUID.ddtSendHandshake, CCUUUID.ddtRecvAnnounce,
                                     CCUUUID.ddtRecvChunk, CCUUUID.ddtV2Recv]
        notifyQueue = []
        setStatus("đang bật thông báo CCU", timed: true)
        for u in notifyUUIDs {
            guard let c = chars[u] else {
                log("B: thiếu đặc tính \(u)")
                continue
            }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                notifyQueue.append(c)
            } else {
                log("B: \(u) không có notify")
            }
        }
        enableNextNotify()
    }

    /// Bật notify từng đặc tính một: chờ callback rồi mới bật cái kế.
    private func enableNextNotify() {
        guard let p = peripheral else { return }
        lastNotifyStep = Date()
        if let c = notifyQueue.first {
            log("B: bật notify \(charName(c.uuid.uuidString.uppercased()))")
            p.setNotifyValue(true, for: c)
        } else {
            notificationsReady()
        }
    }

    fileprivate func handleNotifyState(_ c: CBCharacteristic, error: String?) {
        let key = c.uuid.uuidString.uppercased()
        if let e = error {
            log("B: bật notify \(key) lỗi: \(e)")
        } else {
            log("B: notify \(key) = \(c.isNotifying)")
        }
        if let first = notifyQueue.first, first.uuid == c.uuid {
            notifyQueue.removeFirst()
            enableNextNotify()
        }
    }

    private func notificationsReady() {
        guard !authSent else { return }
        guard let cred = credentials else {
            log("B: chưa có mã CCU, chưa xác thực được")
            return
        }
        authSent = true
        authSentAt = Date()
        writeCmd(CCUCommand.connectAppId(seq: nextSeq()), label: "ConnectAppId")
        enqueueDDT(CCUCommand.authenticationV2(code: cred.code, passkey: cred.passkey), label: "AuthenticationV2")
        setStatus("đang xác thực CCU", timed: true)
    }

    // MARK: - BLE: ghi

    private func write(_ bytes: [UInt8], to c: CBCharacteristic, label: String, quiet: Bool = false) {
        guard let p = peripheral else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        if !quiet {
            // Gói xác thực chứa passkey: không ghi nội dung vào log
            let body = label.contains("AuthenticationV2") ? "\(bytes.count) B, ẩn passkey" : hx(bytes)
            log("B: → \(charName(c.uuid.uuidString.uppercased())) \(label) [\(body)]")
        }
        p.writeValue(Data(bytes), for: c, type: type)
    }

    private func writeCmd(_ bytes: [UInt8], label: String, quiet: Bool = false) {
        guard let c = chars[CCUUUID.cmdWrite] else {
            log("B: thiếu đặc tính CMD write, bỏ \(label)")
            return
        }
        write(bytes, to: c, label: label, quiet: quiet)
    }

    // MARK: - DDT V1 gửi

    private func enqueueDDT(_ packet: [UInt8], label: String) {
        sendQueue.append((packet: packet, label: label))
        startNextDDT()
    }

    private func startNextDDT() {
        guard sender == nil, !sendQueue.isEmpty, let p = peripheral, p.state == .connected else { return }
        let item = sendQueue.removeFirst()
        let mtu = p.maximumWriteValueLength(for: .withResponse)
        let s = DDTSender(packet: item.packet, id: ddtIds.next(), mtu: mtu)
        log("B: DDT gửi \(item.label) id \(s.id), \(item.packet.count) B, mẩu \(s.chunkSize) B")
        sender = s
        senderLabel = item.label
        senderStartedAt = Date()
        driveSender(.begin)
    }

    private func driveSender(_ event: DDTSender.Event) {
        guard var s = sender else { return }
        let action = s.next(event)
        sender = s
        let id = s.id
        switch action {
        case .readHandshake:
            guard let p = peripheral, let c = chars[CCUUUID.ddtSendHandshake] else {
                driveSender(.error("thiếu đặc tính bắt tay DDT"))
                return
            }
            p.readValue(for: c)
        case .writeStart(let b), .writeClose(let b):
            guard let c = chars[CCUUUID.ddtSendControl] else {
                driveSender(.error("thiếu đặc tính mở/đóng DDT"))
                return
            }
            write(b, to: c, label: "DDT \(senderLabel) điều khiển")
        case .writeChunk(let b):
            guard let c = chars[CCUUUID.ddtSendChunk] else {
                driveSender(.error("thiếu đặc tính mẩu DDT"))
                return
            }
            write(b, to: c, label: "DDT \(senderLabel) mẩu")
        case .wait:
            break
        case .pause(let t):
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                Task { @MainActor in
                    guard let self = self, let cur = self.sender, cur.id == id else { return }
                    self.driveSender(.pauseElapsed)
                }
            }
        case .done:
            log("B: DDT \(senderLabel) xong")
            sender = nil
            startNextDDT()
        case .failed(let why):
            log("B: DDT \(senderLabel) lỗi: \(why)")
            sender = nil
            startNextDDT()
        }
    }

    fileprivate func handleWrite(_ c: CBCharacteristic, error: String?) {
        let key = c.uuid.uuidString.uppercased()
        if let e = error { log("B: ghi \(key) lỗi: \(e)") }
        guard let s = sender else { return }
        if key == CCUUUID.ddtSendControl {
            if let e = error { driveSender(.error("ghi mở/đóng: \(e)")); return }
            let event: DDTSender.Event = s.state == .waitingCloseAck ? DDTSender.Event.closeWritten : DDTSender.Event.startWritten
            driveSender(event)
        } else if key == CCUUUID.ddtSendChunk {
            if let e = error { driveSender(.error("ghi mẩu: \(e)")); return }
            driveSender(.chunkWritten)
        }
    }

    // MARK: - BLE: nhận

    fileprivate func handleValue(_ c: CBCharacteristic, bytes: [UInt8], error: String?) {
        let key = c.uuid.uuidString.uppercased()
        if error == nil {
            framesReceived += 1
            let isPing = key == CCUUUID.cmdNotify && bytes.count >= 2 && bytes[0] == 0x01 && bytes[1] == 0x35
            if !isPing || pingCount < 3 {
                log("B: ← \(charName(key)) [\(hx(bytes))]")
            }
        }
        if let e = error {
            log("B: đọc \(key) lỗi: \(e)")
            if key == CCUUUID.ddtSendHandshake, sender?.state == .readingHandshake {
                driveSender(.error("đọc bắt tay: \(e)"))
            }
            return
        }
        switch key {
        case CCUUUID.ddtSendHandshake:
            if sender?.state == .readingHandshake {
                driveSender(.handshakeRead)
            } else {
                driveSender(.handshakeNotify(bytes))
            }
        case CCUUUID.cmdNotify:
            handleCmd(bytes)
        case CCUUUID.ddtRecvAnnounce:
            if let ack = v1rx.announce(bytes) {
                if let a = ackChar {
                    write(ack, to: a, label: "DDT ack")
                } else {
                    log("B: không có đặc tính ack, bỏ")
                }
            }
        case CCUUUID.ddtRecvChunk:
            if let packet = v1rx.chunk(bytes) { handlePacket(packet, via: "V1") }
        case CCUUUID.ddtV2Recv:
            if let packet = v2rx.append(bytes) { handlePacket(packet, via: "V2") }
        default:
            break
        }
    }

    private func handleCmd(_ bytes: [UInt8]) {
        guard let m = CCUMessage(bytes) else { return }
        switch m {
        case .ping:
            pingCount += 1
            if let reply = CCUCommand.pingReply(to: bytes) { writeCmd(reply, label: "ping 310", quiet: pingCount > 3) }
        case .authResult(let ok):
            log("B: xác thực \(ok ? "được chấp nhận" : "bị từ chối")")
            authed = ok
            if ok {
                authedAt = Date()
                probing = false
                setStatus("đang chờ phản hồi", timed: true, frames: true)
                poll()
                sendAfterAuth()
            } else {
                setStatus("CCU từ chối mã xác thực, đang hỏi lại mã")
                authSent = false
                credentials = nil
                askCount = 0
                askPasskey()
            }
        case .ignition(let on):
            log("B: khoá điện \(on ? "bật" : "tắt")")
            data.ignitionOn = on
            if !on { setStatus("xe đã tắt khoá điện") }
        case .fuelCounter(let counter):
            let used = fuel.update(counter: counter)
            log("B: bộ đếm xăng \(counter) → \(String(format: "%.3f", used)) L")
            data.fuelUsedL = used
        case .askTime:
            log("B: xe hỏi giờ (cmd 9)")
            sendTime("xe hỏi")
        case .askLanguage:
            log("B: xe hỏi ngôn ngữ (cmd 11)")
            sendLanguage("xe hỏi")
        case .mediaKey(let k):
            log("B: xe bấm phím nhạc (cmd 279): \(mediaKeyName(k))")
            onMediaKey?(k)
        case .callKey(let k):
            let name = k == 0 ? "từ chối" : (k == 1 ? "trả lời" : (k == 2 ? "kết thúc" : "mã \(k)"))
            log("B: xe bấm nút cuộc gọi (cmd 281): \(name), iOS không cho app trả lời/từ chối")
        case .volumeKey(let k):
            log("B: xe bấm phím âm lượng (cmd 285): mã \(k), gửi lại trạng thái điện thoại")
            sendPhoneStatus(PhoneStatusProbe.read(), why: "xe bấm âm lượng")
        case .askWeather(let lat, let lon, let valid):
            handleWeatherRequest(latitude: lat, longitude: lon, valid: valid, raw: bytes)
        case .other(let cmd, let raw):
            log("B: lệnh lạ từ xe: cmd \(cmd) [\(hx(raw))]")
        }
    }

    // MARK: - Thời tiết cho xe

    /// Xe hỏi thời tiết (cmd 3): lấy dự báo (cache 10 phút) rồi gửi cmd 4 (tên khu vực) và mười cmd 5. Không chặn vòng poll.
    private func handleWeatherRequest(latitude: Double, longitude: Double, valid: Bool, raw: [UInt8]) {
        var lat = latitude, lon = longitude
        let fix = lastFix?()
        if valid {
            log("B: xe hỏi thời tiết (cmd 3): toạ độ \(String(format: "%.4f, %.4f", lat, lon)) [\(hx(raw))]")
        } else if let f = fix {
            log("B: xe hỏi thời tiết (cmd 3) nhưng toạ độ vô lý (\(String(format: "%.4f, %.4f", lat, lon))), dùng vị trí cuối đã biết \(String(format: "%.4f, %.4f", f.lat, f.lon))")
            lat = f.lat
            lon = f.lon
        } else {
            log("B: xe hỏi thời tiết (cmd 3) nhưng toạ độ vô lý và app chưa có vị trí, bỏ qua")
            return
        }
        // Tên từ app chỉ đúng khi toạ độ gần vị trí của app (≤ 3 km)
        var place = ""
        if let f = fix, !f.place.isEmpty,
           CLLocation(latitude: f.lat, longitude: f.lon).distance(from: CLLocation(latitude: lat, longitude: lon)) <= 3000 {
            place = f.place
        }
        let lt = lat, ln = lon, knownPlace = place
        weatherTask?.cancel()
        weatherTask = Task { [weak self] in
            await self?.answerWeather(lat: lt, lon: ln, knownPlace: knownPlace)
        }
    }

    private func answerWeather(lat: Double, lon: Double, knownPlace: String) async {
        let forecast: Weather.Forecast
        if let c = forecastCache, Date().timeIntervalSince(c.at) < Self.forecastCacheSeconds,
           abs(c.lat - lat) < 0.05, abs(c.lon - lon) < 0.05 {
            forecast = c.forecast
            log("B: dự báo lấy từ bộ nhớ đệm (dưới 10 phút), không gọi mạng")
        } else {
            do {
                forecast = try await fetchForecast(lat: lat, lon: lon)
            } catch {
                log("B: lấy dự báo Open-Meteo lỗi: \(error.localizedDescription), không trả lời xe")
                return
            }
            forecastCache = (lat, lon, Date(), forecast)
        }
        if Task.isCancelled { return }
        var place = knownPlace
        if place.isEmpty {
            place = await reverseGeocodedName(lat: lat, lon: lon)
        }
        sendWeather(forecast, place: place)
    }

    private func reverseGeocodedName(lat: Double, lon: Double) async -> String {
        let loc = CLLocation(latitude: lat, longitude: lon)
        guard let marks = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "vi_VN")),
              let mark = marks.first else { return "" }
        let sub = mark.subLocality ?? mark.subAdministrativeArea
        let city = mark.locality ?? mark.administrativeArea
        return PlaceNames.short(sub: sub, city: city)
    }

    private func sendWeather(_ f: Weather.Forecast, place: String) {
        let area = CCUCommand.area(seq: nextSeq(), name: place)
        writeCmd(area, label: "khu vực 4 \"\(place)\"")
        let frames = Weather.forecastFrames(f, seq: { self.nextSeq() })
        for fr in frames {
            writeCmd(fr, label: "dự báo 5 ô \(fr[3])", quiet: true)
        }
        let hours = f.hours.map { "\(Int($0.tempC.rounded()))°" }.joined(separator: "/")
        log("B: đã gửi thời tiết cho xe: khu vực \"\(place)\" (\(area.count - 3) B), \(frames.count) ô dự báo; "
            + "bây giờ \(String(format: "%.1f", f.now.tempC)) °C mã WMO \(f.now.code) (icon \(Weather.bikeIcon(code: f.now.code, isDay: f.now.isDay))), "
            + "\(f.days.count) ngày, giờ kế \(hours.isEmpty ? "—" : hours)")
    }

    private func handlePacket(_ packet: [UInt8], via: String) {
        let cmd = ccuCommand(of: packet) ?? 0
        log("B: gói đầy đủ \(cmd) (\(via)) \(packet.count) B [\(hx(packet))]")
        switch cmd {
        case 260:
            let ids = CCUVehicle.ecuIds(answer260: packet)
            log("B: ECU \(ids.map { String($0) }.joined(separator: ", "))")
            if !ids.isEmpty {
                let first = ecuIds.isEmpty
                ecuIds = ids
                ecuId = ids.first
                if first, let ecu = ids.first, authed || probing {
                    enqueueDDT(CCUCommand.vehicleDataRequest(ecu: ecu), label: "270 ECU \(ecu)")
                }
            }
        case 271:
            let params = CCUVehicle.params(answer271: packet)
            log("B: 271 có \(params.count) tham số: "
                + params.map { "#\($0.id)=\($0.raw.count) B" }.joined(separator: ", "))
            let d = CCUVehicle.decode271(packet)
            var parts: [String] = []
            if let v = d.odoKm { parts.append(String(format: "ODO %.1f km", v)) }
            if let v = d.batteryV { parts.append(String(format: "%.2f V", v)) }
            if let v = d.coolantC { parts.append("\(v) °C") }
            if let v = d.rpm { parts.append("\(v) v/ph") }
            log("B: dữ liệu xe: \(parts.isEmpty ? "không đọc được thông số nào" : parts.joined(separator: " · "))")
            data.merge(d)
            if parts.isEmpty {
                setStatus("xe trả lời nhưng chưa đọc được thông số", frames: true)
            } else {
                setStatus("đã nhận dữ liệu xe")
            }
        default:
            break
        }
    }

    // MARK: - Hỏi định kỳ

    private func poll() {
        lastPoll = Date()
        guard authed || probing, let p = peripheral, p.state == .connected else { return }
        writeCmd(CCUCommand.ignitionRequest, label: "khoá điện 311")
        let pending270 = sendQueue.contains(where: { $0.label.hasPrefix("270") }) || (sender != nil && senderLabel.hasPrefix("270"))
        if ecuIds.isEmpty {
            ecuAsks += 1
            writeCmd(CCUCommand.ecuListRequest, label: "danh sách ECU 259 (lần \(ecuAsks))")
            // Xe không trả lời danh sách ECU: thử luôn ECU đã thấy trên xe thử nghiệm
            if ecuAsks >= 3, !pending270 {
                log("B: chưa có danh sách ECU, thử ECU \(Self.guessECU) (giá trị đoán theo tài liệu)")
                enqueueDDT(CCUCommand.vehicleDataRequest(ecu: Self.guessECU), label: "270 ECU \(Self.guessECU) (đoán)")
            }
        } else if let ecu = ecuIds.first, !pending270 {
            enqueueDDT(CCUCommand.vehicleDataRequest(ecu: ecu), label: "270 ECU \(ecu)")
        }
        writeCmd(CCUCommand.fuelRequest, label: "xăng 287")
    }
}

// MARK: - Delegate (gọi trên luồng chính, chuyển vào MainActor)

extension CCULink: StreamDelegate {
    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        Task { @MainActor in
            switch eventCode {
            case .hasBytesAvailable: self.readMFi()
            case .hasSpaceAvailable: self.flushMFi()
            case .errorOccurred, .endEncountered: self.mfiStreamEnded()
            default: break
            }
        }
    }
}

extension CCULink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in self.handleState(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix(CCUUUID.namePrefix) else { return }
        Task { @MainActor in self.handleDiscover(peripheral, name: name) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in self.handleConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let text = error?.localizedDescription ?? "?"
        Task { @MainActor in self.handleFailedConnect(peripheral, error: text) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let text = error?.localizedDescription ?? ""
        Task { @MainActor in self.handleDisconnected(peripheral, error: text) }
    }
}

extension CCULink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let text = error?.localizedDescription
        Task { @MainActor in self.handleServices(peripheral, error: text) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let text = error?.localizedDescription
        Task { @MainActor in self.handleCharacteristics(peripheral, service: service, error: text) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        let text = error?.localizedDescription
        Task { @MainActor in self.handleNotifyState(characteristic, error: text) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Chép giá trị ngay: characteristic.value có thể đổi trước khi MainActor chạy
        let bytes: [UInt8] = characteristic.value.map { [UInt8]($0) } ?? []
        let text = error?.localizedDescription
        Task { @MainActor in self.handleValue(characteristic, bytes: bytes, error: text) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let text = error?.localizedDescription
        Task { @MainActor in self.handleWrite(characteristic, error: text) }
    }
}
