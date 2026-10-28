import DashCore
import Foundation

/// Cài đặt lưu trong app (UserDefaults). Key Google chỉ được lưu sau khi thử thành công, và không hiện lại.
@MainActor
final class AppSettings: ObservableObject {
    enum RouteSource: String, CaseIterable, Identifiable {
        case auto, valhalla
        var id: String { rawValue }
        var title: String { self == .auto ? "Tự động (Google nếu có key, Valhalla kiểm tra)" : "Chỉ Valhalla (miễn phí)" }
    }

    private let defaults = UserDefaults.standard

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

    private var monthKey: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return "googleCalls-\(c.year ?? 0)-\(c.month ?? 0)"
    }

    init() {
        googleKey = UserDefaults.standard.string(forKey: "googleKey")
        routeSource = RouteSource(rawValue: UserDefaults.standard.string(forKey: "routeSource") ?? "") ?? .auto
        if let d = UserDefaults.standard.data(forKey: "odometer"), let book = try? JSONDecoder().decode(OdometerBook.self, from: d) {
            odometer = book
        } else {
            odometer = OdometerBook()
        }
        googleCalls = 0
        googleCalls = defaults.integer(forKey: monthKey)
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
}
