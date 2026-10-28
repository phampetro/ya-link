import DashCore
import SwiftUI

/// Tab Xe: lịch sử theo ngày — km/L trung bình, biểu đồ cột 7/30 ngày (vẽ tay, không dùng Charts) và danh sách theo ngày.
struct CarTab: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: AppSettings
    @State private var selected = 0   // 0 = hôm nay

    private static let dayNames = ["Chủ nhật", "Thứ hai", "Thứ ba", "Thứ tư", "Thứ năm", "Thứ sáu", "Thứ bảy"]
    private static let dayShort = ["CN", "T2", "T3", "T4", "T5", "T6", "T7"]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PageTitle("Xe")
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var emptyState: some View {
        GroupCard {
            VStack(spacing: 6) {
                Text("Chưa có lịch sử").font(.system(size: 17, weight: .bold)).foregroundColor(Theme.text)
                Text("Đi xe và kết nối app, từng ngày sẽ hiện ở đây.")
                    .font(.system(size: 15)).foregroundColor(Theme.sec).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Có dữ liệu

    private var content: some View {
        let range = settings.historyRange
        let rows = history.history.rows(range: range)
        let sm = history.history.summary(range: range)
        let sel = rows.indices.contains(selected) ? selected : 0
        let empty = history.history.isEmpty
        return VStack(spacing: 0) {
            summaryCard(rows: rows, sm: sm, sel: sel, range: range, empty: empty)
            GroupFoot("Km/L = tổng km ÷ tổng lít. Ngày không chạy hoặc thiếu xăng không tính.")
            GroupTitle("Theo ngày")
            if empty {
                emptyState
            } else {
                GroupCard {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        if i > 0 { RowSeparator() }
                        dayRow(r)
                    }
                }
            }
        }
    }

    private func summaryCard(rows: [DayRow], sm: HistorySummary, sel: Int, range: Int, empty: Bool) -> some View {
        let rangeBinding = Binding<Int>(get: { settings.historyRange }, set: { settings.historyRange = $0 })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tiêu hao trung bình").font(.system(size: 12.5)).foregroundColor(Theme.sec)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(sm.kmPerLitre.map { Fmt.dec($0) } ?? "--")
                            .font(.system(size: 40, weight: .heavy)).foregroundColor(Theme.text)
                        Text("km/L").font(.system(size: 17, weight: .bold)).foregroundColor(Theme.sec)
                    }
                }
                Spacer(minLength: 0)
                PillSegmented(selection: rangeBinding, options: [(7, "7 ngày"), (30, "30 ngày")])
                    .frame(width: 140)
            }
            Text(empty ? "Chưa có dữ liệu"
                 : "\(Fmt.dec(sm.validKm, 0)) km · \(Fmt.dec(sm.litres)) L · chạy \(sm.ranDays)/\(range) ngày"
                 + (sm.missingDays > 0 ? " · \(sm.missingDays) ngày thiếu xăng" : ""))
                .font(.system(size: 12.5)).foregroundColor(Theme.sec)
                .padding(.top, 2)
            chart(rows: rows, sel: sel, range: range)
                .padding(.top, 14)
            if !empty {
                selectedBox(rows[sel])
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Biểu đồ cột

    private func chart(rows: [DayRow], sel: Int, range: Int) -> some View {
        let shown = Array(rows.enumerated()).reversed()    // cũ → mới, trái → phải
        let maxKm = max(rows.map { $0.km }.max() ?? 0, 1)
        let plot: CGFloat = 93
        return HStack(alignment: .bottom, spacing: range > 7 ? 2 : 6) {
            ForEach(Array(shown), id: \.offset) { pair in
                let i = pair.offset, r = pair.element
                let on = i == sel
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: range > 7 ? 3 : 7, style: .continuous)
                        .fill(r.km > 0
                              ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x62c4ff), Color(hex: 0x0a7aff)], startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Theme.fill))
                        .opacity(r.km > 0 && !on ? 0.38 : 1)
                        .frame(height: r.km > 0 ? max(6, CGFloat(r.km / maxKm) * plot) : 4)
                        .shadow(color: on && r.km > 0 ? Color(hex: 0x0a7aff, opacity: 0.45) : .clear, radius: 5, x: 0, y: 4)
                    Color.clear.frame(height: 13)
                        .overlay(
                            Text(barLabel(r, index: i, range: range))
                                .font(.system(size: 10.5, weight: on ? .bold : .regular))
                                .foregroundColor(on ? Theme.text : Theme.sec)
                                .lineLimit(1)
                                .fixedSize())
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { selected = i }
            }
        }
        .frame(height: 112)
    }

    private func barLabel(_ r: DayRow, index: Int, range: Int) -> String {
        if range == 7 { return Self.dayShort[Self.weekday(r.date) - 1] }
        return index % 7 == 0 ? Self.ddMM(r.date) : ""
    }

    private func selectedBox(_ r: DayRow) -> some View {
        HStack(spacing: 8) {
            Text("\(Self.dayName(r)) · \(Self.ddMM(r.date))").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.text)
            Spacer(minLength: 0)
            switch r.kind {
            case .none:
                Text("Không đi").font(.system(size: 13)).foregroundColor(Theme.sec)
            case .missingFuel:
                (Text("\(Fmt.dec(r.km)) km").bold().foregroundColor(Theme.text)
                    + Text(" · ").foregroundColor(Theme.sec)
                    + Text("thiếu xăng").bold().foregroundColor(Theme.orange))
                    .font(.system(size: 13))
            case .valid:
                (Text("\(Fmt.dec(r.km)) km").bold().foregroundColor(Theme.text)
                    + Text(" · \(Fmt.dec(r.litres ?? 0, 2)) L · ").foregroundColor(Theme.sec)
                    + Text(r.kmPerLitre.map { "\(Fmt.dec($0)) km/L" } ?? "").bold().foregroundColor(Theme.green))
                    .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.fill))
    }

    // MARK: - Danh sách theo ngày

    private func dayRow(_ r: DayRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dayName(r)).font(.system(size: 15, weight: r.kind == .none ? .regular : .bold))
                    .foregroundColor(r.kind == .none ? Theme.sec : Theme.text)
                switch r.kind {
                case .none: Text(Self.ddMM(r.date)).font(.system(size: 12.5)).foregroundColor(Theme.sec)
                case .missingFuel: Text("\(Self.ddMM(r.date)) · chưa có số lít").font(.system(size: 12.5)).foregroundColor(Theme.sec)
                case .valid: Text("\(Self.ddMM(r.date)) · \(Fmt.dec(r.litres ?? 0, 2)) L").font(.system(size: 12.5)).foregroundColor(Theme.sec)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                switch r.kind {
                case .none:
                    Text("Không đi").font(.system(size: 15)).foregroundColor(Theme.sec)
                case .missingFuel:
                    Text("\(Fmt.dec(r.km)) km").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                    Text("Thiếu xăng").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.orange)
                case .valid:
                    Text("\(Fmt.dec(r.km)) km").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                    Text(r.kmPerLitre.map { "\(Fmt.dec($0)) km/L" } ?? "").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.green)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Ngày tháng từ khoá "yyyy-MM-dd"

    private static func components(_ key: String) -> (y: Int, m: Int, d: Int) {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? (p[0], p[1], p[2]) : (2000, 1, 1)
    }

    /// 1 = Chủ nhật … 7 = Thứ bảy.
    private static func weekday(_ key: String) -> Int {
        let c = components(key)
        let cal = Calendar.current
        guard let d = cal.date(from: DateComponents(year: c.y, month: c.m, day: c.d, hour: 12)) else { return 1 }
        return cal.component(.weekday, from: d)
    }

    private static func ddMM(_ key: String) -> String {
        let c = components(key)
        return String(format: "%02ld/%02ld", c.d, c.m)
    }

    private static func dayName(_ r: DayRow) -> String {
        if r.daysAgo == 0 { return "Hôm nay" }
        if r.daysAgo == 1 { return "Hôm qua" }
        return dayNames[weekday(r.date) - 1]
    }
}
