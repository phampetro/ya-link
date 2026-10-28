import XCTest
@testable import DashCore

/// Link B (CCU): các ví dụ byte dựng tay từ docs/protocol/link-b-ccu.md.
final class CCUProtocolTests: XCTestCase {
    private let code = "AB12CD34EF56GH"     // 14 ký tự
    private let passkey = "123456"

    // MARK: - Bộ mã hoá protobuf riêng của test (độc lập với CCUProto.varint)

    private func pbVarint(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var x = v
        repeat {
            var byte = UInt8(x & 0x7F)
            x >>= 7
            if x != 0 { byte |= 0x80 }
            out.append(byte)
        } while x != 0
        return out
    }

    private func pbVarintField(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        pbVarint(field << 3 | 0) + pbVarint(value)
    }

    private func pbBytesField(_ field: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        pbVarint(field << 3 | 2) + pbVarint(UInt64(bytes.count)) + bytes
    }

    private func packet(cmd: UInt16, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        return [UInt8(cmd >> 8), UInt8(cmd & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + body
    }

    // MARK: - MFi

    func testAskPasskeyBytes() {
        XCTAssertEqual(CCUMFiFrame.askPasskey.encoded(), [0x01, 0x00, 0x00, 0x00, 0x02, 0x01, 0x39, 0x04])
    }

    func testPasskeyAnswerAcrossChunks() throws {
        let body = Array(code.utf8) + Array(passkey.utf8)
        XCTAssertEqual(body.count, 20)
        let answer: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x16, 0x01, 0x3A] + body + [0x04]
        XCTAssertEqual(CCUMFiFrame(cmd: 0x013A, body: body).encoded(), answer)

        let other: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x03, 0x01, 0x50, 0x07, 0x04]
        let stream: [UInt8] = [0xFF, 0x04] + other + answer
        var reader = CCUMFiReader()
        var frames: [CCUMFiFrame] = []
        var i = 0
        while i < stream.count {
            let end = min(i + 3, stream.count)
            frames += reader.append(Array(stream[i..<end]))
            i = end
        }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], CCUMFiFrame(cmd: 0x0150, body: [0x07]))
        XCTAssertEqual(frames[1].cmd, 0x013A)
        XCTAssertNil(CCUPasskey(answer: frames[0]))
        let p = try XCTUnwrap(CCUPasskey(answer: frames[1]))
        XCTAssertEqual(p.code, code)
        XCTAssertEqual(p.passkey, passkey)
    }

    // MARK: - Lệnh ngắn và xác thực

    func testShortCommands() {
        XCTAssertEqual(CCUCommand.connectAppId(seq: 3), [0x00, 0x02, 0x03, 0x00, 0x00, 0x12, 0x34])
        XCTAssertEqual(CCUCommand.ignitionRequest, [0x01, 0x37])
        XCTAssertEqual(CCUCommand.ecuListRequest, [0x01, 0x03])
        XCTAssertEqual(CCUCommand.fuelRequest, [0x01, 0x1F])
        XCTAssertEqual(CCUCommand.pingReply(to: [0x01, 0x35, 0xAA, 0xBB]), [0x01, 0x36, 0xAA, 0xBB])
        XCTAssertNil(CCUCommand.pingReply(to: [0x01, 0x37]))
        XCTAssertEqual(CCUCommand.language(seq: 4), [0x00, 0x0C, 0x04, 0x0F])

        let date = Date(timeIntervalSince1970: TimeInterval(0x0102_0304))
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(CCUCommand.time(seq: 5, date: date, timeZone: utc),
                       [0x00, 0x0A, 0x05, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04])
        let vn = TimeZone(secondsFromGMT: 7 * 3600)!          // +25200 = 0x6270
        XCTAssertEqual(CCUCommand.time(seq: 5, date: date, timeZone: vn),
                       [0x00, 0x0A, 0x05, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x65, 0x74])
    }

    func testAuthenticationV2Layout() {
        let auth = CCUCommand.authenticationV2(code: code, passkey: passkey)
        XCTAssertEqual(auth.count, 22)
        XCTAssertEqual(Array(auth[0..<2]), [0x01, 0x01])
        XCTAssertEqual(Array(auth[2..<16]), Array(code.utf8))
        XCTAssertEqual(Array(auth[16..<22]), Array(passkey.utf8))

        XCTAssertEqual(CCUMessage.authAccepted([0x01, 0x02, 0x01]), true)
        XCTAssertEqual(CCUMessage.authAccepted([0x01, 0x02, 0x00]), false)
        XCTAssertNil(CCUMessage.authAccepted([0x01, 0x38, 0x01]))
    }

    func testBikeMessages() {
        XCTAssertEqual(CCUMessage([0x01, 0x38, 0x00]), .ignition(on: false))
        XCTAssertEqual(CCUMessage([0x01, 0x38, 0x01]), .ignition(on: true))
        XCTAssertEqual(CCUMessage([0x01, 0x35, 0x12]), .ping)
        XCTAssertEqual(CCUMessage([0x00, 0x09]), .askTime)
        XCTAssertEqual(CCUMessage([0x00, 0x0B]), .askLanguage)
        // 1 000 000 = 0x000F4240 → LE 40 42 0F 00
        XCTAssertEqual(CCUMessage([0x01, 0x20, 0x40, 0x42, 0x0F, 0x00]), .fuelCounter(1_000_000))
        XCTAssertNil(CCUMessage([0x01]))
    }

    // MARK: - DDT V1 gửi

    func testChunkSize() {
        XCTAssertEqual(DDTSender.chunkSize(mtu: 512), 180)
        XCTAssertEqual(DDTSender.chunkSize(mtu: 100), 93)
        XCTAssertEqual(DDTSender.chunkSize(mtu: 10), 20)
    }

    func testIdCounterSkipsZero() {
        var c = DDTIdCounter()
        XCTAssertEqual(c.next(), 1)
        for _ in 0..<253 { _ = c.next() }
        XCTAssertEqual(c.next(), 255)
        XCTAssertEqual(c.next(), 1)
    }

    func testDDTSendSequence22Bytes() {
        let data: [UInt8] = (0..<22).map { UInt8($0) }
        var s = DDTSender(packet: data, id: 7, mtu: 27)     // mẩu 20 byte
        XCTAssertEqual(s.chunkSize, 20)
        XCTAssertEqual(s.next(.begin), .readHandshake)
        XCTAssertEqual(s.next(.handshakeRead), .writeStart([0x07, 0x00, 0x00, 0x16]))
        XCTAssertEqual(s.next(.startWritten), .wait)
        XCTAssertEqual(s.next(.handshakeNotify([0x01, 0x08])), .wait)          // id khác
        let head: [UInt8] = [0x07, 0x00, 0x00, 0x00]
        let firstChunk: [UInt8] = head + Array(data[0..<20])
        XCTAssertEqual(s.next(.handshakeNotify([0x01, 0x07])), .writeChunk(firstChunk))
        XCTAssertEqual(s.next(.chunkWritten), .writeChunk([0x07, 0x00, 0x00, 0x14, 0x14, 0x15]))
        XCTAssertEqual(s.next(.chunkWritten), .writeClose([0x00, 0x00]))
        XCTAssertEqual(s.next(.closeWritten), .wait)
        XCTAssertEqual(s.next(.handshakeNotify([0x00, 0x00])), .pause(0.08))
        XCTAssertFalse(s.isFinished)
        XCTAssertEqual(s.next(.pauseElapsed), .done)
        XCTAssertTrue(s.isFinished)
    }

    func testDDTSendError() {
        var s = DDTSender(packet: [1, 2, 3], id: 1, mtu: 512)
        XCTAssertEqual(s.next(.begin), .readHandshake)
        XCTAssertEqual(s.next(.error("ATT 13")), .failed("ATT 13"))
        XCTAssertTrue(s.isFinished)
    }

    // MARK: - DDT V1 nhận + danh sách ECU

    func testDDTV1ReceiveECUList() {
        // 260: 01 04 len24(3) + 18 E0 09
        let want: [UInt8] = [0x01, 0x04, 0x00, 0x00, 0x03, 0x18, 0xE0, 0x09]
        var r = DDTV1Receiver()
        XCTAssertEqual(r.announce([0x05, 0x00, 0x00, 0x08]), [0x01, 0x05])
        XCTAssertNil(r.chunk([0x06, 0x00, 0x00, 0x00, 0xEE]))                      // id khác: bỏ
        XCTAssertNil(r.chunk([0x05, 0x00, 0x00, 0x04, 0x03, 0x18, 0xE0, 0x09]))    // nửa sau tới trước
        let full = r.chunk([0x05, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00])
        XCTAssertEqual(full, want)
        XCTAssertEqual(CCUVehicle.ecuIds(answer260: want), [1248])
        XCTAssertEqual(ccuCommand(of: want), 260)
    }

    func testECUListPacked() {
        // field 3 packed: 1A 02 E0 09
        let p: [UInt8] = [0x01, 0x04, 0x00, 0x00, 0x04, 0x1A, 0x02, 0xE0, 0x09]
        XCTAssertEqual(CCUVehicle.ecuIds(answer260: p), [1248])
    }

    // MARK: - DDT V2 nhận

    func testDDTV2TwoFragments() {
        var r = DDTV2Receiver()
        XCTAssertNil(r.append([0x00, 0x09, 0x01, 0x01, 0xFF]))                    // thiếu mẩu 0: bỏ
        XCTAssertNil(r.append([0x00, 0x10, 0x00, 0x01, 0x01, 0x0F, 0x00]))
        XCTAssertEqual(r.append([0x00, 0x11, 0x01, 0x01, 0x00, 0x02, 0xAA]), [0x01, 0x0F, 0x00, 0x00, 0x02, 0xAA])
        XCTAssertEqual(r.append([0x00, 0x12, 0x00, 0x00, 0x42]), [0x42])            // một mẩu
    }

    // MARK: - Dữ liệu xe 270 / 271

    func testVehicleDataRequest() {
        XCTAssertEqual(CCUProto.varint(1248), [0xE0, 0x09])
        XCTAssertEqual(CCUCommand.vehicleDataRequest(ecu: 1248),
                       [0x01, 0x0E, 0x00, 0x00, 0x07, 0x18, 0xE0, 0x09, 0x22, 0x02, 0x01, 0x48])
    }

    func testDecode271() {
        // param 72: 32140 = 0x7D8C → 3214.0 km
        let block72 = pbVarintField(1, 72) + pbBytesField(2, [0x00, 0x00, 0x7D, 0x8C])
        // param 1: rpm 0x066D = 1645; byte6 = 175 → 175 × 18.75 / 256 = 12.817 V; byte14 = 122 → 92 °C
        var raw1 = [UInt8](repeating: 0, count: 16)
        raw1[0] = 0x06
        raw1[1] = 0x6D
        raw1[6] = 175
        raw1[14] = 122
        let block1 = pbVarintField(1, 1) + pbBytesField(2, raw1)
        let body = pbVarintField(3, 1248) + pbBytesField(4, block72) + pbBytesField(4, block1)
        let p = packet(cmd: 271, body)
        XCTAssertEqual(Array(p[0..<2]), [0x01, 0x0F])

        let d = CCUVehicle.decode271(p)
        XCTAssertEqual(d.odoKm ?? -1, 3214.0, accuracy: 1e-9)
        XCTAssertEqual(d.batteryV ?? -1, 12.8, accuracy: 0.1)
        XCTAssertEqual(d.coolantC, 92)
        XCTAssertEqual(d.rpm, 1645)
        XCTAssertNil(d.ignitionOn)

        // byte 6 = 0: param 1 không hợp lệ
        var raw0 = raw1
        raw0[6] = 0
        let p0 = packet(cmd: 271, pbBytesField(4, pbVarintField(1, 1) + pbBytesField(2, raw0)))
        let d0 = CCUVehicle.decode271(p0)
        XCTAssertNil(d0.batteryV)
        XCTAssertNil(d0.coolantC)
        XCTAssertNil(d0.odoKm)
    }

    func testDecode271OdoOnlyAndSentinel() {
        // Chỉ param 72 (không có param 1): vẫn ra ODO, pin / nước nil
        let only72 = packet(cmd: 271, pbVarintField(3, 1248) + pbBytesField(4, pbVarintField(1, 72) + pbBytesField(2, [0x00, 0x7D, 0x8C])))
        let d = CCUVehicle.decode271(only72)
        XCTAssertEqual(d.odoKm ?? -1, 3214.0, accuracy: 1e-9)
        XCTAssertNil(d.batteryV)
        XCTAssertNil(d.coolantC)

        // Toàn 0xFF: không phải ODO
        let ff = packet(cmd: 271, pbBytesField(4, pbVarintField(1, 72) + pbBytesField(2, [0xFF, 0xFF, 0xFF, 0xFF])))
        XCTAssertNil(CCUVehicle.decode271(ff).odoKm)

        // Param 1 ngắn hơn 16 byte: bỏ, không làm hỏng param 72 đi kèm
        let short1 = pbBytesField(4, pbVarintField(1, 1) + pbBytesField(2, [0x01, 0x02, 0x03]))
        let mixed = packet(cmd: 271, short1 + pbBytesField(4, pbVarintField(1, 72) + pbBytesField(2, [0x00, 0x7D, 0x8C])))
        let dm = CCUVehicle.decode271(mixed)
        XCTAssertEqual(dm.odoKm ?? -1, 3214.0, accuracy: 1e-9)
        XCTAssertNil(dm.coolantC)

        // Gói hỏng / rỗng: không crash, không có gì
        XCTAssertEqual(CCUVehicle.decode271([0x01, 0x0F]), CCUVehicleData())
        XCTAssertEqual(CCUVehicle.decode271(packet(cmd: 271, [0x22, 0x40, 0x01])), CCUVehicleData())
    }

    func testAuthAndIgnitionVectors() {
        XCTAssertEqual(CCUMessage([0x01, 0x02, 0x01]), .authResult(accepted: true))
        XCTAssertEqual(CCUMessage([0x01, 0x02, 0x00]), .authResult(accepted: false))
        XCTAssertEqual(CCUMessage([0x01, 0x38, 0x01]), .ignition(on: true))
        XCTAssertEqual(CCUMessage([0x01, 0x38, 0x00]), .ignition(on: false))
        XCTAssertEqual(CCUCommand.ignitionRequest, [0x01, 0x37])
        XCTAssertEqual(CCUCommand.ecuListRequest, [0x01, 0x03])
        XCTAssertEqual(CCUCommand.fuelRequest, [0x01, 0x1F])
        // ECU list tài liệu: `18 E0 09` sau 5 byte đầu → 1248
        XCTAssertEqual(CCUVehicle.ecuIds(answer260: [0x01, 0x04, 0x00, 0x00, 0x03, 0x18, 0xE0, 0x09]), [1248])
    }

    func testMerge() {
        var a = CCUVehicleData(ignitionOn: true, odoKm: 10)
        a.merge(CCUVehicleData(odoKm: 11, coolantC: 80))
        XCTAssertEqual(a, CCUVehicleData(ignitionOn: true, odoKm: 11, coolantC: 80))
    }

    // MARK: - Xăng

    func testFuelMeter() {
        var f = FuelMeter()
        XCTAssertEqual(f.update(counter: 1_000_000), 0, accuracy: 1e-9)
        XCTAssertEqual(f.update(counter: 1_050_000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.update(counter: 1_350_000), 0.5, accuracy: 1e-9)   // nhảy 3 L: bỏ
        XCTAssertEqual(f.update(counter: 1_360_000), 0.6, accuracy: 1e-9)
        XCTAssertEqual(f.update(counter: 5), 0.6, accuracy: 1e-9)           // bộ đếm lùi: bỏ
        XCTAssertEqual(f.update(counter: 10_005), 0.7, accuracy: 1e-9)
    }
}
