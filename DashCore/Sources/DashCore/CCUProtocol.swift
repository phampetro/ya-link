import Foundation

// Link B: bộ CCU của xe (docs/protocol/link-b-ccu.md trong maxdash).
// Chỉ logic thuần (Foundation), tầng iPhone (ExternalAccessory + CoreBluetooth) nằm ở App/CCULink.swift.

// MARK: - Dữ liệu xe

/// Dữ liệu xe đọc qua CCU. nil = chưa biết.
public struct CCUVehicleData: Equatable {
    public var ignitionOn: Bool?
    public var odoKm: Double?
    public var batteryV: Double?
    public var coolantC: Int?
    /// Vòng tua máy (assumed: bytes 0–1 của param 1).
    public var rpm: Int?
    /// Xăng đã dùng (lít) kể từ khi app bắt đầu đọc.
    public var fuelUsedL: Double?

    public init(ignitionOn: Bool? = nil, odoKm: Double? = nil, batteryV: Double? = nil,
                coolantC: Int? = nil, rpm: Int? = nil, fuelUsedL: Double? = nil) {
        self.ignitionOn = ignitionOn
        self.odoKm = odoKm
        self.batteryV = batteryV
        self.coolantC = coolantC
        self.rpm = rpm
        self.fuelUsedL = fuelUsedL
    }

    /// Ghi đè các ô khác nil của `other` lên bản này.
    public mutating func merge(_ other: CCUVehicleData) {
        if let v = other.ignitionOn { ignitionOn = v }
        if let v = other.odoKm { odoKm = v }
        if let v = other.batteryV { batteryV = v }
        if let v = other.coolantC { coolantC = v }
        if let v = other.rpm { rpm = v }
        if let v = other.fuelUsedL { fuelUsedL = v }
    }
}

// MARK: - UUID

/// UUID dạng chuỗi (DashCore không dùng CoreBluetooth).
public enum CCUUUID {
    public static let mfiProtocol = "com.yconnect.data"
    public static let namePrefix = "YCCU_"
    public static let service = "AFA2CDF4-ECCF-46A7-A5EA-9DA428C0157A"
    /// Ghi lệnh ngắn `[cmd hi, cmd lo, payload…]`.
    public static let cmdWrite = "B606C7F9-E5A1-4E75-B313-2A920054A8EB"
    /// Lệnh ngắn từ xe.
    public static let cmdNotify = "9C810D26-B605-4306-8C1C-755A1BA3066C"
    /// DDT V1 gửi: bắt tay (read, notify).
    public static let ddtSendHandshake = "75AB2788-87F6-4F61-BA9C-6F85A12600D1"
    /// DDT V1 gửi: mở / đóng.
    public static let ddtSendControl = "56851826-A090-4F6A-A5DF-D1776520F74A"
    /// DDT V1 gửi: các mẩu.
    public static let ddtSendChunk = "E998AEAB-EA8F-4063-83AA-2017C1A44484"
    /// DDT V1 nhận: xe báo có gói.
    public static let ddtRecvAnnounce = "77808451-E42F-4F6B-83ED-3AB44AA3D16A"
    /// DDT V1 nhận: ack của điện thoại. Chỉ biết tiền tố, so khớp bằng tiền tố (assumed).
    public static let ddtRecvAckPrefix = "1A1A7A79"
    /// DDT V1 nhận: các mẩu.
    public static let ddtRecvChunk = "347456EE-A588-4DD5-BD98-62BE3672E27A"
    /// DDT V2 nhận (dữ liệu xe).
    public static let ddtV2Recv = "E974B9A1-FA31-43C6-91AE-09931F3F6EF1"
}

// MARK: - MFi (com.yconnect.data)

/// Khung MFi: SOH 01 · độ dài u32 BE (= 2 + body) · cmd u16 BE · body · EOT 04.
public struct CCUMFiFrame: Equatable, CustomStringConvertible {
    public var cmd: UInt16
    public var body: [UInt8]

    public init(cmd: UInt16, body: [UInt8] = []) {
        self.cmd = cmd
        self.body = body
    }

    public func encoded() -> [UInt8] {
        let n = UInt32(2 + body.count)
        var out: [UInt8] = [0x01, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        out += [UInt8(cmd >> 8), UInt8(cmd & 0xFF)]
        out += body
        out.append(0x04)
        return out
    }

    /// Hỏi mã CCU + passkey: đúng `01 00 00 00 02 01 39 04`.
    public static let askPasskey = CCUMFiFrame(cmd: 0x0139)
    public static let passkeyAnswerCmd: UInt16 = 0x013A

    public var description: String {
        "mfi cmd \(String(format: "%04X", cmd)) [\(body.prefix(32).hex)\(body.count > 32 ? " …(\(body.count) B)" : "")]"
    }
}

/// Ghép byte MFi đến từng mẩu thành khung. Rác hoặc khung hỏng: bỏ 1 byte rồi quét lại.
public struct CCUMFiReader {
    public static let maxLength = 1 << 16
    private var buffer: [UInt8] = []
    public private(set) var droppedBytes = 0

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [CCUMFiFrame] {
        buffer += bytes
        var frames: [CCUMFiFrame] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x01) else {
                droppedBytes += buffer.count
                buffer = []
                break
            }
            if start > 0 {
                droppedBytes += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 5 else { break }
            let n = Int(buffer[1]) << 24 | Int(buffer[2]) << 16 | Int(buffer[3]) << 8 | Int(buffer[4])
            if n < 2 || n > Self.maxLength {
                skipOne()
                continue
            }
            let total = 1 + 4 + n + 1
            guard buffer.count >= total else { break }
            guard buffer[total - 1] == 0x04 else {
                skipOne()
                continue
            }
            let cmd = UInt16(buffer[5]) << 8 | UInt16(buffer[6])
            let body = Array(buffer[7..<(total - 1)])
            frames.append(CCUMFiFrame(cmd: cmd, body: body))
            buffer.removeFirst(total)
        }
        return frames
    }

    private mutating func skipOne() {
        droppedBytes += 1
        buffer.removeFirst()
    }
}

/// Mã CCU (14 ký tự, cũng là đuôi tên BLE `YCCU_<code>`) và passkey 6 số.
public struct CCUPasskey: Equatable {
    public var code: String
    public var passkey: String

    public init(code: String, passkey: String) {
        self.code = code
        self.passkey = passkey
    }

    /// Đọc câu trả lời 0x013A (độ dài 22).
    /// Cách hiểu: "payload" trong tài liệu = phần được đếm trong ô độ dài = cmd (2 byte) + body (20 byte),
    /// nên payload byte 2–15 = body 0–13 (mã), 16–21 = body 14–19 (passkey). Khớp đúng 22 = 2 + 14 + 6.
    /// Dễ dãi: chấp nhận body dài hơn 20 (chỉ lấy 20 byte đầu); bỏ NUL / khoảng trắng cuối mã;
    /// passkey phải là 6 chữ số.
    public init?(answer frame: CCUMFiFrame) {
        guard frame.cmd == CCUMFiFrame.passkeyAnswerCmd, frame.body.count >= 20 else { return nil }
        let codeBytes = Array(frame.body[0..<14])
        let keyBytes = Array(frame.body[14..<20])
        guard keyBytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        let trimmed = codeBytes.filter { $0 != 0x00 }
        guard let c = String(bytes: trimmed, encoding: .ascii), let k = String(bytes: keyBytes, encoding: .ascii) else { return nil }
        let cleanCode = c.trimmingCharacters(in: .whitespaces)
        guard !cleanCode.isEmpty else { return nil }
        code = cleanCode
        passkey = k
    }
}

// MARK: - Lệnh ngắn (CMD write)

public enum CCUCommand {
    /// ConnectAppId: `00 02 <seq> 00 00 12 34`. Xe không trả lời.
    public static func connectAppId(seq: UInt8) -> [UInt8] { [0x00, 0x02, seq, 0x00, 0x00, 0x12, 0x34] }
    /// Hỏi khoá điện (311).
    public static let ignitionRequest: [UInt8] = [0x01, 0x37]
    /// Hỏi danh sách ECU (259), trả lời 260 qua DDT V1 nhận.
    public static let ecuListRequest: [UInt8] = [0x01, 0x03]
    /// Hỏi bộ đếm xăng (287), trả lời 288.
    public static let fuelRequest: [UInt8] = [0x01, 0x1F]

    /// Trả lời ping 309 `01 35 <token>` bằng 310 `01 36 <token>`. nil nếu không phải ping.
    public static func pingReply(to ping: [UInt8]) -> [UInt8]? {
        guard ping.count >= 2, ping[0] == 0x01, ping[1] == 0x35 else { return nil }
        return [0x01, 0x36] + Array(ping[2...])
    }

    /// Giờ (cmd 10): `00 0A <seq>` + 8 byte BE giây epoch địa phương (giây UTC + lệch múi giờ).
    public static func time(seq: UInt8, date: Date, timeZone: TimeZone = .current) -> [UInt8] {
        let local = Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(timeZone.secondsFromGMT(for: date))
        let u = UInt64(bitPattern: local)
        var out: [UInt8] = [0x00, 0x0A, seq]
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((u >> UInt64(shift)) & 0xFF))
        }
        return out
    }

    public static let languageVietnamese: UInt8 = 15
    public static let languageEnglish: UInt8 = 0

    /// Ngôn ngữ (cmd 12): `00 0C <seq> <lang>`; 15 tiếng Việt, 0 tiếng Anh.
    public static func language(seq: UInt8, lang: UInt8 = CCUCommand.languageVietnamese) -> [UInt8] {
        [0x00, 0x0C, seq, lang]
    }

    /// AuthenticationV2 (gửi qua DDT V1): `01 01` + mã (14 ASCII) + passkey (6 ASCII) = 22 byte.
    /// Mã ngắn hơn 14 thì đệm 0x00, dài hơn thì cắt (assumed; mã thật luôn đủ 14).
    public static func authenticationV2(code: String, passkey: String) -> [UInt8] {
        var c = Array(code.utf8.prefix(14))
        while c.count < 14 { c.append(0x00) }
        var k = Array(passkey.utf8.prefix(6))
        while k.count < 6 { k.append(0x30) }
        return [0x01, 0x01] + c + k
    }

    /// Yêu cầu dữ liệu xe 270 (gửi qua DDT V1): `01 0E len24` + protobuf `18 <ecu> 22 02 01 48`
    /// (field 3 = ECU, field 4 packed = param 1 và 72). Cách hiểu: len24 = độ dài phần protobuf phía sau.
    public static func vehicleDataRequest(ecu: UInt64) -> [UInt8] {
        let proto: [UInt8] = [0x18] + CCUProto.varint(ecu) + [0x22, 0x02, 0x01, 0x48]
        let n = proto.count
        return [0x01, 0x0E, UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + proto
    }
}

// MARK: - Lệnh ngắn từ xe (CMD notify)

public enum CCUMessage: Equatable {
    /// 258 `01 02 <r>`: r = 1 chấp nhận.
    case authResult(accepted: Bool)
    /// 312 `01 38 <s>`: 1 bật, 0 tắt (tắt cũng được đẩy sang không cần hỏi).
    case ignition(on: Bool)
    /// 288 `01 20` + u32 LE.
    case fuelCounter(UInt32)
    /// 309 `01 35 <token>`.
    case ping
    /// 9 `00 09`: xe hỏi giờ.
    case askTime
    /// 11 `00 0B`: xe hỏi ngôn ngữ.
    case askLanguage
    case other(cmd: UInt16, bytes: [UInt8])

    public init?(_ b: [UInt8]) {
        guard b.count >= 2 else { return nil }
        let cmd = UInt16(b[0]) << 8 | UInt16(b[1])
        switch cmd {
        case 258 where b.count >= 3: self = .authResult(accepted: b[2] == 1)
        // Tài liệu: 1 bật, 0 tắt. Giá trị khác chưa rõ nghĩa: không đoán, trả .other.
        case 312 where b.count >= 3 && b[2] <= 1: self = .ignition(on: b[2] == 1)
        case 288 where b.count >= 6: self = .fuelCounter(le32(b, 2))
        case 309: self = .ping
        case 9: self = .askTime
        case 11: self = .askLanguage
        default: self = .other(cmd: cmd, bytes: b)
        }
    }

    /// `01 02 01` → true, `01 02 xx` → false, khác → nil.
    public static func authAccepted(_ b: [UInt8]) -> Bool? {
        if case .authResult(let ok)? = CCUMessage(b) { return ok }
        return nil
    }
}

/// cmd (2 byte đầu, BE) của một gói đã ghép (DDT) hoặc lệnh ngắn.
public func ccuCommand(of packet: [UInt8]) -> UInt16? {
    guard packet.count >= 2 else { return nil }
    return UInt16(packet[0]) << 8 | UInt16(packet[1])
}

// MARK: - DDT V1 gửi (điện thoại → xe)

/// id gói DDT: 1…255 xoay vòng, bỏ 0.
public struct DDTIdCounter {
    private var last: UInt8 = 0
    public init() {}
    public mutating func next() -> UInt8 {
        last = last == 255 ? 1 : last + 1
        return last
    }
}

/// Gửi một gói dài qua DDT V1, dạng máy trạng thái. Tầng BLE gọi `next(_:)` với sự kiện vừa xảy ra
/// và làm đúng việc trả về:
///   .begin → đọc 75AB2788 → (đọc xong) ghi mở `[id, len24]` vào 56851826 → chờ notify `[01, id]` trên 75AB2788
///   → ghi từng mẩu `[id, off24] + mẩu` vào E998AEAB (mẩu sau khi mẩu trước ghi xong)
///   → ghi đóng `00 00` vào 56851826 → chờ notify `00 00` → nghỉ 80 ms → xong.
public struct DDTSender {
    public enum Action: Equatable {
        /// Đọc 75AB2788.
        case readHandshake
        /// Ghi vào 56851826 (with response).
        case writeStart([UInt8])
        /// Ghi vào E998AEAB (with response).
        case writeChunk([UInt8])
        /// Ghi `00 00` vào 56851826 (with response).
        case writeClose([UInt8])
        /// Không làm gì, chờ sự kiện kế.
        case wait
        /// Chờ chừng này giây rồi gọi `.pauseElapsed`.
        case pause(TimeInterval)
        case done
        case failed(String)
    }

    public enum Event: Equatable {
        case begin
        case handshakeRead
        case startWritten
        /// Notify trên 75AB2788.
        case handshakeNotify([UInt8])
        case chunkWritten
        case closeWritten
        case pauseElapsed
        case error(String)
    }

    public enum State: Equatable {
        case idle, readingHandshake, waitingStartAck, sendingChunks, waitingCloseAck, gap, done, failed
    }

    public static let gapSeconds: TimeInterval = 0.08

    /// Cỡ mẩu = clamp(mtu − 7, 20, 180).
    public static func chunkSize(mtu: Int) -> Int { min(max(mtu - 7, 20), 180) }

    public let id: UInt8
    public let packet: [UInt8]
    public let chunkSize: Int
    public private(set) var state: State = .idle
    /// Mẩu kế tiếp sẽ ghi (vị trí byte).
    public private(set) var offset = 0

    public init(packet: [UInt8], id: UInt8, mtu: Int) {
        self.packet = packet
        self.id = id == 0 ? 1 : id
        self.chunkSize = DDTSender.chunkSize(mtu: mtu)
    }

    /// Byte mở: `[id, len >> 16, len >> 8, len]`.
    public var startBytes: [UInt8] {
        let n = packet.count
        return [id, UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }

    public static let closeBytes: [UInt8] = [0x00, 0x00]

    public var isFinished: Bool { state == .done || state == .failed }

    public mutating func next(_ event: Event) -> Action {
        if case .error(let why) = event {
            state = .failed
            return .failed(why)
        }
        switch (state, event) {
        case (.idle, .begin):
            state = .readingHandshake
            return .readHandshake
        case (.readingHandshake, .handshakeRead):
            state = .waitingStartAck
            return .writeStart(startBytes)
        case (.waitingStartAck, .handshakeNotify(let b)):
            guard b.count >= 2, b[0] == 0x01, b[1] == id else { return .wait }
            state = .sendingChunks
            offset = 0
            return nextChunkOrClose()
        case (.sendingChunks, .chunkWritten):
            return nextChunkOrClose()
        case (.waitingCloseAck, .handshakeNotify(let b)):
            guard b.count >= 2, b[0] == 0x00, b[1] == 0x00 else { return .wait }
            state = .gap
            return .pause(DDTSender.gapSeconds)
        case (.gap, .pauseElapsed):
            state = .done
            return .done
        default:
            return .wait
        }
    }

    private mutating func nextChunkOrClose() -> Action {
        guard offset < packet.count else {
            state = .waitingCloseAck
            return .writeClose(DDTSender.closeBytes)
        }
        let end = min(offset + chunkSize, packet.count)
        let o = offset
        let bytes: [UInt8] = [id, UInt8((o >> 16) & 0xFF), UInt8((o >> 8) & 0xFF), UInt8(o & 0xFF)] + Array(packet[o..<end])
        offset = end
        return .writeChunk(bytes)
    }
}

// MARK: - DDT V1 nhận (xe → điện thoại)

/// 1. xe notify `[id, len24]` trên 77808451 → `announce` trả ack `[01, id]` để ghi vào 1A1A7A79.
/// 2. mẩu `[id, off24] + bytes` trên 347456EE → `chunk` trả gói hoàn chỉnh khi đủ `len` byte.
public struct DDTV1Receiver {
    private var id: UInt8?
    private var buffer: [UInt8] = []
    private var filled: [Bool] = []
    private var filledCount = 0
    public static let maxLength = 1 << 20

    public init() {}

    public mutating func announce(_ b: [UInt8]) -> [UInt8]? {
        guard b.count >= 4 else { return nil }
        let n = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n <= Self.maxLength else { return nil }
        id = b[0]
        buffer = [UInt8](repeating: 0, count: n)
        filled = [Bool](repeating: false, count: n)
        filledCount = 0
        return [0x01, b[0]]
    }

    public mutating func chunk(_ b: [UInt8]) -> [UInt8]? {
        guard b.count >= 4, let current = id, b[0] == current else { return nil }
        let off = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        var i = 4
        var pos = off
        while i < b.count && pos < buffer.count {
            buffer[pos] = b[i]
            if !filled[pos] {
                filled[pos] = true
                filledCount += 1
            }
            i += 1
            pos += 1
        }
        guard filledCount == buffer.count, !buffer.isEmpty else { return nil }
        let out = buffer
        id = nil
        buffer = []
        filled = []
        filledCount = 0
        return out
    }
}

// MARK: - DDT V2 nhận (xe → điện thoại)

/// Mỗi notify trên E974B9A1: `[c0, c1, fragIndex, lastFragIndex] + bytes` (c0 c1 là bộ đếm).
/// fragIndex 0 bắt đầu bộ đệm mới; xong khi fragIndex ≥ lastFragIndex.
/// Lỡ mẩu (số thứ tự nhảy) thì bỏ gói đang ghép, chờ fragIndex 0 kế tiếp.
public struct DDTV2Receiver {
    private var buffer: [UInt8] = []
    private var expected: Int?

    public init() {}

    public mutating func append(_ b: [UInt8]) -> [UInt8]? {
        guard b.count >= 4 else { return nil }
        let frag = Int(b[2])
        let last = Int(b[3])
        if frag == 0 {
            buffer = []
        } else if expected != frag {
            expected = nil
            buffer = []
            return nil
        }
        buffer += b[4...]
        if frag >= last {
            let out = buffer
            buffer = []
            expected = nil
            return out
        }
        expected = frag + 1
        return nil
    }
}

// MARK: - Protobuf tối giản

public struct CCUProtoField: Equatable {
    public var number: Int
    public var wireType: Int
    /// Giá trị cho wire type 0 (varint), 1 (fixed64), 5 (fixed32).
    public var varint: UInt64?
    /// Byte cho wire type 2 (length-delimited).
    public var bytes: [UInt8]?
}

public enum CCUProto {
    public static func readVarint(_ b: [UInt8], at i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count && shift < 64 {
            let byte = b[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    public static func varint(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var x = v
        while x >= 0x80 {
            out.append(UInt8(x & 0x7F) | 0x80)
            x >>= 7
        }
        out.append(UInt8(x))
        return out
    }

    /// Đọc các field ở tầng ngoài cùng. Gặp chỗ hỏng thì dừng, trả các field đã đọc được.
    public static func fields(_ b: [UInt8]) -> [CCUProtoField] {
        var out: [CCUProtoField] = []
        var i = 0
        while i < b.count {
            guard let key = readVarint(b, at: &i) else { break }
            let number = Int(key >> 3)
            let wire = Int(key & 0x07)
            switch wire {
            case 0:
                guard let v = readVarint(b, at: &i) else { return out }
                out.append(CCUProtoField(number: number, wireType: 0, varint: v, bytes: nil))
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                guard i + size <= b.count else { return out }
                var v: UInt64 = 0
                for k in 0..<size { v |= UInt64(b[i + k]) << UInt64(8 * k) }
                i += size
                out.append(CCUProtoField(number: number, wireType: wire, varint: v, bytes: nil))
            case 2:
                guard let len = readVarint(b, at: &i), len <= UInt64(b.count - i) else { return out }
                let end = i + Int(len)
                out.append(CCUProtoField(number: number, wireType: 2, varint: nil, bytes: Array(b[i..<end])))
                i = end
            default:
                return out
            }
        }
        return out
    }

    public static func packedVarints(_ b: [UInt8]) -> [UInt64] {
        var out: [UInt64] = []
        var i = 0
        while i < b.count {
            guard let v = readVarint(b, at: &i) else { break }
            out.append(v)
        }
        return out
    }
}

// MARK: - Giải mã dữ liệu xe

public enum CCUVehicle {
    /// 260: bỏ 5 byte (`01 04 len24`), field 3 (varint hoặc packed) = các ECU id.
    public static func ecuIds(answer260 packet: [UInt8]) -> [UInt64] {
        guard packet.count > 5 else { return [] }
        var ids: [UInt64] = []
        for f in CCUProto.fields(Array(packet[5...])) where f.number == 3 {
            if let v = f.varint, f.wireType == 0 {
                ids.append(v)
            } else if let b = f.bytes {
                ids += CCUProto.packedVarints(b)
            }
        }
        return ids
    }

    /// Các tham số thô trong 271: bỏ 5 byte; mỗi field 4 = {field 1 paramId, field 2 raw}.
    public static func params(answer271 packet: [UInt8]) -> [(id: UInt64, raw: [UInt8])] {
        guard packet.count > 5 else { return [] }
        var out: [(id: UInt64, raw: [UInt8])] = []
        for f in CCUProto.fields(Array(packet[5...])) where f.number == 4 {
            guard let block = f.bytes else { continue }
            var pid: UInt64?
            var raw: [UInt8] = []
            for g in CCUProto.fields(block) {
                if g.number == 1, let v = g.varint { pid = v }
                if g.number == 2, let b = g.bytes { raw = b }
            }
            if let p = pid { out.append((id: p, raw: raw)) }
        }
        return out
    }

    /// 271 → ODO (param 72), điện áp / nhiệt độ nước / vòng tua (param 1). Ô không có thì nil.
    public static func decode271(_ packet: [UInt8]) -> CCUVehicleData {
        var d = CCUVehicleData()
        for p in params(answer271: packet) {
            switch p.id {
            case 72:
                // big-endian ÷ 10 = km
                guard !p.raw.isEmpty, p.raw.count <= 8 else { continue }
                var v: UInt64 = 0
                for byte in p.raw { v = v << 8 | UInt64(byte) }
                d.odoKm = Double(v) / 10
            case 1:
                guard p.raw.count >= 16, p.raw[6] != 0 else { continue }
                d.batteryV = Double(p.raw[6]) * 18.75 / 256
                d.coolantC = Int(p.raw[14]) - 30
                d.rpm = Int(p.raw[0]) << 8 | Int(p.raw[1])   // assumed
            default:
                break
            }
        }
        return d
    }
}

// MARK: - Xăng

/// Cộng dồn xăng đã dùng từ bộ đếm 288: lít = Δ / 100 000; bỏ bước nhảy ≥ 2 L (và bộ đếm lùi).
public struct FuelMeter: Equatable {
    public static let countsPerLitre: Double = 100_000
    public static let maxJumpLitres: Double = 2
    public private(set) var usedLitres: Double = 0
    public private(set) var lastCounter: UInt32?

    public init() {}

    @discardableResult
    public mutating func update(counter: UInt32) -> Double {
        defer { lastCounter = counter }
        guard let last = lastCounter, counter >= last else { return usedLitres }
        let litres = Double(counter - last) / FuelMeter.countsPerLitre
        if litres < FuelMeter.maxJumpLitres { usedLitres += litres }
        return usedLitres
    }
}
