import CoreLocation
import DashCore
import DashRender
import Foundation
import MapKit

/// Luồng dẫn đường: nhận chữ chia sẻ từ Google Maps → tìm điểm đến → xác nhận → tính đường
/// (Valhalla / Google) → bám tuyến theo GPS (tính lại khi đi lệch) → tới nơi.
/// Cũng dùng cho luồng "lưu địa điểm" (cùng bước đọc link và xác nhận, nhưng chỉ lưu, không dẫn đường)
/// và `navigate(to:)` đi thẳng tới địa điểm đã lưu (từ menu giữ Enter trên đồng hồ).
@MainActor
final class NavigationController: ObservableObject {
    /// Một kết quả tìm kiếm MapKit cho link chỉ có địa chỉ.
    struct Candidate: Equatable {
        var name: String
        var address: String
        var point: GeoPoint
        /// Khoảng cách từ vị trí GPS gần nhất (m), nil khi chưa có vị trí.
        var distanceM: Double?
    }

    struct Pending: Equatable {
        /// Toạ độ đến từ đâu: ghim trong link, khung nhìn bản đồ, hoặc tìm theo tên.
        enum Source: Equatable { case pin, viewport, search }

        var name: String
        var point: GeoPoint
        var source: Source = .pin
        var alternatives: [Candidate] = []
        var selected: Int = 0
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
    /// Thông tin chặng tiếp theo (bản sao của `ui.nav` để màn hình quan sát được).
    @Published private(set) var info: NavInfo?
    /// Đang ở luồng "Đặt Nhà / Công ty / Yêu thích từ link": màn xác nhận ở chế độ lưu.
    @Published private(set) var pendingSlot: PlaceSlot?

    let tiles = TileStore()
    var onStarted: ((NavInfo) -> Void)?
    var onChange: (() -> Void)?
    var onToast: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private let ui: DashUI
    private let settings: AppSettings
    private let clock: () -> TimeInterval
    private var navigator: Navigator?
    private var route: Route?
    private var destination: Pending?
    private var lastPending: Pending?
    private var awaitingFix: Pending?
    private var lastText: String?
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

    /// Hiện màn xác nhận với địa điểm mẫu (chỉ để chụp ảnh giao diện trên trình giả lập).
    func debugShowConfirm() {
        state = .confirm(Pending(name: "Chợ Bến Thành", point: GeoPoint(lat: 10.7725, lon: 106.6980)))
    }

    private func restState() {
        state = navigator != nil ? .active : .idle
    }

    private func publishInfo() {
        if info != ui.nav { info = ui.nav }
    }

    // MARK: - Chia sẻ

    /// Chữ nhận từ tiện ích Chia sẻ (hoặc từ bộ nhớ tạm).
    func handleShared(text: String) {
        lastText = text
        state = .resolving
        Task {
            guard let dest = await ShareLink.resolve(text: text) else {
                state = .failed("Không đọc được địa điểm từ nội dung chia sẻ.")
                return
            }
            if let p = dest.point {
                state = .confirm(Pending(name: dest.name ?? dest.searchText ?? "Điểm đến", point: p,
                                         source: dest.coordinateSource == .viewport ? .viewport : .pin))
                return
            }
            let query = dest.searchText ?? dest.name ?? ""
            let found = await searchCandidates(ShareLink.searchQueries(for: query))
            guard let first = found.first else {
                onLog?("link chỉ có địa chỉ: MapKit không có kết quả")
                state = .failed("Không tìm thấy địa điểm từ địa chỉ trong link.")
                return
            }
            onLog?("link chỉ có địa chỉ: \(found.count) kết quả MapKit, chọn: \(first.name)")
            state = .confirm(Pending(name: first.name, point: first.point, source: .search,
                                     alternatives: found, selected: 0))
        }
    }

    /// Chọn một kết quả trong danh sách ở màn xác nhận (đổi tên và toạ độ đang chờ).
    func selectAlternative(_ index: Int) {
        guard case .confirm(var p) = state, p.alternatives.indices.contains(index) else { return }
        let c = p.alternatives[index]
        p.selected = index
        p.name = c.name
        p.point = c.point
        state = .confirm(p)
        onLog?("đổi lựa chọn: \(c.name) (#\(index + 1))")
    }

    /// Luồng thêm địa điểm: dán link → đọc → màn xác nhận ở chế độ "Lưu địa điểm này?".
    func beginAdd(slot: PlaceSlot, text: String) {
        pendingSlot = slot
        handleShared(text: text)
    }

    /// Tìm bằng MapKit lần lượt từng truy vấn (cụ thể trước). Dừng khi đã có kết quả (nếu mới có 1 thì thử thêm
    /// truy vấn đơn giản hơn để có phương án thay thế). Gộp, bỏ trùng toạ độ trong 30 m, tối đa 5, giữ thứ tự MapKit.
    private func searchCandidates(_ queries: [String]) async -> [Candidate] {
        var out: [Candidate] = []
        for q in queries {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            if let l = lastFix {
                req.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
            }
            guard let items = try? await MKLocalSearch(request: req).start().mapItems else { continue }
            for item in items {
                let c = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(c) else { continue }
                let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                if out.contains(where: { CLLocation(latitude: $0.point.lat, longitude: $0.point.lon).distance(from: loc) < 30 }) { continue }
                let pm = item.placemark
                let street = [pm.subThoroughfare, pm.thoroughfare].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                let joined = [street, pm.subLocality ?? "", pm.locality ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                let address = joined.isEmpty ? (pm.title ?? "") : joined
                let itemName = item.name ?? ""
                let name = itemName.isEmpty ? (address.isEmpty ? q : address) : itemName
                out.append(Candidate(name: name, address: address, point: GeoPoint(lat: c.latitude, lon: c.longitude),
                                     distanceM: lastFix.map { $0.distance(from: loc) }))
                if out.count >= 5 { return out }
            }
            if out.count >= 2 { break }
        }
        return out
    }

    func cancelPending() {
        pendingSlot = nil
        restState()
    }

    /// Lỗi: bỏ thông báo, về trạng thái trước đó.
    func dismissFailure() {
        pendingSlot = nil
        restState()
    }

    /// Lưu địa điểm đang chờ xác nhận (không bắt đầu dẫn đường).
    func savePending(as slot: PlaceSlot, name: String? = nil) {
        guard case .confirm(let p) = state else { return }
        let custom = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(name: custom.isEmpty ? p.name : custom, sub: "", lat: p.point.lat, lon: p.point.lon)
        settings.savePlace(place, as: slot)
        pendingSlot = nil
        restState()
        onToast?(slot == .home ? "Đã lưu làm Nhà" : slot == .work ? "Đã lưu làm Công ty" : "Đã thêm vào Yêu thích")
        fillSub(lat: p.point.lat, lon: p.point.lon)
    }

    /// Tra ngược toạ độ ra tên khu vực (vd. "Q.7") để hiện dưới tên địa điểm.
    private func fillSub(lat: Double, lon: Double) {
        let loc = CLLocation(latitude: lat, longitude: lon)
        CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "vi_VN")) { [weak self] marks, _ in
            let m = marks?.first
            let sub = PlaceNames.short(sub: m?.subLocality ?? m?.subAdministrativeArea,
                                       city: m?.locality ?? m?.administrativeArea)
            Task { @MainActor in self?.settings.fillSub(sub, lat: lat, lon: lon) }
        }
    }

    // MARK: - Bắt đầu / kết thúc

    func startConfirmed() {
        guard case .confirm(let p) = state else { return }
        pendingSlot = nil
        begin(p)
    }

    /// Đi thẳng tới địa điểm đã lưu, bỏ qua bước xác nhận (từ menu trên đồng hồ).
    func navigate(to place: SavedPlace) {
        pendingSlot = nil
        begin(Pending(name: place.name, point: GeoPoint(lat: place.lat, lon: place.lon)))
    }

    /// Bắt đầu đi. Định vị chỉ chạy khi cần nên vị trí có thể cũ: nếu quá 30 s thì chờ một lần cập nhật mới (tối đa 20 s).
    private func begin(_ p: Pending) {
        lastPending = p
        destination = p
        state = .routing
        if let loc = lastFix, Date().timeIntervalSince(loc.timestamp) < 30 {
            Task { await plan(from: loc, to: p, initial: true) }
            return
        }
        awaitingFix = p
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard awaitingFix == p else { return }
            awaitingFix = nil
            if navigator == nil { destination = nil }
            state = .failed("Chưa có vị trí GPS. Cho phép vị trí “Khi dùng app” rồi thử lại.")
        }
    }

    /// Thử lại sau lỗi: tính đường lại tới điểm cuối, hoặc đọc lại link vừa dán.
    func retry() {
        if let p = lastPending {
            begin(p)
        } else if let t = lastText {
            handleShared(text: t)
        } else {
            state = .idle
        }
    }

    func stop() {
        awaitingFix = nil
        navigator = nil
        route = nil
        destination = nil
        ui.cancelNavigation()
        state = .idle
        publishInfo()
        onChange?()
    }

    private func plan(from loc: CLLocation, to p: Pending, initial: Bool) async {
        let planner = RoutePlanner(googleKey: settings.activeGoogleKey)
        planner.onGoogleCall = { [weak settings] in Task { @MainActor in settings?.countGoogleCall() } }
        planner.onDiag = { [weak self] text in Task { @MainActor in self?.onLog?(text) } }
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
            } else if initial {
                navigator = nil
                state = .failed("Không tính được đường: tuyến rỗng.")
            }
        } catch {
            if initial { state = .failed("Không tính được đường: \(error.localizedDescription)") }
        }
        replanning = false
        publishInfo()
        onChange?()
    }

    // MARK: - GPS

    func locationUpdated(_ loc: CLLocation) {
        lastFix = loc
        if loc.course >= 0 && loc.speed > 1.5 { lastHeading = loc.course }
        if let p = awaitingFix {
            awaitingFix = nil
            Task { await plan(from: loc, to: p, initial: true) }
        }
        guard let nav = navigator, let dest = destination else { return }
        let here = GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let u = nav.update(here, at: loc.timestamp, speedMps: max(0, loc.speed))
        lastPassed = u.passedIndex
        if u.arrived {
            navigator = nil
            route = nil
            destination = nil
            ui.arrive(now: clock())
            state = .idle
            publishInfo()
            onToast?("Đã tới nơi")
            onChange?()
            return
        }
        if var info = u.info {
            if info.speedLimit == nil { info.speedLimit = ui.nav?.speedLimit }
            ui.nav = info
        }
        publishInfo()
        if u.needsReroute && !replanning {
            replanning = true
            Task { await plan(from: loc, to: dest, initial: false) }
        }
        onChange?()
    }

    // MARK: - Bản đồ

    /// Cảnh bản đồ cho bộ vẽ (nil khi chưa có vị trí); khi chưa chỉ đường vẫn vẽ bản đồ quanh xe.
    func mapScene() -> MapScene? {
        guard let loc = lastFix, Date().timeIntervalSince(loc.timestamp) < 120 else { return nil }   // vị trí cũ thì không vẽ sai chỗ
        let center = MapPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let pts = route?.points.map { MapPoint(lat: $0.lat, lon: $0.lon) } ?? []
        tiles.prefetch(around: center, z: 14, radius: 1)
        return MapScene(center: center, headingDeg: lastHeading, route: pts, passedIndex: lastPassed,
                        destination: destination.map { MapPoint(lat: $0.point.lat, lon: $0.point.lon) }, store: tiles)
    }
}
