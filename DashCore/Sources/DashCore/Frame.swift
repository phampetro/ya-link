import Foundation

/// CRC-32/MPEG-2: đa thức 0x04C11DB7, khởi tạo 0xFFFFFFFF, MSB trước, không đảo bit, không XOR cuối.
/// Giá trị kiểm tra cho ASCII "123456789" là 0x0376E6E7.
public enum CRC32MPEG2 {
    private static let table: [UInt32] = (0..<256).map { i in
        var crc = UInt32(i) << 24
        for _ in 0..<8 {
            crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    public static func checksum<S: Sequence>(_ data: S, start: UInt32 = 0xFFFF_FFFF) -> UInt32 where S.Element == UInt8 {
        var crc = start
        for byte in data {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }
}

/// Một khung Link A (cả hai chiều):
/// magic `nAl@` · version 01 · direction · command · độ dài payload (u32 LE) · flag · CRC (u32 LE) · payload.
/// CRC tính trên 12 byte đầu (không gồm ô CRC) rồi tới payload.
public struct Frame: Equatable, CustomStringConvertible {
    public static let magic: [UInt8] = [0x6E, 0x41, 0x6C, 0x40]
    public static let headerSize = 16
    /// Điện thoại gửi direction 06; xe gửi 03 (01 với lệnh 55).
    public static let phoneDirection: UInt8 = 0x06

    public var direction: UInt8
    public var command: UInt8
    public var flag: UInt8
    public var payload: [UInt8]

    public init(command: UInt8, flag: UInt8, payload: [UInt8], direction: UInt8 = Frame.phoneDirection) {
        self.direction = direction
        self.command = command
        self.flag = flag
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        let n = UInt32(payload.count)
        var head = Frame.magic + [0x01, direction, command]
        head += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
        head.append(flag)
        let crc = CRC32MPEG2.checksum(head + payload)
        return head + [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)] + payload
    }

    public enum DecodeError: Error, Equatable {
        case noMagic, tooShort, lengthMismatch(declared: Int, actual: Int), crcMismatch
    }

    /// Giải mã đúng một khung trọn vẹn (dùng cho test và cho FrameReader).
    public static func decode(_ raw: [UInt8]) throws -> Frame {
        guard raw.count >= headerSize else { throw DecodeError.tooShort }
        guard Array(raw[0..<4]) == magic else { throw DecodeError.noMagic }
        let n = Int(le32(raw, 7))
        guard raw.count == headerSize + n else { throw DecodeError.lengthMismatch(declared: n, actual: raw.count - headerSize) }
        let payload = Array(raw[headerSize...])
        guard CRC32MPEG2.checksum(Array(raw[0..<12]) + payload) == le32(raw, 12) else { throw DecodeError.crcMismatch }
        return Frame(command: raw[6], flag: raw[11], payload: payload, direction: raw[5])
    }

    public var description: String {
        "cmd \(command) flag \(flag) [\(payload.prefix(24).hex)\(payload.count > 24 ? " …(\(payload.count) B)" : "")]"
    }
}

/// Ghép các mẩu byte nhận được (đến lộn xộn) thành khung hoàn chỉnh.
/// Quét tìm magic, bỏ rác phía trước; độ dài vô lý (> 1 MiB) thì bỏ 1 byte và quét lại;
/// CRC sai thì bỏ 1 byte và quét lại (không phải luật của xe, là cách giải mã an toàn).
public struct FrameReader {
    public static let maxPayload = 1 << 20
    private var buffer: [UInt8] = []
    public private(set) var droppedBytes = 0
    public private(set) var badFrames = 0

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [Frame] {
        buffer += bytes
        var frames: [Frame] = []
        while true {
            guard let start = Self.find(Frame.magic, in: buffer) else {
                // giữ lại 3 byte cuối phòng magic bị cắt đôi
                let keep = min(buffer.count, Frame.magic.count - 1)
                droppedBytes += buffer.count - keep
                buffer = Array(buffer.suffix(keep))
                break
            }
            if start > 0 {
                droppedBytes += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= Frame.headerSize else { break }
            let n = Int(le32(buffer, 7))
            if n > Self.maxPayload {
                skipOne()
                continue
            }
            guard buffer.count >= Frame.headerSize + n else { break }
            let raw = Array(buffer[0..<(Frame.headerSize + n)])
            if let frame = try? Frame.decode(raw) {
                frames.append(frame)
                buffer.removeFirst(raw.count)
            } else {
                badFrames += 1
                skipOne()
            }
        }
        return frames
    }

    private mutating func skipOne() {
        droppedBytes += 1
        buffer.removeFirst()
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}

func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
}

func le16(_ b: [UInt8], _ at: Int) -> UInt16 {
    UInt16(b[at]) | UInt16(b[at + 1]) << 8
}

public extension Sequence where Element == UInt8 {
    /// "6E 41 6C 40" — chữ hoa, cách nhau bằng dấu cách, như trong vectors.
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public extension Array where Element == UInt8 {
    /// Đọc chuỗi hex có hoặc không có dấu cách.
    init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
