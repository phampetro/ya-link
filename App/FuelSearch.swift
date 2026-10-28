import CoreLocation
import DashCore
import Foundation
import MapKit

/// Một trạm xăng tìm được quanh xe.
struct FuelStation: Equatable {
    var name: String
    var lat: Double
    var lon: Double
    var distanceM: Double
}

/// Tìm trạm xăng gần nhất bằng MapKit (MKLocalSearch "trạm xăng", bán kính 5 km), giữ kết quả ~60 s.
@MainActor
final class FuelSearch {
    private var cache: (at: Date, center: CLLocation, stations: [FuelStation])?
    private var inFlight: Task<[FuelStation], Never>?
    let cacheSeconds: TimeInterval = 60
    let maxResults = 8

    /// Kết quả đã có và còn mới (cùng khu vực, dưới 60 s) hoặc nil.
    func cached(near loc: CLLocation) -> [FuelStation]? {
        guard let c = cache, Date().timeIntervalSince(c.at) < cacheSeconds,
              c.center.distance(from: loc) < 500 else { return nil }
        return c.stations
    }

    func search(near loc: CLLocation) async -> [FuelStation] {
        if let hit = cached(near: loc) { return hit }
        if let t = inFlight { return await t.value }
        let task = Task { () -> [FuelStation] in
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = "trạm xăng"
            req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 5_000, longitudinalMeters: 5_000)
            guard let items = try? await MKLocalSearch(request: req).start().mapItems else { return [] }
            let stations = items.map { item -> FuelStation in
                let c = item.placemark.coordinate
                let d = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: loc)
                return FuelStation(name: item.name ?? "Trạm xăng", lat: c.latitude, lon: c.longitude, distanceM: d)
            }
            return Array(stations.sorted { $0.distanceM < $1.distanceM }.prefix(8))
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if !result.isEmpty { cache = (Date(), loc, result) }
        return result
    }
}
