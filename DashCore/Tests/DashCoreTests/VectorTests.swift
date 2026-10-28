import XCTest
@testable import DashCore

/// Chạy toàn bộ test vectors của maxdash (bản sao trong thư mục vectors/, lấy từ maxdash commit 80bbd9c).
/// Luật của repo: TẤT CẢ phải qua trước khi ra xe. Sai một byte thì đồng hồ im lặng bỏ qua app.
final class VectorTests: XCTestCase {
    private func load(_ name: String) throws -> [[String: Any]] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: nil))
        let data = try Data(contentsOf: dir.appendingPathComponent("\(name).json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["vectors"] as? [[String: Any]])
    }

    private func bytes(_ any: Any?, _ id: String) throws -> [UInt8] {
        let s = try XCTUnwrap(any as? String, "\(id): thiếu chuỗi hex")
        return try XCTUnwrap([UInt8](hex: s), "\(id): hex sai")
    }

    func testCRC() throws {
        for v in try load("crc") {
            let id = v["id"] as! String
            let input = try bytes((v["input"] as! [String: Any])["hex"], id)
            let text = (v["expect"] as! [String: Any])["crc32_mpeg2"] as! String   // "0x0376E6E7"
            let want = try XCTUnwrap(UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16), id)
            XCTAssertEqual(CRC32MPEG2.checksum(input), want, id)
        }
    }

    func testPhoneFrames() throws {
        for v in try load("frames") {
            let id = v["id"] as! String
            let i = v["input"] as! [String: Any]
            let frame = Frame(command: UInt8(i["command"] as! Int), flag: UInt8(i["flag"] as! Int),
                              payload: try bytes(i["payload_hex"], id), direction: UInt8(i["direction"] as! Int))
            let want = try bytes((v["expect"] as! [String: Any])["frame_hex"], id)
            XCTAssertEqual(frame.encoded().hex, want.hex, id)
        }
    }

    /// Các khung điện thoại tự dựng (không đọc từ vector) phải ra đúng payload trong frames.json.
    func testPhoneCommandBuilders() throws {
        var want: [String: [UInt8]] = [:]
        for v in try load("frames") {
            let id = v["id"] as! String
            want[id] = try bytes((v["expect"] as! [String: Any])["frame_hex"], id)
        }
        let built: [String: Frame] = [
            "hello-81": PhoneCommand.helloAck,
            "hello-33": PhoneCommand.helloSecond,
            "challenge-response-84": PhoneCommand.challengeResponse(key: [0x44, 0x34, 0x0E, 0x0A]),
            "nav-state-2": PhoneCommand.navigationState(navigating: false),
            "init-31": PhoneCommand.initialize,
            "home-flag-10": PhoneCommand.homeSaved(false),
            "empty-label-14": PhoneCommand.rearmButtons,
            "work-flag-11": PhoneCommand.workSaved(false),
            "init-13": PhoneCommand.showFramesReply,
            "road-name-3": PhoneCommand.bottomBar("Lê Lợi"),
            "road-clear-3": PhoneCommand.bottomBar(""),
            "speed-limit-50-17": PhoneCommand.speedLimit(50),
            "speed-limit-clear-17": PhoneCommand.speedLimit(0),
            "init-12": PhoneCommand.initDone,
            "pause-ack-20": PhoneCommand.pauseAck,
            "latency-16": PhoneCommand.latency(milliseconds: 300),
        ]
        for (id, frame) in built {
            let expected = try XCTUnwrap(want[id], "frames.json không có \(id)")
            XCTAssertEqual(frame.encoded().hex, expected.hex, id)
        }
        XCTAssertEqual(built.count, want.count, "có vector trong frames.json chưa được dựng bằng PhoneCommand")
    }

    func testBikeCommands() throws {
        for v in try load("link-a-commands") {
            let id = v["id"] as! String
            let raw = try bytes((v["input"] as! [String: Any])["frame_hex"], id)
            let e = v["expect"] as! [String: Any]
            let frame = try Frame.decode(raw)
            XCTAssertEqual(Int(frame.command), e["command"] as? Int, id)
            XCTAssertEqual(Int(frame.flag), e["flag"] as? Int, id)
            XCTAssertEqual(frame.payload, try bytes(e["payload_hex"], id), id)

            let means = e["means"] as? [String: Any] ?? [:]
            let msg = BikeMessage(frame)
            if let s = means["serial"] as? String { XCTAssertEqual(msg, .serial(s), id) }
            if let ok = means["authenticated"] as? Bool { XCTAssertEqual(msg, .authResult(accepted: ok), id) }
            if let part = means["part_number"] as? String {
                XCTAssertEqual(msg, .challenge(partNumber: part, key: try bytes(means["key_hex"], id)), id)
                let screen = means["screen"] as! [Int]
                let size = DashScreen.size(forPartNumber: part)
                XCTAssertEqual([size.width, size.height], screen, id)
            }
            if means["start_frames"] as? Bool == true { XCTAssertEqual(msg, .showFrames, id) }
            if means["pause"] as? Bool == true { XCTAssertEqual(msg, .pause, id) }
            if let kmh = means["speed_kmh"] as? Int { XCTAssertEqual(msg, .speed(kmh, mph: false), id) }
            if let b = means["button"] as? String { XCTAssertEqual(msg, b == "up" ? .buttonUp : .buttonDown, id) }
            if let ack = means["ack_frame_id"] as? Int { XCTAssertEqual(msg, .ack(UInt16(ack)), id) }
            if case .unknown = msg { XCTFail("\(id): lệnh \(frame.command) chưa được hiểu") }
        }
    }

    /// Cả phiên trên NMAX Turbo: sau mỗi khung của xe, app phải gửi ĐÚNG các khung liệt kê, đúng thứ tự.
    func testHandshakeSession() throws {
        for v in try load("handshake-nmax-turbo") {
            let id = v["id"] as! String
            let steps = (v["input"] as! [String: Any])["steps"] as! [[String: Any]]
            let session = LinkASession()
            var t: TimeInterval = 0
            var i = 0
            while i < steps.count {
                let step = steps[i]
                XCTAssertEqual(step["from"] as? String, "bike", "\(id) bước \(i): phải bắt đầu bằng khung của xe")
                let frame = try Frame.decode(try bytes(step["frame_hex"], id))
                t += 0.1
                let sent = session.receive(frame, now: t).send
                var want: [Frame] = []
                if i + 1 < steps.count, steps[i + 1]["from"] as? String == "phone" {
                    for m in steps[i + 1]["must_send"] as! [[String: Any]] {
                        want.append(Frame(command: UInt8(m["command"] as! Int), flag: UInt8(m["flag"] as! Int),
                                          payload: try bytes(m["payload_hex"], id)))
                    }
                    i += 1
                }
                XCTAssertEqual(sent.map(\.description), want.map(\.description),
                               "\(id) bước \(i) (\(step["note"] as? String ?? ""))")
                i += 1
            }
            let screen = (v["expect"] as! [String: Any])["screen"] as! [Int]
            XCTAssertEqual([session.screen.width, session.screen.height], screen, id)
        }
    }

    // MARK: - Ngoài vectors: hành vi an toàn của bộ ghép khung và phiên

    func testReaderHandlesChunksAndGarbage() throws {
        let a = PhoneCommand.helloAck.encoded(), b = PhoneCommand.bottomBar("Lê Lợi").encoded()
        let stream: [UInt8] = [0x00, 0x6E, 0x41] + a + [0xFF] + b   // rác, magic cụt, khung, rác, khung
        var reader = FrameReader()
        var got: [Frame] = []
        for chunk in stride(from: 0, to: stream.count, by: 5) {
            got += reader.append(Array(stream[chunk..<min(chunk + 5, stream.count)]))
        }
        XCTAssertEqual(got, [PhoneCommand.helloAck, PhoneCommand.bottomBar("Lê Lợi")])
    }

    func testReaderSkipsBadCRC() throws {
        var bad = PhoneCommand.helloAck.encoded()
        bad[12] ^= 0xFF
        var reader = FrameReader()
        let got = reader.append(bad + PhoneCommand.initialize.encoded())
        XCTAssertEqual(got, [PhoneCommand.initialize])
        XCTAssertEqual(reader.badFrames, 1)
    }

    func testInitFallbackAfterTwoSeconds() {
        let s = LinkASession()
        _ = s.receive(Frame(command: 66, flag: 0, payload: Array("0000000000".utf8), direction: 3), now: 0)
        XCTAssertTrue(s.receive(Frame(command: 82, flag: 0, payload: [1, 0], direction: 3), now: 0.1).send.isEmpty)
        XCTAssertTrue(s.tick(now: 1.0).send.isEmpty)
        XCTAssertEqual(s.tick(now: 2.2).send.count, 9)
        XCTAssertTrue(s.tick(now: 3.0).send.isEmpty)
    }

    func testOneFrameInFlight() {
        let s = LinkASession()
        XCTAssertNil(s.makeMapFrame(jpeg: [1, 2, 3], now: 0), "chưa 55 thì không gửi khung")
        _ = s.receive(Frame(command: 55, flag: 0, payload: [1, 0], direction: 1), now: 0)
        let f = s.makeMapFrame(jpeg: Array(repeating: 7, count: 3000), now: 0)
        XCTAssertEqual(f?.payload.prefix(3).map { $0 }, [3, 1, 0])
        XCTAssertNil(s.makeMapFrame(jpeg: [1], now: 0.1), "đang chờ ACK")
        _ = s.receive(Frame(command: 80, flag: 0, payload: [1, 0], direction: 3), now: 0.3)
        XCTAssertNotNil(s.makeMapFrame(jpeg: [1], now: 0.4))
    }

    func testSmallJpegIsPadded() {
        let f = PhoneCommand.mapFrame(jpeg: Array(repeating: 9, count: 100), frameId: 5)
        XCTAssertEqual(f.payload.count, 3 + 2050)
    }

    func testBottomBarCutsOnCharacterBoundary() {
        let text = String(repeating: "Ợ", count: 100)          // 3 byte mỗi ký tự
        let p = PhoneCommand.bottomBar(text).payload
        XCTAssertEqual(p.count, 144)
        XCTAssertNotNil(String(bytes: p, encoding: .utf8))
    }
}
