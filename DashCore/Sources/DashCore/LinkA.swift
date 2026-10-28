import Foundation

/// Lệnh xe gửi điện thoại (docs/protocol/link-a-dash.md, "Commands: bike to phone").
public enum BikeMessage: Equatable {
    case serial(String)                                   // 66
    case authResult(accepted: Bool)                       // 82
    case challenge(partNumber: String, key: [UInt8])      // 83, mỗi byte XOR 0x0A
    case showFrames                                       // 55 01 00: bấm Home / quay lại bản đồ
    case openList(UInt8)                                  // 55 03 / 04 (documented — not yet observed)
    case closeList(UInt8)                                 // 56 03 / 04 (documented — not yet observed)
    case pause                                            // 56 khác: rời màn hình, tắt máy, quá tải
    case speed(Int, mph: Bool)                            // 65: u16 LE ở byte 1–2; byte 0 = 01 là mph (assumed)
    case buttonUp                                         // 51
    case buttonDown                                       // 52
    case ack(UInt16)                                      // 80
    case listEnter(index: UInt16, listId: UInt16, option: UInt8) // 48 (documented — not yet observed)
    case stopRoute                                        // 49 (documented — not yet observed)
    case goHome, goWork                                   // 53 / 54 (documented — not yet observed)
    case unknown(Frame)

    public init(_ f: Frame) {
        let p = f.payload
        switch f.command {
        case 66:
            self = .serial(String(decoding: p, as: UTF8.self))
        case 82:
            self = .authResult(accepted: p.first == 1)
        case 83 where p.count >= 16:
            let plain = p.prefix(16).map { $0 ^ 0x0A }
            let part = String(decoding: plain[0..<12], as: UTF8.self)
            self = .challenge(partNumber: part, key: Array(plain[12..<16]))
        case 55:
            if let k = p.first, k == 3 || k == 4 { self = .openList(k) } else { self = .showFrames }
        case 56:
            if let k = p.first, k == 3 || k == 4 { self = .closeList(k) } else { self = .pause }
        case 65 where p.count >= 3:
            self = .speed(Int(le16(p, 1)), mph: p[0] == 1)
        case 51:
            self = .buttonUp
        case 52:
            self = .buttonDown
        case 80 where p.count >= 2:
            self = .ack(le16(p, 0))
        case 48 where p.count >= 5:
            self = .listEnter(index: le16(p, 0), listId: le16(p, 2), option: p[4])
        case 49:
            self = .stopRoute
        case 53:
            self = .goHome
        case 54:
            self = .goWork
        default:
            self = .unknown(f)
        }
    }
}

/// Kích thước khung hình theo mã đồng hồ (lệnh 83).
public enum DashScreen {
    public static func size(forPartNumber part: String) -> (width: Int, height: Int) {
        if part.contains("006-B4160") { return (480, 240) }   // documented — not yet observed
        return (480, 234)                                     // 006-B3952-01 observed; mã lạ: tạm 234
    }
}

/// Lệnh điện thoại gửi xe (docs/protocol/link-a-dash.md, "Commands: phone to bike").
/// Giá trị flag 0 là 2 byte `[value, 00]`.
public enum PhoneCommand {
    public static let helloAck = Frame(command: 81, flag: 0, payload: [0x01, 0x00])
    public static let helloSecond = Frame(command: 33, flag: 1, payload: [0x7C, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
    public static let initialize = Frame(command: 31, flag: 0, payload: [0x01, 0x00])
    public static let showFramesReply = Frame(command: 13, flag: 0, payload: [0x01, 0x00])
    public static let initDone = Frame(command: 12, flag: 0, payload: [0x01, 0x00])   // documented — not yet observed
    /// Nhãn rỗng: gửi sau MỖI lần bấm UP/DOWN, nếu không chỉ lần bấm đầu tới được app.
    public static let rearmButtons = Frame(command: 14, flag: 1, payload: [0x07, 0x1A, 0x00, 0x00])
    public static let pauseAck = Frame(command: 20, flag: 0, payload: [])              // documented — not yet observed

    public static func challengeResponse(key: [UInt8]) -> Frame {
        Frame(command: 84, flag: 1, payload: key)
    }

    public static func navigationState(navigating: Bool) -> Frame {
        Frame(command: 2, flag: 0, payload: [navigating ? 1 : 0, 0])
    }

    public static func homeSaved(_ saved: Bool) -> Frame {
        Frame(command: 10, flag: 0, payload: [saved ? 1 : 0, 0])
    }

    public static func workSaved(_ saved: Bool) -> Frame {
        Frame(command: 11, flag: 0, payload: [saved ? 1 : 0, 0])
    }

    /// Chữ ở thanh dưới (`▲ <text>`). UTF-8 ≤ 144 byte, cắt đúng ranh giới ký tự.
    /// Chuỗi rỗng gửi một dấu cách (xoá chữ). Phải có flag 1, flag 0 bị bỏ qua.
    public static func bottomBar(_ text: String) -> Frame {
        Frame(command: 3, flag: 1, payload: utf8Prefix(text.isEmpty ? " " : text, maxBytes: 144))
    }

    /// Biển tốc độ của đồng hồ: f32 LE giới hạn, u8 độ dài, "km/h". 0 = tắt biển.
    public static func speedLimit(_ kmh: Float) -> Frame {
        let bits = kmh.bitPattern
        let unit = Array("km/h".utf8)
        let payload = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24),
                       UInt8(unit.count)] + unit
        return Frame(command: 17, flag: 1, payload: payload)
    }

    /// Báo độ trễ sau mỗi ACK: [rtt ms / 100, 00], tối đa 255 (documented — not yet observed).
    public static func latency(milliseconds: Int) -> Frame {
        Frame(command: 16, flag: 0, payload: [UInt8(max(0, min(255, milliseconds / 100))), 0])
    }

    /// Khung bản đồ: lệnh 0 flag 1, byte 0 = chế độ (03 bản đồ thường, 00 đang dẫn đường),
    /// byte 1–2 = mã khung u16 LE, sau đó là JPEG baseline 4:2:0 đúng kích thước màn hình.
    /// JPEG ≤ 2048 byte được đệm số 0 tới 2050 (documented — not yet observed).
    public static func mapFrame(jpeg: [UInt8], frameId: UInt16, mode: UInt8 = 3) -> Frame {
        var image = jpeg
        if image.count <= 2048 { image += [UInt8](repeating: 0, count: 2050 - image.count) }
        return Frame(command: 0, flag: 1, payload: [mode, UInt8(frameId & 0xFF), UInt8(frameId >> 8)] + image)
    }

    static func utf8Prefix(_ s: String, maxBytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        for ch in s {
            let bytes = Array(String(ch).utf8)
            if out.count + bytes.count > maxBytes { break }
            out += bytes
        }
        return out
    }
}
