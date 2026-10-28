import CoreLocation
import DashCore
import DashRender
import Foundation
import MapKit

/// Luồng dẫn đường: nhận chữ chia sẻ từ Google Maps → tìm điểm đến → xác nhận → tính đường
/// (Valhalla / Google) → bám tuyến theo GPS (tính lại khi đi lệch) → tới nơi.
@MainActor
final class NavigationController: ObservableObject {
    struct Pending: Equatable {
        var name: String
        var point: GeoPoint
    }

    enum State: Equatable {
        case idle
        case resolving
        case confirm(Pending)
        case routing
        case active
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var routeSource = ""

    let tiles = TileStore()
    var onStarted: ((NavInfo) -> Void)?
    var onChange: (() -> Void)?

    private let ui: DashUI
    private let settings: AppSettings
    private let clock: () -> TimeInterval
    private var navigator: Navigator?
    private var route: Route?
    private var destination: Pending?
    private var lastFix: CLLocation?
    private var lastHeading: Double = 0
    private var replanning = false
    private var lastPassed = 0

    init(ui: DashUI, settings: AppSettings, clock: @escaping () -> TimeInterval) {
        self.ui = ui
        self.settings = settings
        self.clock = clock
        tiles.onTileLoaded = { [weak self] in self?.onChange?() }
    }

    var isActive: Bool { navigator != nil }

    // MARK: - Chia sẻ

    /// Chữ nhận từ tiện ích Chia sẻ (hoặc từ bộ nhớ tạm).
    func handleShared(text: String) {
        state = .resolving
        Task {
            guard let dest = await ShareLink.resolve(text: text) else {
                state = .failed("Không đọc được địa điểm từ nội dung chia sẻ.")
                return
            }
            var point = dest.point
            if point == nil, let q = dest.searchText ?? dest.name {
                point = await search(q)
            }
            guard let p = point else {
                state = .failed("Không tìm thấy toạ độ cho “\(dest.searchText ?? dest.name ?? "địa điểm")”.")
                return
            }
            state = .confirm(Pending(name: dest.name ?? dest.searchText ?? "Điểm đến", point: p))
        }
    }

    /// Tìm tên địa điểm bằng MapKit (chỉ lấy kết quả đầu, người dùng xác nhận lại ở màn xác nhận).
    private func search(_ text: String) async -> GeoPoint? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = text
        if let l = lastFix {
            req.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else { return nil }
        return GeoPoint(lat: item.placemark.coordinate.latitude, lon: item.placemark.coordinate.longitude)
    }

    func cancelPending() {
        if case .active = state { return }
        state = .idle
    }

    // MARK: - Bắt đầu / kết thúc

    func startConfirmed() {
        guard case .confirm(let p) = state else { return }
        guard let loc = lastFix else {
            state = .failed("Chưa có vị trí GPS. Cho phép vị trí “Luôn luôn” rồi thử lại.")
            return
        }
        destination = p
        state = .routing
        Task { await plan(from: loc, to: p, initial: true) }
    }

    func stop() {
        navigator = nil
        route = nil
        destination = nil
        ui.cancelNavigation()
        state = .idle
        onChange?()
    }

    private func plan(from loc: CLLocation, to p: Pending, initial: Bool) async {
        let planner = RoutePlanner(googleKey: settings.activeGoogleKey)
        planner.onGoogleCall = { [weak settings] in Task { @MainActor in settings?.countGoogleCall() } }
        do {
            let r = try await planner.plan(from: GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude),
                                           to: p.point, via: [])
            route = r
            routeSource = r.source == .google ? "Google" : "Valhalla"
            let nav = Navigator(route: r, destinationName: p.name)
            navigator = nav
            tiles.prefetch(route: r.points.map { MapPoint(lat: $0.lat, lon: $0.lon) }, zooms: [13, 14])
            if let info = nav.update(GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude), at: Date(),
                                     speedMps: max(0, loc.speed)).info {
                if initial {
                    ui.startNavigation(info, now: clock())
                    state = .active
                    onStarted?(info)
                } else {
                    ui.nav = info
                }
            }
        } catch {
            if initial { state = .failed("Không tính được đường: \(error.localizedDescription)") }
        }
        replanning = false
        onChange?()
    }

    // MARK: - GPS

    func locationUpdated(_ loc: CLLocation) {
        lastFix = loc
        if loc.course >= 0 && loc.speed > 1.5 { lastHeading = loc.course }
        guard let nav = navigator, let dest = destination else { return }
        let here = GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let u = nav.update(here, at: loc.timestamp, speedMps: max(0, loc.speed))
        lastPassed = u.passedIndex
        if u.arrived {
            navigator = nil
            route = nil
            ui.arrive(now: clock())
            state = .idle
            onChange?()
            return
        }
        if var info = u.info {
            if info.speedLimit == nil { info.speedLimit = ui.nav?.speedLimit }
            ui.nav = info
        }
        if u.needsReroute && !replanning {
            replanning = true
            Task { await plan(from: loc, to: dest, initial: false) }
        }
        onChange?()
    }

    // MARK: - Bản đồ

    /// Cảnh bản đồ cho bộ vẽ (nil khi chưa có vị trí); khi chưa chỉ đường vẫn vẽ bản đồ quanh xe.
    func mapScene() -> MapScene? {
        guard let loc = lastFix else { return nil }
        let center = MapPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let pts = route?.points.map { MapPoint(lat: $0.lat, lon: $0.lon) } ?? []
        tiles.prefetch(around: center, z: 14, radius: 1)
        return MapScene(center: center, headingDeg: lastHeading, route: pts, passedIndex: lastPassed,
                        destination: destination.map { MapPoint(lat: $0.point.lat, lon: $0.point.lon) }, store: tiles)
    }
}
