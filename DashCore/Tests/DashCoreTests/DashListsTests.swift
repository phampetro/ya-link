import XCTest
@testable import DashCore

final class DashListsTests: XCTestCase {
    private func bike(_ cmd: UInt8, _ payload: [UInt8] = []) -> Frame {
        Frame(command: cmd, flag: 0, payload: payload, direction: 0x03)
    }

    func testListCount() {
        XCTAssertEqual(PhoneCommand.listCount(listId: 3, count: 5),
                       Frame(command: 7, flag: 1, payload: [5, 0, 0]))
        XCTAssertEqual(PhoneCommand.listCount(listId: 4, count: 8),
                       Frame(command: 8, flag: 1, payload: [8, 0, 0]))
        XCTAssertEqual(PhoneCommand.listCount(listId: 4, count: 99).payload, [30, 0, 0])
    }

    func testListItemBytes() {
        // "Nhà" = 4E 68 C3 A0; 1.0f = 00 00 80 3F
        let f = PhoneCommand.listItem(listId: 3, index: 2, octant: 1, name: "Nhà", distance: 1, unit: "km")
        XCTAssertEqual(f.command, 98)
        XCTAssertEqual(f.flag, 1)
        XCTAssertEqual(f.payload, [0x02, 0x00, 0x03, 0x00, 0x01, 0x04, 0x02,
                                   0x00, 0x00, 0x80, 0x3F, 0x6B, 0x6D, 0x4E, 0x68, 0xC3, 0xA0])
        let g = PhoneCommand.listItem(listId: 4, index: 300, octant: 8, name: "A", distance: 1500, unit: "m")
        XCTAssertEqual(g.command, 99)
        // 1500.0f = 0x44BB8000
        XCTAssertEqual(g.payload, [0x2C, 0x01, 0x04, 0x00, 0x08, 0x01, 0x01,
                                   0x00, 0x80, 0xBB, 0x44, 0x6D, 0x41])
    }

    func testNameTruncatedOnCharacterBoundary() {
        let twoByte = String(repeating: "à", count: 100)       // 200 bytes -> 128
        let f = PhoneCommand.listItem(listId: 3, index: 0, octant: 0, name: twoByte, distance: 0, unit: "m")
        XCTAssertEqual(f.payload[5], 128)
        XCTAssertEqual(f.payload.count, 11 + 1 + 128)
        let threeByte = String(repeating: "€", count: 50)       // 150 bytes -> 126 (42 chars)
        let g = PhoneCommand.listItem(listId: 3, index: 0, octant: 0, name: threeByte, distance: 0, unit: "m")
        XCTAssertEqual(g.payload[5], 126)
        let nameBytes = Array(g.payload[12...])
        XCTAssertNotNil(String(bytes: nameBytes, encoding: .utf8))
        XCTAssertEqual(String(decoding: nameBytes, as: UTF8.self).count, 42)
    }

    func testOctant() {
        XCTAssertEqual(DashLists.octant(bearingDeg: 0), 1)
        XCTAssertEqual(DashLists.octant(bearingDeg: 22.4), 1)
        XCTAssertEqual(DashLists.octant(bearingDeg: 22.5), 2)
        XCTAssertEqual(DashLists.octant(bearingDeg: 45), 2)
        XCTAssertEqual(DashLists.octant(bearingDeg: 90), 3)
        XCTAssertEqual(DashLists.octant(bearingDeg: 135), 4)
        XCTAssertEqual(DashLists.octant(bearingDeg: 180), 5)
        XCTAssertEqual(DashLists.octant(bearingDeg: 225), 6)
        XCTAssertEqual(DashLists.octant(bearingDeg: 270), 7)
        XCTAssertEqual(DashLists.octant(bearingDeg: 315), 8)
        XCTAssertEqual(DashLists.octant(bearingDeg: 350), 1)
        XCTAssertEqual(DashLists.octant(bearingDeg: -10), 1)
        XCTAssertEqual(DashLists.bearing(fromLat: 10, lon: 106, toLat: 11, lon: 106), 0, accuracy: 0.01)
        XCTAssertEqual(DashLists.bearing(fromLat: 0, lon: 106, toLat: 0, lon: 107), 90, accuracy: 0.01)
    }

    func testFormatDistance() {
        XCTAssertEqual(DashLists.formatDistance(meters: 0).unit, "m")
        XCTAssertEqual(DashLists.formatDistance(meters: 349.6).value, 350)
        let k = DashLists.formatDistance(meters: 1530)
        XCTAssertEqual(k.unit, "km")
        XCTAssertEqual(k.value, 1.5, accuracy: 0.001)
    }

    func testFramesCapAtThirty() {
        let items = (0..<40).map { DashListItem(name: "P\($0)", distanceMeters: Double($0)) }
        let fs = DashLists.frames(listId: 4, items: items)
        XCTAssertEqual(fs.count, 31)
        XCTAssertEqual(fs[0].command, 8)
        XCTAssertEqual(fs[0].payload, [30, 0, 0])
        XCTAssertTrue(fs.dropFirst().allSatisfy { $0.command == 99 })
    }

    func testTurnBoxAndEta() {
        let f = PhoneCommand.turnBox(icon: 2, distance: 1, unit: "m", road: "AB")
        XCTAssertEqual(f, Frame(command: 4, flag: 1, payload: [2, 0x00, 0x00, 0x80, 0x3F, 1, 2, 0x6D, 0x41, 0x42]))
        XCTAssertEqual(PhoneCommand.eta(minutes: 300), Frame(command: 1, flag: 1, payload: [0x2C, 0x01, 0, 0]))
    }

    // MARK: - Session

    func testSessionListEvents() {
        let s = LinkASession()
        var r = s.receive(bike(55, [3]), now: 0)
        XCTAssertEqual(r.events, [.listOpened(3)])
        XCTAssertEqual(r.send, [])
        XCTAssertEqual(s.openListId, 3)
        r = s.receive(bike(56, [3, 0]), now: 0)
        XCTAssertEqual(r.events, [.listClosed(3)])
        XCTAssertNil(s.openListId)

        s.navigating = true
        r = s.receive(bike(55, [4, 0]), now: 0)
        XCTAssertEqual(r.events, [.listOpened(4)])
        XCTAssertEqual(r.send, [PhoneCommand.navigationState(navigating: false)])
        r = s.receive(bike(56, [4]), now: 0)
        XCTAssertEqual(r.events, [.listClosed(4)])
        XCTAssertEqual(r.send, [PhoneCommand.navigationState(navigating: true)])
    }

    func testSessionSelectionAndRouteCommands() {
        let s = LinkASession()
        XCTAssertEqual(s.receive(bike(48, [2, 0, 3, 0, 0]), now: 0).events,
                       [.listSelected(index: 2, listId: 3, option: 0)])
        XCTAssertEqual(s.receive(bike(53), now: 0).events, [.goHome])
        XCTAssertEqual(s.receive(bike(54), now: 0).events, [.goWork])
        XCTAssertEqual(s.receive(bike(49), now: 0).events, [.stopRoute])
    }

    func testPauseAndShowFramesUnchanged() {
        let s = LinkASession()
        XCTAssertEqual(s.receive(bike(55, [1, 0]), now: 0).events, [.showFrames])
        XCTAssertEqual(s.receive(bike(56, [0, 0]), now: 0).events, [.pause])
        XCTAssertEqual(s.receive(bike(56, [0]), now: 0).events, [.pause])
    }

    func testUnknownCommandDoesNotCrash() {
        let s = LinkASession()
        let r = s.receive(bike(120, [1, 2, 3]), now: 0)
        XCTAssertEqual(r.events.count, 1)
        // 48 quá ngắn cũng chỉ là "khác"
        XCTAssertEqual(s.receive(bike(48, [1]), now: 0).events.count, 1)
    }

    func testSetSavedSendsOnlyAfterInitAndOnChange() {
        let s = LinkASession()
        XCTAssertEqual(s.setSaved(home: true, work: false), [])
        XCTAssertTrue(s.homeSaved)
        // sau khi init
        _ = s.receive(Frame(command: 83, flag: 1, payload: [UInt8](repeating: 0x0A, count: 16), direction: 0x03), now: 0)
        _ = s.receive(bike(82, [1, 0]), now: 0)
        XCTAssertTrue(s.initSent)
        XCTAssertEqual(s.setSaved(home: true, work: true), [PhoneCommand.workSaved(true)])
        XCTAssertEqual(s.setSaved(home: true, work: true), [])
        let show = s.receive(bike(55, [1, 0]), now: 0).send
        XCTAssertTrue(show.contains(PhoneCommand.homeSaved(true)))
        XCTAssertTrue(show.contains(PhoneCommand.workSaved(true)))
    }

    // MARK: - Báo độ trễ (16) sau ACK

    func testAckWithMeasuredRttSendsLatency() {
        let s = LinkASession()
        _ = s.receive(bike(55, [1, 0]), now: 0)
        XCTAssertNotNil(s.makeMapFrame(jpeg: [0xFF, 0xD8], now: 10))
        XCTAssertFalse(s.canSendFrame)                       // một khung chờ ACK
        let r = s.receive(bike(80, [1, 0]), now: 10.45)      // rtt 450 ms → 4
        XCTAssertEqual(r.events, [.ack(id: 1, roundTripMs: 450)])
        XCTAssertEqual(r.send, [PhoneCommand.latency(milliseconds: 450)])
        XCTAssertEqual(r.send.first?.payload, [4, 0])
        XCTAssertEqual(r.send.first?.command, 16)
        XCTAssertTrue(s.canSendFrame)                        // ACK mở đường cho khung kế
    }

    func testLatencyIsCappedAt255() {
        let s = LinkASession()
        _ = s.receive(bike(55, [1, 0]), now: 0)
        s.ackTimeout = 1000
        XCTAssertNotNil(s.makeMapFrame(jpeg: [0xFF, 0xD8], now: 0))
        let r = s.receive(bike(80, [1, 0]), now: 100)        // 100 000 ms
        XCTAssertEqual(r.send.first?.payload, [255, 0])
    }

    func testAckWithNothingInFlightSendsNoLatency() {
        let s = LinkASession()
        _ = s.receive(bike(55, [1, 0]), now: 0)
        let r = s.receive(bike(80, [1, 0]), now: 5)
        XCTAssertEqual(r.events, [.ack(id: 1, roundTripMs: nil)])
        XCTAssertEqual(r.send, [])
    }
}
