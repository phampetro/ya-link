import Foundation

/// Logic phiên Link A, không phụ thuộc cách truyền (ExternalAccessory trên iPhone, SPP trên Android).
/// Đưa từng khung của xe vào `receive`, gửi đi đúng các khung trong `Reaction.send`, theo thứ tự.
/// Gọi `tick` định kỳ (vd. mỗi 0,5 s) cho các việc theo thời gian.
///
/// Luồng (docs/how-it-works/lifecycle.md):
///   66 → gửi 81, 33 · 83 → gửi 84 · 83 rồi 82 → gửi chuỗi init (dự phòng: 2 s sau 82 đầu tiên)
///   55 → gửi lại trạng thái (2, 14, 13, 3, 10, 11) rồi được gửi khung hình · 56 → dừng gửi khung
///   51/52 → gửi 14 nhãn rỗng để bấm tiếp được · 80 → ACK khung, được gửi khung kế (mỗi lúc 1 khung)
public final class LinkASession {
    public enum Event: Equatable {
        case connected(serial: String)
        case authenticated(partNumber: String, width: Int, height: Int)
        case showFrames
        case pause
        case buttonUp, buttonDown
        case speed(Int)
        case ack(id: UInt16, roundTripMs: Int?)
        /// Menu gốc của đồng hồ (Enter / giữ Enter không bao giờ tới điện thoại, xem docs).
        case goHome, goWork, stopRoute
        case listOpened(Int)          // 55 03 / 04
        case listClosed(Int)          // 56 03 / 04
        case listSelected(index: Int, listId: Int, option: Int)   // 48
        case other(BikeMessage)
    }

    public struct Reaction: Equatable {
        public var send: [Frame] = []
        public var events: [Event] = []
    }

    // Trạng thái app muốn đồng hồ hiển thị; được gửi lại mỗi lần 55 (đồng hồ quên chữ thanh dưới sau khi tạm dừng).
    public var bottomBarText = ""
    public var speedLimitKmh: Float = 0
    public var navigating = false
    public var homeSaved = false
    public var workSaved = false

    public private(set) var serial: String?
    public private(set) var partNumber: String?
    public private(set) var screen = (width: 480, height: 234)
    public private(set) var initSent = false
    /// true sau 55, false sau 56: chỉ được gửi khung hình khi true.
    public private(set) var showing = false
    /// Danh sách gốc của đồng hồ đang mở (3 yêu thích, 4 trạm xăng), nil khi không.
    public private(set) var openListId: Int?

    private var seenChallenge = false
    private var firstAuthAt: TimeInterval?
    private var nextFrameId: UInt16 = 1
    private var inFlight: (id: UInt16, sentAt: TimeInterval)?
    /// Không nhận được ACK sau chừng này giây thì coi như mất, cho gửi khung khác (assumed).
    public var ackTimeout: TimeInterval = 2
    /// Dự phòng init khi không thấy 83 rồi 82 (documented — not yet observed).
    public var initFallbackDelay: TimeInterval = 2

    public init() {}

    public func receive(_ frame: Frame, now: TimeInterval) -> Reaction {
        var r = Reaction()
        let message = BikeMessage(frame)
        switch message {
        case .serial(let s):
            resetHandshake()
            serial = s
            r.send = [PhoneCommand.helloAck, PhoneCommand.helloSecond]
            r.events = [.connected(serial: s)]

        case .challenge(let part, let key):
            partNumber = part
            screen = DashScreen.size(forPartNumber: part)
            seenChallenge = true          // 83 lặp lại: phải chờ 82 mới
            r.send = [PhoneCommand.challengeResponse(key: key)]

        case .authResult:
            if firstAuthAt == nil { firstAuthAt = now }
            // 82 trước 83 không tính; 82 sau 83 mới gửi init
            if seenChallenge && !initSent {
                r.send = initSequence()
                initSent = true
                r.events = [.authenticated(partNumber: partNumber ?? "", width: screen.width, height: screen.height)]
            }

        case .openList(let k):
            openListId = Int(k)
            // Đang dẫn đường thì báo "không dẫn đường" để đồng hồ hiện danh sách
            if navigating { r.send = [PhoneCommand.navigationState(navigating: false)] }
            r.events = [.listOpened(Int(k))]

        case .closeList(let k):
            openListId = nil
            if navigating { r.send = [PhoneCommand.navigationState(navigating: true)] }
            r.events = [.listClosed(Int(k))]

        case .listEnter(let index, let listId, let option):
            r.events = [.listSelected(index: Int(index), listId: Int(listId), option: Int(option))]

        case .goHome: r.events = [.goHome]
        case .goWork: r.events = [.goWork]
        case .stopRoute: r.events = [.stopRoute]

        case .showFrames:
            showing = true
            openListId = nil
            inFlight = nil
            r.send = [PhoneCommand.navigationState(navigating: navigating), PhoneCommand.rearmButtons,
                      PhoneCommand.showFramesReply, PhoneCommand.bottomBar(bottomBarText),
                      PhoneCommand.homeSaved(homeSaved), PhoneCommand.workSaved(workSaved)]
            r.events = [.showFrames]

        case .pause:
            showing = false
            openListId = nil
            inFlight = nil
            r.send = [PhoneCommand.pauseAck]
            r.events = [.pause]

        case .buttonUp:
            r.send = [PhoneCommand.rearmButtons]
            r.events = [.buttonUp]

        case .buttonDown:
            r.send = [PhoneCommand.rearmButtons]
            r.events = [.buttonDown]

        case .speed(let v, let mph):
            // Sự kiện luôn là km/h. mph chỉ là giả định trong tài liệu (byte 0 = 01).
            r.events = [.speed(mph ? Int((Double(v) * 1.609344).rounded()) : v)]

        case .ack(let id):
            var rtt: Int?
            if let f = inFlight {
                rtt = Int((now - f.sentAt) * 1000)
                inFlight = nil
            }
            r.events = [.ack(id: id, roundTripMs: rtt)]

        default:
            r.events = [.other(message)]
        }
        return r
    }

    /// Việc theo thời gian: init dự phòng, bỏ khung chờ ACK quá lâu.
    public func tick(now: TimeInterval) -> Reaction {
        var r = Reaction()
        if !initSent, let t = firstAuthAt, now - t >= initFallbackDelay {
            r.send = initSequence()
            initSent = true
            r.events = [.authenticated(partNumber: partNumber ?? "", width: screen.width, height: screen.height)]
        }
        if let f = inFlight, now - f.sentAt > ackTimeout {
            inFlight = nil
        }
        return r
    }

    /// Có được gửi khung hình lúc này không (đang hiển thị và không có khung nào chờ ACK).
    public var canSendFrame: Bool { showing && inFlight == nil }

    /// Tạo khung hình kế tiếp và ghi nhận nó đang chờ ACK. Trả nil nếu chưa được gửi.
    public func makeMapFrame(jpeg: [UInt8], now: TimeInterval, mode: UInt8 = 3) -> Frame? {
        guard canSendFrame else { return nil }
        let id = nextFrameId
        nextFrameId = nextFrameId == UInt16.max ? 1 : nextFrameId + 1
        inFlight = (id, now)
        return PhoneCommand.mapFrame(jpeg: jpeg, frameId: id, mode: mode)
    }

    /// Cập nhật cờ Nhà / Công ty đã lưu. Trả về khung 10 / 11 cần gửi ngay (rỗng nếu chưa init hoặc không đổi).
    /// Mỗi lần 55 và trong init, cờ vẫn được gửi lại như tài liệu.
    public func setSaved(home: Bool, work: Bool) -> [Frame] {
        let homeChanged = home != homeSaved, workChanged = work != workSaved
        homeSaved = home
        workSaved = work
        guard initSent else { return [] }
        var out: [Frame] = []
        if homeChanged { out.append(PhoneCommand.homeSaved(home)) }
        if workChanged { out.append(PhoneCommand.workSaved(work)) }
        return out
    }

    /// Chuỗi init sau bắt tay, đúng thứ tự trong tài liệu.
    func initSequence() -> [Frame] {
        [PhoneCommand.navigationState(navigating: navigating), PhoneCommand.initialize,
         PhoneCommand.homeSaved(homeSaved), PhoneCommand.rearmButtons, PhoneCommand.workSaved(workSaved),
         PhoneCommand.showFramesReply, PhoneCommand.bottomBar(bottomBarText),
         PhoneCommand.speedLimit(speedLimitKmh), PhoneCommand.initDone]
    }

    private func resetHandshake() {
        seenChallenge = false
        firstAuthAt = nil
        initSent = false
        showing = false
        inFlight = nil
        partNumber = nil
    }
}
