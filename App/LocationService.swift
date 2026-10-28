import CoreLocation
import Foundation

/// Vị trí GPS, chỉ chạy liên tục khi cần: chỉ đường (kể cả khi khoá máy, cần quyền "Khi dùng app" là đủ),
/// hoặc đang mở bản đồ trên đồng hồ (chỉ khi app ở trước). Còn lại tắt hẳn, không hiện viên thuốc xanh.
/// Việc giữ app sống để gửi khung hình lên đồng hồ do chế độ nền `external-accessory` đảm nhiệm.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var placeName = ""
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    enum Tracking { case off, foreground, background }

    var onUpdate: ((CLLocation) -> Void)?
    private(set) var tracking: Tracking = .off

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocoded: CLLocation?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .otherNavigation
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            begin()
        }
    }

    private var authorized: Bool {
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse
    }

    private func begin() {
        guard authorized else { return }
        apply()
        if tracking == .off { manager.requestLocation() }     // một lần: cho thời tiết và tên khu vực
    }

    /// Một lần lấy vị trí (không bật viên thuốc xanh), dùng để làm mới thời tiết khi không chỉ đường.
    func requestOnce() {
        guard authorized, tracking == .off else { return }
        manager.requestLocation()
    }

    func setTracking(_ t: Tracking) {
        guard t != tracking else { return }
        tracking = t
        apply()
    }

    private func apply() {
        guard authorized else { return }
        switch tracking {
        case .off:
            manager.stopUpdatingLocation()
            manager.showsBackgroundLocationIndicator = false
            manager.allowsBackgroundLocationUpdates = false
        case .foreground:
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
            manager.startUpdatingLocation()
        case .background:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.begin()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.location = loc
            self.onUpdate?(loc)
            self.reverseGeocodeIfNeeded(loc)
        }
    }

    /// Tên khu vực (phường/quận) cho ô thời tiết, hỏi lại khi đi xa hơn 1 km.
    private func reverseGeocodeIfNeeded(_ loc: CLLocation) {
        if let last = lastGeocoded, loc.distance(from: last) < 1000 { return }
        lastGeocoded = loc
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "vi_VN")) { [weak self] marks, _ in
            let mark = marks?.first
            let sub = mark?.subLocality ?? mark?.subAdministrativeArea
            let city = mark?.locality ?? mark?.administrativeArea
            Task { @MainActor in self?.placeName = PlaceNames.short(sub: sub, city: city) }
        }
    }
}

/// Rút gọn tên địa danh (dùng tạm đến khi gắn bộ rút gọn của DashCore).
enum PlaceNames {
    static func short(sub: String?, city: String?) -> String {
        let raw = (sub?.isEmpty == false ? sub : city) ?? ""
        let pairs = [("Quận ", "Q."), ("Phường ", "P. "), ("Thành phố ", "TP. "), ("Huyện ", "H. "), ("Thị xã ", "TX. ")]
        for (long, short) in pairs where raw.hasPrefix(long) {
            return short + raw.dropFirst(long.count)
        }
        return raw
    }
}
