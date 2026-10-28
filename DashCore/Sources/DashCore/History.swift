import Foundation

/// Một ngày chạy xe: ODO đầu/cuối ngày và bộ đếm xăng (lít, cộng dồn) đầu/cuối ngày.
/// km = ODO cuối − ODO đầu; lít = xăng cuối − xăng đầu (cộng phần đã chốt trước lần bộ đếm bị reset).
/// Không có số xăng cả ngày (app không đọc được) thì `fuelStart` = nil: ngày đó "thiếu xăng".
public struct DayRecord: Codable, Equatable {
    /// Khoá ngày "yyyy-MM-dd" theo lịch của máy.
    public var date: String
    public var odoStart: Double
    public var odoEnd: Double
    public var fuelStart: Double?
    public var fuelEnd: Double?
    /// Lít đã chốt trước khi bộ đếm xăng bị đặt lại (app khởi động lại thì bộ đếm về 0).
    public var fuelCarry: Double

    public init(date: String, odoStart: Double, odoEnd: Double, fuelStart: Double? = nil, fuelEnd: Double? = nil,
                fuelCarry: Double = 0) {
        self.date = date
        self.odoStart = odoStart
        self.odoEnd = odoEnd
        self.fuelStart = fuelStart
        self.fuelEnd = fuelEnd
        self.fuelCarry = fuelCarry
    }

    private enum CodingKeys: String, CodingKey { case date, odoStart, odoEnd, fuelStart, fuelEnd, fuelCarry }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        odoStart = try c.decode(Double.self, forKey: .odoStart)
        odoEnd = try c.decode(Double.self, forKey: .odoEnd)
        fuelStart = try c.decodeIfPresent(Double.self, forKey: .fuelStart)
        fuelEnd = try c.decodeIfPresent(Double.self, forKey: .fuelEnd)
        fuelCarry = try c.decodeIfPresent(Double.self, forKey: .fuelCarry) ?? 0
    }

    /// Quãng đường trong ngày (km, không âm).
    public var km: Double { max(0, odoEnd - odoStart) }

    /// Xăng dùng trong ngày (lít); nil nếu không có số xăng.
    public var litres: Double? {
        guard let s = fuelStart, let e = fuelEnd else { return nil }
        return max(0, e - s) + fuelCarry
    }

    /// Ngày có chạy xe.
    public var ran: Bool { km > 0 }
}

/// Một dòng trong danh sách "Theo ngày" (đủ mọi ngày của khoảng, kể cả ngày không chạy).
public struct DayRow: Equatable {
    public enum Kind: Equatable {
        case none        // không đi
        case missingFuel // có km nhưng thiếu số lít
        case valid       // có km và lít
    }
    public var date: String
    public var daysAgo: Int
    public var km: Double
    public var litres: Double?
    public var kind: Kind
    /// km/L của riêng ngày đó (chỉ khi `valid` và lít > 0).
    public var kmPerLitre: Double? {
        guard kind == .valid, let l = litres, l > 0 else { return nil }
        return km / l
    }
}

public struct HistorySummary: Equatable {
    /// Tổng km của mọi ngày chạy (kể cả ngày thiếu xăng).
    public var totalKm: Double
    /// Tổng km của các ngày hợp lệ (có lít) — mẫu số của km/L.
    public var validKm: Double
    public var litres: Double
    /// km/L = tổng km hợp lệ ÷ tổng lít hợp lệ; nil nếu chưa có.
    public var kmPerLitre: Double?
    public var ranDays: Int
    public var missingDays: Int
}

/// Lịch sử theo ngày (tối đa 30 ngày). Logic thuần, app lưu/đọc JSON.
public struct DailyHistory: Codable, Equatable {
    public static let maxDays = 30

    public private(set) var days: [DayRecord]

    public init(days: [DayRecord] = []) { self.days = days }

    public var isEmpty: Bool { days.isEmpty }

    // MARK: - Ghi

    /// Khoá ngày "yyyy-MM-dd".
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ n: Int, _ w: Int) -> String {
            let s = String(n)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        return "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0, 2))-\(pad(c.day ?? 0, 2))"
    }

    /// Ngày trước `date` n ngày (khoá).
    public static func key(daysAgo n: Int, from date: Date, calendar: Calendar = .current) -> String {
        key(for: calendar.date(byAdding: .day, value: -n, to: date) ?? date, calendar: calendar)
    }

    /// Ghi một lần đọc (ODO, xăng cộng dồn) vào ngày của `date`. Trả true nếu có gì thay đổi.
    @discardableResult
    public mutating func record(odoKm: Double?, fuelUsedL: Double?, date: Date = Date(),
                                calendar: Calendar = .current) -> Bool {
        guard let odo = odoKm, odo.isFinite else { return false }
        let k = Self.key(for: date, calendar: calendar)
        let before = days
        if let i = days.firstIndex(where: { $0.date == k }) {
            var d = days[i]
            if odo > d.odoEnd { d.odoEnd = odo }
            if odo < d.odoStart { d.odoStart = odo }     // sổ ODO bị sửa lùi: giữ mốc nhỏ nhất
            if let f = fuelUsedL, f.isFinite {
                if d.fuelStart == nil || d.fuelEnd == nil {
                    d.fuelStart = f
                    d.fuelEnd = f
                } else if let s = d.fuelStart, let e = d.fuelEnd, f < e - 0.000_001 {
                    d.fuelCarry += max(0, e - s)         // bộ đếm về 0 (app chạy lại): chốt phần cũ
                    d.fuelStart = f
                    d.fuelEnd = f
                } else {
                    d.fuelEnd = f
                }
            }
            days[i] = d
        } else {
            let f = (fuelUsedL?.isFinite == true) ? fuelUsedL : nil
            days.append(DayRecord(date: k, odoStart: odo, odoEnd: odo, fuelStart: f, fuelEnd: f))
        }
        days.sort { $0.date < $1.date }
        if days.count > Self.maxDays { days.removeFirst(days.count - Self.maxDays) }
        return days != before
    }

    public mutating func clear() { days = [] }

    // MARK: - Đọc

    public func record(forKey key: String) -> DayRecord? { days.first { $0.date == key } }

    /// Các dòng của `range` ngày gần nhất, mới nhất trước (index 0 = hôm nay).
    public func rows(range: Int, today: Date = Date(), calendar: Calendar = .current) -> [DayRow] {
        (0..<max(0, range)).map { n in
            let k = Self.key(daysAgo: n, from: today, calendar: calendar)
            guard let r = record(forKey: k), r.ran else {
                return DayRow(date: k, daysAgo: n, km: 0, litres: nil, kind: .none)
            }
            if let l = r.litres { return DayRow(date: k, daysAgo: n, km: r.km, litres: l, kind: .valid) }
            return DayRow(date: k, daysAgo: n, km: r.km, litres: nil, kind: .missingFuel)
        }
    }

    /// Tổng hợp `range` ngày. km/L = tổng km ÷ tổng lít của các ngày hợp lệ (không phải trung bình cộng),
    /// ngày thiếu xăng và ngày không chạy không tính vào km/L.
    public func summary(range: Int, today: Date = Date(), calendar: Calendar = .current) -> HistorySummary {
        let rs = rows(range: range, today: today, calendar: calendar)
        let valid = rs.filter { $0.kind == .valid }
        let validKm = valid.reduce(0) { $0 + $1.km }
        let litres = valid.reduce(0) { $0 + ($1.litres ?? 0) }
        return HistorySummary(
            totalKm: rs.reduce(0) { $0 + $1.km },
            validKm: validKm,
            litres: litres,
            kmPerLitre: litres > 0 ? validKm / litres : nil,
            ranDays: rs.filter { $0.kind != .none }.count,
            missingDays: rs.filter { $0.kind == .missingFuel }.count)
    }

    // MARK: - Xuất

    /// CSV mỗi ngày một dòng: ngày, odo đầu, odo cuối, km, lít (trống nếu thiếu), km/L.
    public func csv() -> String {
        var out = "date,odo_start,odo_end,km,litres,km_per_litre\n"
        for d in days {
            let l = d.litres
            let kmpl = (l ?? 0) > 0 && d.ran ? String(format: "%.2f", d.km / (l ?? 1)) : ""
            out += "\(d.date),\(String(format: "%.1f", d.odoStart)),\(String(format: "%.1f", d.odoEnd)),"
                + "\(String(format: "%.1f", d.km)),\(l.map { String(format: "%.3f", $0) } ?? ""),\(kmpl)\n"
        }
        return out
    }

    // MARK: - Lưu

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> DailyHistory? { try? JSONDecoder().decode(DailyHistory.self, from: data) }
}
