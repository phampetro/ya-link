import DashCore
import Foundation

/// Lịch sử theo ngày lưu trong Documents/history.json (Documents được iCloud sao lưu).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var history = DailyHistory()

    private let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("history.json")

    init() {
        if let d = try? Data(contentsOf: url), let h = DailyHistory.decode(d) { history = h }
    }

    /// Ghi một lần đọc từ xe (gọi khi ODO hoặc bộ đếm xăng đổi).
    func record(odoKm: Double?, fuelUsedL: Double?) {
        var h = history
        if h.record(odoKm: odoKm, fuelUsedL: fuelUsedL, date: Date()) {
            history = h
            save()
        }
    }

    func clear() {
        history = DailyHistory()
        save()
    }

    private func save() {
        if let d = history.encoded() { try? d.write(to: url, options: .atomic) }
    }

    /// Ghi CSV ra thư mục tạm để chia sẻ; trả đường dẫn file.
    func exportURL() -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ya-link-lichsu.csv")
        try? history.csv().write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Dữ liệu mẫu 14 ngày (chỉ để chụp ảnh giao diện trên CI: YALINK_SEED=1).
    func seedDemo() {
        var h = DailyHistory()
        let cal = Calendar.current
        let km: [Double] = [24.6, 41.2, 0, 68.5, 12.3, 33.8, 18.9, 22.0, 0, 51.4, 30.2, 9.8, 45.5, 27.1]
        var odo = 3000.0
        for (i, k) in km.enumerated().reversed() {
            guard k > 0, let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let missing = i == 4
            let fuel0 = 10.0 + Double(i)
            _ = h.record(odoKm: odo, fuelUsedL: missing ? nil : fuel0, date: d)
            odo += k
            _ = h.record(odoKm: odo, fuelUsedL: missing ? nil : fuel0 + k / 38, date: d)
        }
        history = h
        save()
    }
}
