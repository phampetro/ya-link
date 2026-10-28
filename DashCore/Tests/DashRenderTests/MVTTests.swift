import XCTest
import Foundation
@testable import DashRender

/// Tiny protobuf writer for hand-encoding test tiles.
private struct PBWriter {
    var buf: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 { buf.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        buf.append(UInt8(v))
    }
    mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }
    mutating func uint(_ field: Int, _ v: UInt64) { key(field, 0); varint(v) }
    mutating func lenField(_ field: Int, _ b: [UInt8]) { key(field, 2); varint(UInt64(b.count)); buf.append(contentsOf: b) }
    mutating func string(_ field: Int, _ s: String) { lenField(field, Array(s.utf8)) }
    mutating func packed(_ field: Int, _ values: [UInt32]) {
        var inner = PBWriter()
        for v in values { inner.varint(UInt64(v)) }
        lenField(field, inner.buf)
    }
}

private func zz(_ v: Int) -> UInt32 { UInt32(bitPattern: Int32((v << 1) ^ (v >> 63))) }
private func cmd(_ id: UInt32, _ count: UInt32) -> UInt32 { (count << 3) | id }

private func feature(id: UInt64, type: UInt64, tags: [UInt32], geometry: [UInt32]) -> [UInt8] {
    var w = PBWriter()
    w.uint(1, id)
    w.packed(2, tags)
    w.uint(3, type)
    w.packed(4, geometry)
    return w.buf
}

private func stringValue(_ s: String) -> [UInt8] { var w = PBWriter(); w.string(1, s); return w.buf }
private func uintValue(_ v: UInt64) -> [UInt8] { var w = PBWriter(); w.uint(5, v); return w.buf }

private func makeTile() -> Data {
    // transportation: LineString (2,2) -> (2,10) -> (10,10), class=primary
    var transport = PBWriter()
    transport.uint(15, 2)
    transport.string(1, "transportation")
    transport.lenField(2, feature(id: 1, type: 2, tags: [0, 0], geometry: [
        cmd(1, 1), zz(2), zz(2),
        cmd(2, 2), zz(0), zz(8), zz(8), zz(0),
    ]))
    transport.string(3, "class")
    transport.lenField(4, stringValue("primary"))
    transport.uint(5, 4096)

    // water: Polygon ring (3,6) -> (8,6) -> (3,12) -> close, class=lake rank=42
    var water = PBWriter()
    water.uint(15, 2)
    water.string(1, "water")
    water.lenField(2, feature(id: 7, type: 3, tags: [0, 0, 1, 1], geometry: [
        cmd(1, 1), zz(3), zz(6),
        cmd(2, 2), zz(5), zz(0), zz(-5), zz(6),
        cmd(7, 1),
    ]))
    water.string(3, "class")
    water.string(3, "rank")
    water.lenField(4, stringValue("lake"))
    water.lenField(4, uintValue(42))
    water.uint(5, 4096)

    var tile = PBWriter()
    tile.lenField(3, transport.buf)
    tile.lenField(3, water.buf)
    tile.uint(99, 1) // unknown field must be skipped
    return Data(tile.buf)
}

final class MVTTests: XCTestCase {
    func testDecodeLineAndPolygon() throws {
        let tile = try MVT.decode(makeTile())
        XCTAssertEqual(Set(tile.layers.keys), ["transportation", "water"])

        let t = try XCTUnwrap(tile.layers["transportation"])
        XCTAssertEqual(t.extent, 4096)
        XCTAssertEqual(t.features.count, 1)
        let line = t.features[0]
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(line.id, 1)
        XCTAssertEqual(line.properties["class"], .string("primary"))
        XCTAssertEqual(line.properties["class"]?.stringValue, "primary")
        XCTAssertEqual(line.geometry, [[MVTPoint(x: 2, y: 2), MVTPoint(x: 2, y: 10), MVTPoint(x: 10, y: 10)]])

        let w = try XCTUnwrap(tile.layers["water"])
        XCTAssertEqual(w.features.count, 1)
        let poly = w.features[0]
        XCTAssertEqual(poly.kind, .polygon)
        XCTAssertEqual(poly.properties["class"], .string("lake"))
        XCTAssertEqual(poly.properties["rank"], .int(42))
        XCTAssertEqual(poly.geometry, [[MVTPoint(x: 3, y: 6), MVTPoint(x: 8, y: 6),
                                        MVTPoint(x: 3, y: 12), MVTPoint(x: 3, y: 6)]])
    }

    func testGzipRejected() {
        XCTAssertThrowsError(try MVT.decode(Data([0x1F, 0x8B, 0x08, 0x00]))) { err in
            XCTAssertEqual(err as? MVTError, .gzipped)
        }
    }

    func testEmptyAndTruncated() throws {
        XCTAssertTrue(try MVT.decode(Data()).layers.isEmpty)
        XCTAssertThrowsError(try MVT.decode(Data([0x1A, 0x10, 0x0A]))) // layer length exceeds data
    }

    func testMercator() {
        // Ho Chi Minh City, District 1.
        // x = (106.7009 + 180) / 360 * 2^14 = 13048.08 -> 13048
        // y = (1 - ln(tan(lat) + sec(lat)) / pi) / 2 * 2^14, ln(...) = 0.189211 -> 7698.6 -> 7698
        let p = MapPoint(lat: 10.7769, lon: 106.7009)
        let t = Mercator.tile(p, z: 14)
        XCTAssertEqual(t.x, 13048)
        XCTAssertEqual(t.y, 7698)

        let origin = Mercator.worldPixel(MapPoint(lat: 0, lon: 0), zoom: 0)
        XCTAssertEqual(origin.x, 128, accuracy: 1e-9)
        XCTAssertEqual(origin.y, 128, accuracy: 1e-9)

        let w = Mercator.worldPixel(p, zoom: 15.5)
        let back = Mercator.point(worldX: w.x, worldY: w.y, zoom: 15.5)
        XCTAssertEqual(back.lat, p.lat, accuracy: 1e-9)
        XCTAssertEqual(back.lon, p.lon, accuracy: 1e-9)

        XCTAssertEqual(Mercator.metersPerPixel(lat: 0, zoom: 0), 156_543.03392, accuracy: 0.01)
    }

    func testTileStoreInsertForTesting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TileStore(cacheDirectory: dir)
        let tile = try MVT.decode(makeTile())
        store.insertForTesting(tile, z: 14, x: 13048, y: 7698)
        XCTAssertEqual(store.tile(z: 14, x: 13048, y: 7698), tile)
        // Overzoom maps to the z14 parent.
        XCTAssertEqual(store.tile(z: 16, x: 13048 * 4 + 1, y: 7698 * 4 + 3), tile)
    }
}
