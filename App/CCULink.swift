import CoreBluetooth
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
    @Published private(set) var status: String = "Chưa thấy CCU"
    /// Mỗi bước đều gọi hàm này (app hiện trong log).
    var onLog: ((String) -> Void)?

    static let pollInterval: TimeInterval = 10
    static let ddtTimeout: TimeInterval = 5

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
        log("B: bắt đầu")
        openMFi()
    }

    // MARK: - Log / trạng thái

    private func log(_ text: String) {
        onLog?(text)
    }

    private func setStatus(_ text: String) {
        if status != text { status = text }
        log("B: \(text)")
    }

    private func nextSeq() -> UInt8 {
        seq = seq &+ 1
        return seq
    }

    // MARK: - Hẹn giờ

    private func tick() {
        let now = Date()
        // Hỏi lại passkey nếu chưa có trả lời (tối đa 5 lần mỗi phiên)
        if ea != nil, credentials == nil, let t = askedAt, now.timeIntervalSince(t) > 3, askCount < 5 {
            log("B: chưa có passkey, hỏi lại")
            askPasskey()
        }
        if peripheral == nil { tryBLE() }
        if sender != nil, now.timeIntervalSince(senderStartedAt) > Self.ddtTimeout {
            driveSender(.error("quá \(Int(Self.ddtTimeout)) s"))
        }
        if authed, now.timeIntervalSince(lastPoll) >= Self.pollInterval {
            poll()
        }
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
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(CCUUUID.mfiProtocol) }) else { return }
        log("B: thấy MFi \(acc.name) · \(acc.protocolStrings.joined(separator: ", "))")
        guard let s = EASession(accessory: acc, forProtocol: CCUUUID.mfiProtocol) else {
            setStatus("Không mở được MFi CCU. Tắt app Y-Connect?")
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
        askPasskey()
        setStatus("Đang hỏi mã CCU…")
    }

    private func askPasskey() {
        askedAt = Date()
        askCount += 1
        let bytes = CCUMFiFrame.askPasskey.encoded()
        log("B: MFi → \(bytes.hex)")
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
                    log("B: mã CCU \(p.code), đã có passkey")
                    if isNew || peripheral == nil {
                        setStatus("Có mã CCU, đang tìm BLE…")
                    }
                    tryBLE()
                } else if mfiFramesLogged < 20 {
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
        }
    }

    private func connect(_ p: CBPeripheral) {
        guard let c = central else { return }
        if scanning {
            c.stopScan()
            scanning = false
        }
        peripheral = p
        p.delegate = self
        c.connect(p, options: nil)
        setStatus("Đang nối BLE \(p.name ?? "CCU")…")
    }

    private func resetLink() {
        chars = [:]
        ackChar = nil
        notifyQueue = []
        authed = false
        authSent = false
        sender = nil
        sendQueue = []
        v1rx = DDTV1Receiver()
        v2rx = DDTV2Receiver()
    }

    fileprivate func handleState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            log("B: Bluetooth bật")
            tryBLE()
        case .unauthorized:
            setStatus("Chưa cho phép Bluetooth")
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
        log("B: BLE đã nối, ghi tối đa \(p.maximumWriteValueLength(for: .withResponse)) B")
        p.discoverServices([serviceUUID])
        setStatus("Đang dò dịch vụ CCU…")
    }

    fileprivate func handleFailedConnect(_ p: CBPeripheral, error: String) {
        guard p === peripheral else { return }
        log("B: nối BLE lỗi: \(error)")
        peripheral = nil
        setStatus("Nối BLE CCU lỗi, thử lại…")
    }

    fileprivate func handleDisconnected(_ p: CBPeripheral, error: String) {
        guard p === peripheral else { return }
        resetLink()
        setStatus(data.ignitionOn == false ? "Đã tắt khoá, chờ xe…" : "Mất BLE CCU, chờ xe…")
        log("B: BLE ngắt \(error)")
        // Lệnh connect của iOS không hết hạn: tự nối lại khi xe bật lại
        central?.connect(p, options: nil)
    }

    // MARK: - BLE: dịch vụ, đặc tính, notify

    fileprivate func handleServices(_ p: CBPeripheral, error: String?) {
        if let e = error { log("B: dò dịch vụ lỗi: \(e)") }
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            setStatus("Không thấy dịch vụ CCU")
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
        if let c = notifyQueue.first {
            log("B: bật notify \(c.uuid.uuidString)")
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
        writeCmd(CCUCommand.connectAppId(seq: nextSeq()), label: "ConnectAppId")
        enqueueDDT(CCUCommand.authenticationV2(code: cred.code, passkey: cred.passkey), label: "AuthenticationV2")
        setStatus("Đang xác thực CCU…")
    }

    // MARK: - BLE: ghi

    private func write(_ bytes: [UInt8], to c: CBCharacteristic, label: String) {
        guard let p = peripheral else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        log("B: → \(label) [\(bytes.prefix(24).hex)\(bytes.count > 24 ? " …(\(bytes.count) B)" : "")]")
        p.writeValue(Data(bytes), for: c, type: type)
    }

    private func writeCmd(_ bytes: [UInt8], label: String) {
        guard let c = chars[CCUUUID.cmdWrite] else {
            log("B: thiếu đặc tính CMD write, bỏ \(label)")
            return
        }
        write(bytes, to: c, label: label)
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
                log("B: ← bắt tay DDT [\(bytes.hex)]")
                driveSender(.handshakeNotify(bytes))
            }
        case CCUUUID.cmdNotify:
            handleCmd(bytes)
        case CCUUUID.ddtRecvAnnounce:
            log("B: ← DDT báo gói [\(bytes.hex)]")
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
            log("B: ← \(key) [\(bytes.prefix(24).hex)]")
        }
    }

    private func handleCmd(_ bytes: [UInt8]) {
        guard let m = CCUMessage(bytes) else { return }
        switch m {
        case .ping:
            if let reply = CCUCommand.pingReply(to: bytes) { writeCmd(reply, label: "ping 310") }
        case .authResult(let ok):
            log("B: ← xác thực [\(bytes.hex)]")
            authed = ok
            if ok {
                setStatus("CCU đã xác thực")
                poll()
            } else {
                setStatus("CCU từ chối xác thực")
            }
        case .ignition(let on):
            log("B: ← khoá điện \(on ? "bật" : "tắt")")
            data.ignitionOn = on
            if !on { setStatus("Đã tắt khoá điện") }
        case .fuelCounter(let counter):
            let used = fuel.update(counter: counter)
            log("B: ← bộ đếm xăng \(counter) → \(String(format: "%.3f", used)) L")
            data.fuelUsedL = used
        case .askTime:
            log("B: ← xe hỏi giờ")
            writeCmd(CCUCommand.time(seq: nextSeq(), date: Date()), label: "giờ")
        case .askLanguage:
            log("B: ← xe hỏi ngôn ngữ")
            writeCmd(CCUCommand.language(seq: nextSeq(), lang: CCUCommand.languageVietnamese), label: "ngôn ngữ")
        case .other(let cmd, _):
            log("B: ← cmd \(cmd) [\(bytes.prefix(24).hex)]")
        }
    }

    private func handlePacket(_ packet: [UInt8], via: String) {
        let cmd = ccuCommand(of: packet) ?? 0
        switch cmd {
        case 260:
            let ids = CCUVehicle.ecuIds(answer260: packet)
            log("B: ← ECU \(ids.map { String($0) }.joined(separator: ", ")) (\(via))")
            if !ids.isEmpty {
                let first = ecuIds.isEmpty
                ecuIds = ids
                if first, let ecu = ids.first, authed {
                    enqueueDDT(CCUCommand.vehicleDataRequest(ecu: ecu), label: "270 ECU \(ecu)")
                }
            }
        case 271:
            let d = CCUVehicle.decode271(packet)
            var parts: [String] = []
            if let v = d.odoKm { parts.append(String(format: "ODO %.1f km", v)) }
            if let v = d.batteryV { parts.append(String(format: "%.2f V", v)) }
            if let v = d.coolantC { parts.append("\(v) °C") }
            if let v = d.rpm { parts.append("\(v) v/ph") }
            log("B: ← dữ liệu xe (\(via)): \(parts.isEmpty ? packet.prefix(32).hex : parts.joined(separator: " · "))")
            data.merge(d)
        default:
            log("B: ← gói \(cmd) (\(via)) \(packet.count) B [\(packet.prefix(32).hex)]")
        }
    }

    // MARK: - Hỏi định kỳ

    private func poll() {
        lastPoll = Date()
        guard authed, let p = peripheral, p.state == .connected else { return }
        writeCmd(CCUCommand.ignitionRequest, label: "khoá điện 311")
        if ecuIds.isEmpty {
            writeCmd(CCUCommand.ecuListRequest, label: "danh sách ECU 259")
        } else if let ecu = ecuIds.first, !sendQueue.contains(where: { $0.label.hasPrefix("270") }) {
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
