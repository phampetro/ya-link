import Foundation

/// Sổ ODO của xe: mốc TRIP 1, TRIP 2, lần thay nhớt; chọn mục hiện ở thanh dưới trang chủ.
/// Mốc nil nghĩa là chưa biết ODO lúc đặt: coi như bằng ODO hiện tại (trip = 0) — gọi `sync` để chốt.
public struct OdometerBook: Codable, Equatable {
    public enum BarItem: String, Codable, CaseIterable { case odo, trip1, trip2, oil }

    public static let defaultOilIntervalKm: Double = 1500

    public var trip1StartKm: Double?
    public var trip2StartKm: Double?
    public var oilChangedAtKm: Double?
    public var oilIntervalKm: Double
    public var barItem: BarItem

    public init(trip1StartKm: Double? = nil, trip2StartKm: Double? = nil, oilChangedAtKm: Double? = nil,
                oilIntervalKm: Double = OdometerBook.defaultOilIntervalKm, barItem: BarItem = .odo) {
        self.trip1StartKm = trip1StartKm
        self.trip2StartKm = trip2StartKm
        self.oilChangedAtKm = oilChangedAtKm
        self.oilIntervalKm = oilIntervalKm
        self.barItem = barItem
    }

    private enum CodingKeys: String, CodingKey { case trip1StartKm, trip2StartKm, oilChangedAtKm, oilIntervalKm, barItem }

    /// Đọc bản lưu cũ thiếu khoá vẫn được (dùng giá trị mặc định).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trip1StartKm = try c.decodeIfPresent(Double.self, forKey: .trip1StartKm)
        trip2StartKm = try c.decodeIfPresent(Double.self, forKey: .trip2StartKm)
        oilChangedAtKm = try c.decodeIfPresent(Double.self, forKey: .oilChangedAtKm)
        oilIntervalKm = try c.decodeIfPresent(Double.self, forKey: .oilIntervalKm) ?? Self.defaultOilIntervalKm
        barItem = try c.decodeIfPresent(BarItem.self, forKey: .barItem) ?? .odo
    }

    // MARK: - Thay đổi

    /// ODO vừa biết: mốc nào còn nil thì lấy ODO hiện tại.
    public mutating func sync(odoKm: Double?) {
        guard let o = odoKm else { return }
        if trip1StartKm == nil { trip1StartKm = o }
        if trip2StartKm == nil { trip2StartKm = o }
        if oilChangedAtKm == nil { oilChangedAtKm = o }
    }

    public mutating func resetTrip1(odoKm: Double?) { trip1StartKm = odoKm }
    public mutating func resetTrip2(odoKm: Double?) { trip2StartKm = odoKm }
    public mutating func oilChanged(odoKm: Double?) { oilChangedAtKm = odoKm }

    // MARK: - Đọc

    /// Quãng đường từ mốc (km, không âm); nil nếu chưa biết ODO.
    public func trip1Km(odoKm: Double?) -> Double? { Self.since(trip1StartKm, odoKm) }
    public func trip2Km(odoKm: Double?) -> Double? { Self.since(trip2StartKm, odoKm) }

    /// Km còn lại tới lần thay nhớt (âm = quá hạn); nil nếu chưa biết ODO.
    public func oilRemainingKm(odoKm: Double?) -> Double? {
        guard let o = odoKm else { return nil }
        return (oilChangedAtKm ?? o) + oilIntervalKm - o
    }

    /// Chữ thanh dưới: "ODO 3.214 km", "TRIP 1 · 125,4 km", "OIL · còn 320 km" / "OIL · quá 40 km".
    public func barText(odoKm: Double?) -> String {
        switch barItem {
        case .odo:
            return "ODO \(odoKm.map { Self.thousands(Int($0.rounded(.down))) } ?? "--") km"
        case .trip1:
            return "TRIP 1 · \(trip1Km(odoKm: odoKm).map(Self.oneDecimal) ?? "--") km"
        case .trip2:
            return "TRIP 2 · \(trip2Km(odoKm: odoKm).map(Self.oneDecimal) ?? "--") km"
        case .oil:
            guard let r = oilRemainingKm(odoKm: odoKm) else { return "OIL · -- km" }
            let km = Int(abs(r).rounded())
            return r < 0 && km > 0 ? "OIL · quá \(Self.thousands(km)) km" : "OIL · còn \(Self.thousands(km)) km"
        }
    }

    // MARK: - Định dạng

    private static func since(_ start: Double?, _ odo: Double?) -> Double? {
        guard let o = odo else { return nil }
        return max(0, o - (start ?? o))
    }

    /// 3214 → "3.214" (dấu chấm ngăn hàng nghìn kiểu Việt).
    static func thousands(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// 125.44 → "125,4" (một số lẻ, dấu phẩy thập phân).
    static func oneDecimal(_ v: Double) -> String {
        String(format: "%.1f", (v * 10).rounded() / 10).replacingOccurrences(of: ".", with: ",")
    }
}
