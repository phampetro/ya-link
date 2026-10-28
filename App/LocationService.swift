import CoreLocation
import Foundation

/// Vị trí GPS, chạy cả khi khoá máy trong túi (chế độ nền `location`, quyền "Luôn luôn").
/// Cũng là thứ giữ app sống ở chế độ nền để tiếp tục gửi khung hình lên đồng hồ.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var placeName = ""
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    var onUpdate: ((CLLocation) -> Void)?

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

    private func begin() {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()          // để chạy tiếp khi khoá máy
        }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
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
