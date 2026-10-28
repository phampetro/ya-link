import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MapPoint: Equatable, Hashable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

/// Web Mercator (EPSG:3857) helpers, XYZ tile scheme (y grows southwards).
public enum Mercator {
    public static let maxLatitude = 85.05112878

    public static func worldPixel(_ p: MapPoint, zoom: Double, tileSize: Double = 256) -> (x: Double, y: Double) {
        let scale = tileSize * pow(2.0, zoom)
        let lat = min(max(p.lat, -maxLatitude), maxLatitude) * .pi / 180
        let x = (p.lon + 180) / 360 * scale
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * scale
        return (x, y)
    }

    public static func point(worldX x: Double, worldY y: Double, zoom: Double, tileSize: Double = 256) -> MapPoint {
        let scale = tileSize * pow(2.0, zoom)
        let lon = x / scale * 360 - 180
        let n = Double.pi * (1 - 2 * y / scale)
        let lat = atan(sinh(n)) * 180 / .pi
        return MapPoint(lat: lat, lon: lon)
    }

    /// Ground resolution for 256 px tiles.
    public static func metersPerPixel(lat: Double, zoom: Double) -> Double {
        return 156_543.033_92 * cos(lat * .pi / 180) / pow(2.0, zoom)
    }

    public static func tile(_ p: MapPoint, z: Int) -> (x: Int, y: Int) {
        let n = 1 << max(0, z)
        let w = worldPixel(p, zoom: Double(z), tileSize: 1)
        let x = min(max(Int(floor(w.x)), 0), n - 1)
        let y = min(max(Int(floor(w.y)), 0), n - 1)
        return (x, y)
    }
}

/// Thread-safe vector tile cache: memory LRU -> disk -> network (OpenFreeMap).
public final class TileStore {
    public static let maxZoom = 14
    public static let tileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!

    private struct Key: Hashable { let z: Int, x: Int, y: Int }

    private let lock = NSLock()
    private let session: URLSession
    private let cacheDirectory: URL
    private let memoryCapacity = 150
    private let maxConcurrent = 6

    private var memory: [Key: (tile: MVTTile, stamp: UInt64)] = [:]
    private var clock: UInt64 = 0
    private var queued: [Key] = []
    private var queuedSet = Set<Key>()
    private var active = Set<Key>()
    private var failures: [Key: Date] = [:]
    private var template: String?
    private var templateLoading = false
    private var templateFailedAt: Date?
    private var _onTileLoaded: (() -> Void)?

    /// Called on the main queue whenever a tile finished downloading.
    public var onTileLoaded: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onTileLoaded }
        set { lock.lock(); _onTileLoaded = newValue; lock.unlock() }
    }

    public init(cacheDirectory: URL? = nil, session: URLSession = .shared) {
        self.session = session
        if let dir = cacheDirectory {
            self.cacheDirectory = dir
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = caches.appendingPathComponent("tiles", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: Public API

    /// Returns the decoded tile if available (memory, then disk); otherwise nil and schedules a download.
    public func tile(z: Int, x: Int, y: Int) -> MVTTile? {
        guard let key = normalize(z: z, x: x, y: y) else { return nil }
        lock.lock()
        if let hit = memory[key] {
            clock += 1
            memory[key] = (hit.tile, clock)
            lock.unlock()
            return hit.tile
        }
        lock.unlock()

        if let data = try? Data(contentsOf: fileURL(key)), let decoded = try? MVT.decode(data) {
            lock.lock(); store(decoded, key); lock.unlock()
            return decoded
        }
        enqueue(key, priority: true)
        return nil
    }

    public func prefetch(around center: MapPoint, z: Int, radius: Int) {
        let zz = min(max(z, 0), TileStore.maxZoom)
        let c = Mercator.tile(center, z: zz)
        let r = max(0, radius)
        var keys: [Key] = []
        for dy in -r...r { for dx in -r...r {
            if let k = normalize(z: zz, x: c.x + dx, y: c.y + dy) { keys.append(k) }
        } }
        keys.sort { abs($0.x - c.x) + abs($0.y - c.y) < abs($1.x - c.x) + abs($1.y - c.y) }
        for k in keys { prefetchKey(k) }
    }

    public func prefetch(route: [MapPoint], zooms: [Int]) {
        guard !route.isEmpty else { return }
        for z in Set(zooms.map { min(max($0, 0), TileStore.maxZoom) }).sorted() {
            var seen = Set<Key>()
            var ordered: [Key] = []
            func add(_ wx: Double, _ wy: Double) {
                if let k = normalize(z: z, x: Int(floor(wx)), y: Int(floor(wy))), seen.insert(k).inserted {
                    ordered.append(k)
                }
            }
            var prev = Mercator.worldPixel(route[0], zoom: Double(z), tileSize: 1)
            add(prev.x, prev.y)
            for p in route.dropFirst() {
                let cur = Mercator.worldPixel(p, zoom: Double(z), tileSize: 1)
                let dist = max(abs(cur.x - prev.x), abs(cur.y - prev.y))
                let steps = min(10_000, max(1, Int(ceil(dist * 4))))
                for s in 1...steps {
                    let t = Double(s) / Double(steps)
                    add(prev.x + (cur.x - prev.x) * t, prev.y + (cur.y - prev.y) * t)
                }
                prev = cur
                if ordered.count > 5_000 { break }
            }
            for k in ordered { prefetchKey(k) }
        }
    }

    public func insertForTesting(_ tile: MVTTile, z: Int, x: Int, y: Int) {
        guard let key = normalize(z: z, x: x, y: y) else { return }
        lock.lock(); store(tile, key); lock.unlock()
    }

    // MARK: Internals

    private func normalize(z: Int, x: Int, y: Int) -> Key? {
        let zz = min(max(z, 0), TileStore.maxZoom)
        var xx = x, yy = y
        if zz < z { // caller asked for an overzoomed tile: use the covering parent
            let shift = z - zz
            xx = x >> shift; yy = y >> shift
        }
        let n = 1 << zz
        guard yy >= 0 && yy < n else { return nil }
        xx = ((xx % n) + n) % n
        return Key(z: zz, x: xx, y: yy)
    }

    private func fileURL(_ k: Key) -> URL {
        return cacheDirectory.appendingPathComponent("\(k.z)/\(k.x)/\(k.y).pbf")
    }

    /// Must hold lock.
    private func store(_ tile: MVTTile, _ key: Key) {
        clock += 1
        memory[key] = (tile, clock)
        if memory.count > memoryCapacity {
            let overflow = memory.count - memoryCapacity
            let oldest = memory.sorted { $0.value.stamp < $1.value.stamp }.prefix(overflow)
            for (k, _) in oldest { memory.removeValue(forKey: k) }
        }
    }

    private func prefetchKey(_ k: Key) {
        lock.lock()
        let inMemory = memory[k] != nil
        lock.unlock()
        if inMemory || FileManager.default.fileExists(atPath: fileURL(k).path) { return }
        enqueue(k, priority: false)
    }

    private func enqueue(_ key: Key, priority: Bool) {
        lock.lock()
        if active.contains(key) { lock.unlock(); return }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 30 { lock.unlock(); return }
        if queuedSet.contains(key) {
            if priority, let i = queued.firstIndex(of: key) { queued.remove(at: i); queued.insert(key, at: 0) }
        } else {
            queuedSet.insert(key)
            if priority { queued.insert(key, at: 0) } else { queued.append(key) }
        }
        lock.unlock()
        pump()
    }

    private func pump() {
        lock.lock()
        guard let tmpl = template else {
            let canRetry = templateFailedAt.map { Date().timeIntervalSince($0) > 15 } ?? true
            let start = !templateLoading && canRetry
            if start { templateLoading = true }
            lock.unlock()
            if start { loadTemplate() }
            return
        }
        var starts: [Key] = []
        while active.count < maxConcurrent, !queued.isEmpty {
            let k = queued.removeFirst()
            queuedSet.remove(k)
            active.insert(k)
            starts.append(k)
        }
        lock.unlock()
        for k in starts { download(k, template: tmpl) }
    }

    private func loadTemplate() {
        session.dataTask(with: TileStore.tileJSONURL) { [weak self] data, _, _ in
            guard let self = self else { return }
            var found: String?
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tiles = obj["tiles"] as? [String], let first = tiles.first {
                found = first
            }
            self.lock.lock()
            self.templateLoading = false
            if let f = found { self.template = f } else { self.templateFailedAt = Date() }
            self.lock.unlock()
            if found != nil { self.pump() }
        }.resume()
    }

    private func download(_ key: Key, template: String) {
        let s = template
            .replacingOccurrences(of: "{z}", with: String(key.z))
            .replacingOccurrences(of: "{x}", with: String(key.x))
            .replacingOccurrences(of: "{y}", with: String(key.y))
        guard let url = URL(string: s) else { finish(key, tile: nil); return }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var decoded: MVTTile?
            if let data = data, status == 200 || status == 0, let t = try? MVT.decode(data) {
                decoded = t
                let file = self.fileURL(key)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            } else if status == 204 || (status == 200 && (data?.isEmpty ?? true)) {
                decoded = MVTTile() // empty tile (e.g. open ocean)
                let file = self.fileURL(key)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? Data().write(to: file, options: .atomic)
            }
            self.finish(key, tile: decoded)
        }.resume()
    }

    private func finish(_ key: Key, tile: MVTTile?) {
        lock.lock()
        active.remove(key)
        if let t = tile { store(t, key); failures.removeValue(forKey: key) } else { failures[key] = Date() }
        let callback = _onTileLoaded
        lock.unlock()
        if tile != nil, let cb = callback { DispatchQueue.main.async { cb() } }
        pump()
    }
}
