import XCTest
@testable import DashCore

/// Các giá trị THẬT ghi trong maxdash/docs/protocol/observations.md (bike test 2026-10-25), viết thẳng bằng byte:
/// ODO raw `00 00 00 A3` → 16,3 km · param 1 byte 6 `AA` → 12,45 V · byte 14 `46` → 40 °C ·
/// ECU `01 04 00 00 03 18 E0 09` → 1248 · khi nổ máy ắc quy 14,28–14,43 V · xăng +101…+120 mỗi 10 s ≈ 0,4 L/h.
final class ObservedVectorsTests: XCTestCase {
    /// 271 dựng đúng như xe: `01 0F len24` + field 3 (ECU) + field 4 (ODO) + field 4 (param 1).
    private func packet271(odoRaw: [UInt8], param1: [UInt8]) -> [UInt8] {
        let odoBlock: [UInt8] = [0x08, 0x48, 0x12, UInt8(odoRaw.count)] + odoRaw       // {1: 72, 2: raw}
        let p1Block: [UInt8] = [0x08, 0x01, 0x12, UInt8(param1.count)] + param1       // {1: 1, 2: raw}
        let body: [UInt8] = [0x18, 0xE0, 0x09]
            + [0x22, UInt8(odoBlock.count)] + odoBlock
            + [0x22, UInt8(p1Block.count)] + p1Block
        let n = body.count
        return [0x01, 0x0F, UInt8(n >> 16), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + body
    }

    private func param1(rpm: UInt16 = 0, byte6: UInt8, byte14: UInt8) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 16)
        raw[0] = UInt8(rpm >> 8); raw[1] = UInt8(rpm & 0xFF)
        raw[6] = byte6; raw[14] = byte14
        return raw
    }

    func testObservedOdoBatteryCoolant() {
        let d = CCUVehicle.decode271(packet271(odoRaw: [0x00, 0x00, 0x00, 0xA3], param1: param1(byte6: 0xAA, byte14: 0x46)))
        XCTAssertEqual(d.odoKm ?? -1, 16.3, accuracy: 1e-9)
        XCTAssertEqual(d.batteryV ?? -1, 12.45, accuracy: 0.005)
        XCTAssertEqual(d.coolantC, 40)
        XCTAssertEqual(d.rpm, 0)
    }

    func testObservedEngineRunning() {
        // Nổ máy: 14,28 V = byte 195, 14,43 V = byte 197; nước 46 °C = 76; vòng tua 1645, 2120, 3042.
        let cases: [(UInt16, UInt8, UInt8, Double, Int)] = [(1645, 195, 70, 14.28, 40), (2120, 196, 74, 14.35, 44),
                                                           (3042, 197, 76, 14.43, 46)]
        for (rpm, b6, b14, volts, temp) in cases {
            let d = CCUVehicle.decode271(packet271(odoRaw: [0xA3], param1: param1(rpm: rpm, byte6: b6, byte14: b14)))
            XCTAssertEqual(d.batteryV ?? -1, volts, accuracy: 0.01)
            XCTAssertEqual(d.coolantC, temp)
            XCTAssertEqual(d.rpm, Int(rpm))
        }
    }

    func testOdoRawLengthsAreBigEndian() {
        XCTAssertEqual(CCUVehicle.decode271(packet271(odoRaw: [0xA3], param1: [])).odoKm, 16.3)
        XCTAssertEqual(CCUVehicle.decode271(packet271(odoRaw: [0x01, 0x00], param1: [])).odoKm, 25.6)   // 256, không phải 1
        XCTAssertEqual(CCUVehicle.decode271(packet271(odoRaw: [0x00, 0x07, 0xA1, 0x20], param1: [])).odoKm, 50_000.0)
    }

    func testShortParam1IsIgnored() {
        // Tài liệu: param 1 phải ≥ 16 byte và byte 6 ≠ 0.
        let d = CCUVehicle.decode271(packet271(odoRaw: [0xA3], param1: [UInt8](repeating: 0x50, count: 15)))
        XCTAssertNil(d.batteryV)
        XCTAssertNil(d.coolantC)
        XCTAssertNil(d.rpm)
        XCTAssertEqual(d.odoKm, 16.3)
    }

    func testObservedEcuListAndRequest() {
        XCTAssertEqual(CCUVehicle.ecuIds(answer260: [0x01, 0x04, 0x00, 0x00, 0x03, 0x18, 0xE0, 0x09]), [1248])
        // Yêu cầu 270: `01 0E len24` + `18 <ecu varint> 22 02 01 48` (len24 = độ dài protobuf, như 260).
        XCTAssertEqual(CCUCommand.vehicleDataRequest(ecu: 1248),
                       [0x01, 0x0E, 0x00, 0x00, 0x07, 0x18, 0xE0, 0x09, 0x22, 0x02, 0x01, 0x48])
    }

    func testObservedIgnition() {
        XCTAssertEqual(CCUMessage([0x01, 0x38, 0x01]), .ignition(on: true))
        XCTAssertEqual(CCUMessage([0x01, 0x38, 0x00]), .ignition(on: false))
        // Giá trị lạ không được hiểu thành "bật".
        if case .ignition? = CCUMessage([0x01, 0x38, 0x02]) { XCTFail("2 không phải bật/tắt") }
    }

    func testObservedFuelRateIsAboutPointFourLitresPerHour() {
        // +101…+120 mỗi 10 s (≈ 0,4 L/h) với ÷100 000: chỉ kiểm tra độ lớn. Thang này CHƯA có log đổ xăng xác nhận.
        var f = FuelMeter()
        var counter: UInt32 = 5_000
        f.update(counter: counter)
        for _ in 0..<360 { counter += 110; f.update(counter: counter) }    // 1 giờ, mỗi 10 s
        XCTAssertEqual(f.usedLitres, 0.396, accuracy: 0.001)
    }

    func testMphSpeedIsConvertedToKmh() {
        let s = LinkASession()
        let kmh = s.receive(Frame(command: 65, flag: 0, payload: [0x00, 40, 0], direction: 3), now: 0)
        XCTAssertEqual(kmh.events, [.speed(40)])
        let mph = s.receive(Frame(command: 65, flag: 0, payload: [0x01, 25, 0], direction: 3), now: 1)
        XCTAssertEqual(mph.events, [.speed(40)])   // 25 mph = 40,2 km/h
        // u16 little-endian ở byte 1–2: 00 01 → 256
        let big = s.receive(Frame(command: 65, flag: 0, payload: [0x00, 0x00, 0x01], direction: 3), now: 2)
        XCTAssertEqual(big.events, [.speed(256)])
    }
}
