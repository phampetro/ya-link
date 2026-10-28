import Foundation

// MARK: - Public model

public struct MVTPoint: Equatable, Hashable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public enum MVTValue: Equatable {
    case string(String)
    case double(Double)
    case int(Int64)
    case bool(Bool)

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .double(let d): return String(d)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

public struct MVTFeature: Equatable {
    public enum Kind: Equatable { case point, line, polygon, unknown }
    public var id: UInt64?
    public var kind: Kind
    public var properties: [String: MVTValue]
    /// One array per MoveTo part (points: each point its own part; lines: each linestring; polygons: each ring).
    public var geometry: [[MVTPoint]]

    public init(id: UInt64? = nil, kind: Kind, properties: [String: MVTValue], geometry: [[MVTPoint]]) {
        self.id = id; self.kind = kind; self.properties = properties; self.geometry = geometry
    }
}

public struct MVTLayer: Equatable {
    public var name: String
    public var extent: Int
    public var features: [MVTFeature]
    public init(name: String, extent: Int = 4096, features: [MVTFeature] = []) {
        self.name = name; self.extent = extent; self.features = features
    }
}

public struct MVTTile: Equatable {
    public var layers: [String: MVTLayer]
    public init(layers: [String: MVTLayer] = [:]) { self.layers = layers }
}

public enum MVTError: Error, Equatable {
    case gzipped
    case truncated
    case malformed
}

// MARK: - Decoder

public enum MVT {
    public static func decode(_ data: Data) throws -> MVTTile {
        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B { throw MVTError.gzipped }
        var r = PBReader(bytes: bytes[...])
        var tile = MVTTile()
        while !r.atEnd {
            let (field, wire) = try r.readKey()
            if field == 3 && wire == 2 {
                let layer = try decodeLayer(try r.readBytes())
                tile.layers[layer.name] = layer
            } else {
                try r.skip(wire)
            }
        }
        return tile
    }

    private struct RawFeature {
        var id: UInt64?
        var tags: [UInt32] = []
        var type: Int = 0
        var geometry: [UInt32] = []
    }

    private static func decodeLayer(_ slice: ArraySlice<UInt8>) throws -> MVTLayer {
        var r = PBReader(bytes: slice)
        var name = ""
        var extent = 4096
        var keys: [String] = []
        var values: [MVTValue] = []
        var raws: [RawFeature] = []
        while !r.atEnd {
            let (field, wire) = try r.readKey()
            switch (field, wire) {
            case (1, 2): name = try r.readString()
            case (2, 2): raws.append(try decodeRawFeature(try r.readBytes()))
            case (3, 2): keys.append(try r.readString())
            case (4, 2): values.append(try decodeValue(try r.readBytes()))
            case (5, 0): extent = Int(truncatingIfNeeded: try r.readVarint())
            default: try r.skip(wire)
            }
        }
        var features: [MVTFeature] = []
        features.reserveCapacity(raws.count)
        for raw in raws {
            var props: [String: MVTValue] = [:]
            var i = 0
            while i + 1 < raw.tags.count {
                let k = Int(raw.tags[i]), v = Int(raw.tags[i + 1])
                if k < keys.count && v < values.count { props[keys[k]] = values[v] }
                i += 2
            }
            let kind: MVTFeature.Kind
            switch raw.type {
            case 1: kind = .point
            case 2: kind = .line
            case 3: kind = .polygon
            default: kind = .unknown
            }
            features.append(MVTFeature(id: raw.id, kind: kind, properties: props,
                                       geometry: decodeGeometry(raw.geometry, kind: kind)))
        }
        return MVTLayer(name: name, extent: extent, features: features)
    }

    private static func decodeRawFeature(_ slice: ArraySlice<UInt8>) throws -> RawFeature {
        var r = PBReader(bytes: slice)
        var f = RawFeature()
        while !r.atEnd {
            let (field, wire) = try r.readKey()
            switch (field, wire) {
            case (1, 0): f.id = try r.readVarint()
            case (2, 2): f.tags = try r.readPackedUInt32()
            case (2, 0): f.tags.append(UInt32(truncatingIfNeeded: try r.readVarint()))
            case (3, 0): f.type = Int(truncatingIfNeeded: try r.readVarint())
            case (4, 2): f.geometry = try r.readPackedUInt32()
            case (4, 0): f.geometry.append(UInt32(truncatingIfNeeded: try r.readVarint()))
            default: try r.skip(wire)
            }
        }
        return f
    }

    private static func decodeValue(_ slice: ArraySlice<UInt8>) throws -> MVTValue {
        var r = PBReader(bytes: slice)
        var value: MVTValue = .string("")
        while !r.atEnd {
            let (field, wire) = try r.readKey()
            switch (field, wire) {
            case (1, 2): value = .string(try r.readString())
            case (2, 5): value = .double(Double(Float(bitPattern: try r.readFixed32())))
            case (3, 1): value = .double(Double(bitPattern: try r.readFixed64()))
            case (4, 0): value = .int(Int64(bitPattern: try r.readVarint()))
            case (5, 0): value = .int(Int64(bitPattern: try r.readVarint()))
            case (6, 0):
                let u = try r.readVarint()
                value = .int(Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1))))
            case (7, 0): value = .bool(try r.readVarint() != 0)
            default: try r.skip(wire)
            }
        }
        return value
    }

    private static func zigzag(_ v: UInt32) -> Int {
        return Int(Int32(bitPattern: (v >> 1) ^ (0 &- (v & 1))))
    }

    private static func decodeGeometry(_ cmds: [UInt32], kind: MVTFeature.Kind) -> [[MVTPoint]] {
        var parts: [[MVTPoint]] = []
        var current: [MVTPoint] = []
        var x = 0, y = 0
        var i = 0
        while i < cmds.count {
            let cmdInt = cmds[i]; i += 1
            let cmd = cmdInt & 0x7
            let count = Int(cmdInt >> 3)
            switch cmd {
            case 1, 2:
                for _ in 0..<count {
                    guard i + 1 < cmds.count else { i = cmds.count; break }
                    x += zigzag(cmds[i]); y += zigzag(cmds[i + 1]); i += 2
                    let p = MVTPoint(x: x, y: y)
                    if cmd == 1 {
                        if kind == .point {
                            parts.append([p])
                        } else {
                            if !current.isEmpty { parts.append(current) }
                            current = [p]
                        }
                    } else {
                        current.append(p)
                    }
                }
            case 7:
                if let first = current.first, current.last != first { current.append(first) }
                if !current.isEmpty { parts.append(current) }
                current = []
            default:
                i = cmds.count // unknown command: stop
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - Minimal protobuf reader

struct PBReader {
    let bytes: ArraySlice<UInt8>
    var pos: Int

    init(bytes: ArraySlice<UInt8>) { self.bytes = bytes; self.pos = bytes.startIndex }

    var atEnd: Bool { pos >= bytes.endIndex }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < bytes.endIndex else { throw MVTError.truncated }
            let b = bytes[pos]; pos += 1
            if shift < 64 { result |= UInt64(b & 0x7F) << shift }
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 70 { throw MVTError.malformed }
        }
    }

    mutating func readKey() throws -> (field: Int, wire: Int) {
        let k = try readVarint()
        return (Int(truncatingIfNeeded: k >> 3), Int(k & 0x7))
    }

    mutating func readFixed32() throws -> UInt32 {
        guard pos + 4 <= bytes.endIndex else { throw MVTError.truncated }
        var v: UInt32 = 0
        for j in 0..<4 { v |= UInt32(bytes[pos + j]) << (8 * UInt32(j)) }
        pos += 4
        return v
    }

    mutating func readFixed64() throws -> UInt64 {
        guard pos + 8 <= bytes.endIndex else { throw MVTError.truncated }
        var v: UInt64 = 0
        for j in 0..<8 { v |= UInt64(bytes[pos + j]) << (8 * UInt64(j)) }
        pos += 8
        return v
    }

    mutating func readBytes() throws -> ArraySlice<UInt8> {
        let len = try readVarint()
        guard len <= UInt64(bytes.endIndex - pos) else { throw MVTError.truncated }
        let end = pos + Int(len)
        let s = bytes[pos..<end]
        pos = end
        return s
    }

    mutating func readString() throws -> String {
        let s = try readBytes()
        return String(decoding: s, as: UTF8.self)
    }

    mutating func readPackedUInt32() throws -> [UInt32] {
        var sub = PBReader(bytes: try readBytes())
        var out: [UInt32] = []
        while !sub.atEnd { out.append(UInt32(truncatingIfNeeded: try sub.readVarint())) }
        return out
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try readVarint()
        case 1: guard pos + 8 <= bytes.endIndex else { throw MVTError.truncated }; pos += 8
        case 2: _ = try readBytes()
        case 5: guard pos + 4 <= bytes.endIndex else { throw MVTError.truncated }; pos += 4
        default: throw MVTError.malformed
        }
    }
}
