import DashCore
import Foundation

/// Ô lưu địa điểm.
enum PlaceSlot: Equatable {
    case home, work, fav

    var label: String {
        switch self {
        case .home: return "Nhà"
        case .work: return "Công ty"
        case .fav: return "Yêu thích"
        }
    }
}

/// Cài đặt lưu trong app (UserDefaults). Key Google chỉ được lưu sau khi thử thành công, và không hiện lại.
@MainActor
final class AppSettings: ObservableObject {
    enum RouteSource: String, CaseIterable, Identifiable {
        case auto, valhalla
        var id: String { rawValue }
        var title: String { self == .auto ? "Tự động" : "Chỉ Valhalla" }
    }

    private let defaults = UserDefaults.standard

    /// Gọi khi tên / lời chào / địa điểm đổi (DashLink đẩy vào DashUI).
    var onProfileChange: (() -> Void)?

    @Published private(set) var googleKey: String? {
        didSet { defaults.set(googleKey, forKey: "googleKey") }
    }
    @Published var routeSource: RouteSource {
        didSet { defaults.set(routeSource.rawValue, forKey: "routeSource") }
    }
    @Published var odometer: OdometerBook {
        didSet { if let d = try? JSONEncoder().encode(odometer) { defaults.set(d, forKey: "odometer") } }
    }
    @Published private(set) var googleCalls: Int {
        didSet { defaults.set(googleCalls, forKey: monthKey) }
    }

    @Published var userName: String {
        didSet { defaults.set(userName, forKey: "userName"); onProfileChange?() }
    }
    @Published var greetingEnabled: Bool {
        didSet { defaults.set(greetingEnabled, forKey: "greetingEnabled"); onProfileChange?() }
    }
    @Published var places: SavedPlaces {
        didSet {
            if let d = try? JSONEncoder().encode(places) { defaults.set(d, forKey: "places") }
            onProfileChange?()
        }
    }
    /// Khoảng ngày (7 hoặc 30) của km/L ở tab Đồng hồ và tab Xe.
    @Published var historyRange: Int {
        didSet { defaults.set(historyRange, forKey: "historyRange") }
    }
    @Published var onboarded: Bool {
        didSet { defaults.set(onboarded, forKey: "onboarded") }
    }

    private var monthKey: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return "googleCalls-\(c.year ?? 0)-\(c.month ?? 0)"
    }

    init() {
        let d = UserDefaults.standard
        googleKey = d.string(forKey: "googleKey")
        routeSource = RouteSource(rawValue: d.string(forKey: "routeSource") ?? "") ?? .auto
        if let data = d.data(forKey: "odometer"), let book = try? JSONDecoder().decode(OdometerBook.self, from: data) {
            odometer = book
        } else {
            odometer = OdometerBook()
        }
        googleCalls = 0
        userName = d.string(forKey: "userName") ?? ""
        greetingEnabled = d.object(forKey: "greetingEnabled") as? Bool ?? true
        if let data = d.data(forKey: "places"), let p = try? JSONDecoder().decode(SavedPlaces.self, from: data) {
            places = p
        } else {
            places = SavedPlaces()
        }
        let r = d.integer(forKey: "historyRange")
        historyRange = (r == 7 || r == 30) ? r : 7
        onboarded = d.bool(forKey: "onboarded")
        googleCalls = d.integer(forKey: monthKey)
    }

    /// Key dùng để tính đường lúc này (nil = chỉ Valhalla).
    var activeGoogleKey: String? { routeSource == .auto ? googleKey : nil }

    var maskedKey: String {
        guard let k = googleKey, k.count > 8 else { return "Chưa có" }
        return "\(k.prefix(4))••••\(k.suffix(4))"
    }

    func saveTestedKey(_ key: String) { googleKey = key }
    func removeKey() { googleKey = nil }
    func countGoogleCall() { googleCalls += 1 }

    // MARK: - Địa điểm đã lưu

    func removePlace(_ slot: PlaceSlot) {
        let p = places
        places = SavedPlaces(home: slot == .home ? nil : p.home, work: slot == .work ? nil : p.work, favs: p.favs)
    }

    func removeFavourite(at index: Int) {
        var favs = places.favs
        guard favs.indices.contains(index) else { return }
        favs.remove(at: index)
        places = SavedPlaces(home: places.home, work: places.work, favs: favs)
    }

    /// Đặt Nhà / Công ty, hoặc thêm vào Yêu thích (bỏ qua nếu trùng vị trí).
    func savePlace(_ place: SavedPlace, as slot: PlaceSlot) {
        let p = places
        switch slot {
        case .home: places = SavedPlaces(home: place, work: p.work, favs: p.favs)
        case .work: places = SavedPlaces(home: p.home, work: place, favs: p.favs)
        case .fav:
            let dup = p.favs.contains { abs($0.lat - place.lat) < 1e-5 && abs($0.lon - place.lon) < 1e-5 }
            if !dup { places = SavedPlaces(home: p.home, work: p.work, favs: p.favs + [place]) }
        }
    }

    /// Điền phần mô tả (khu vực) sau khi tra ngược toạ độ.
    func fillSub(_ sub: String, lat: Double, lon: Double) {
        guard !sub.isEmpty else { return }
        var changed = false
        func fixed(_ q: SavedPlace?) -> SavedPlace? {
            guard let q = q else { return nil }
            guard q.sub.isEmpty, abs(q.lat - lat) < 1e-5, abs(q.lon - lon) < 1e-5 else { return q }
            changed = true
            return SavedPlace(name: q.name, sub: sub, lat: q.lat, lon: q.lon)
        }
        let p = places
        let n = SavedPlaces(home: fixed(p.home), work: fixed(p.work), favs: p.favs.compactMap { fixed($0) })
        if changed { places = n }
    }
}
