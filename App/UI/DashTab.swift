import DashCore
import DashRender
import ExternalAccessory
import SwiftUI

/// Tab Đồng hồ: lời chào + trạng thái kết nối, 4 ô số liệu của xe, màn hình đồng hồ xem trước và các nút ▲ ▼ Enter Home.
struct DashTab: View {
    let link: DashLink
    @ObservedObject var ccu: CCULink
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    let goSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DashHeader(link: link, name: settings.userName, goSettings: goSettings)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                tiles
                vehicleCaption
                GroupTitle("Xem thử trên đồng hồ")
                DashPreview(link: link)
                DashButtons(link: link)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    /// Một dòng nhỏ báo vì sao chưa có số liệu xe (chỉ hiện khi một trong 3 ô xe còn trống).
    @ViewBuilder private var vehicleCaption: some View {
        let d = ccu.data
        if d.coolantC == nil || d.batteryV == nil || d.odoKm == nil {
            Text(ccu.status)
                .font(.system(size: 12.5))
                .foregroundColor(Theme.sec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
    }

    private var avg: Double? { history.history.summary(range: settings.historyRange).kmPerLitre }

    private var tiles: some View {
        let d = ccu.data
        let cl: DashUI.Level = d.coolantC.map { DashUI.coolantLevel($0) } ?? .normal
        let bl: DashUI.Level = d.batteryV.map { DashUI.batteryLevel($0) } ?? .normal
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(symbol: Sym.thermo, color: .orange, label: "Nước làm mát",
                     value: d.coolantC.map { String($0) } ?? "--", unit: d.coolantC == nil ? "" : "°C", level: cl)
            StatTile(symbol: Sym.battery, color: .green, label: "Ắc quy",
                     value: d.batteryV.map { Fmt.dec($0) } ?? "--", unit: d.batteryV == nil ? "" : "V", level: bl)
            StatTile(symbol: Sym.road, color: .blue, label: "ODO",
                     value: d.odoKm.map { Fmt.thousands(Int($0.rounded(.down))) } ?? "--", unit: d.odoKm == nil ? "" : "km", level: .normal)
            StatTile(symbol: Sym.drop, color: .purple, label: "Tiêu hao TB \(settings.historyRange) ngày",
                     value: avg.map { Fmt.dec($0) } ?? "--", unit: avg == nil ? "" : "km/L", level: .normal)
        }
    }
}

/// Ô số liệu lớn (kính mờ, tô cam/đỏ khi cảnh báo).
struct StatTile: View {
    let symbol: String
    let color: TileColor
    let label: String
    let value: String
    let unit: String
    var level: DashUI.Level = .normal

    private var numColor: Color {
        switch level {
        case .normal: return Theme.text
        case .warn: return Theme.orange
        case .bad: return Theme.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundColor(numColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !unit.isEmpty {
                        Text(unit).font(.system(size: 15, weight: .bold)).foregroundColor(Theme.sec)
                    }
                }
                Text(label).font(.system(size: 12.5)).foregroundColor(Theme.sec).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                GlassBackground(radius: 26)
                if level != .normal {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill((level == .bad ? Theme.red : Theme.orange).opacity(0.16))
                }
            }
        )
    }
}

/// Lời chào (trái) và trạng thái kết nối (phải).
private struct DashHeader: View {
    @ObservedObject var link: DashLink
    let name: String
    let goSettings: () -> Void

    var body: some View {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 10) {
            Button(action: goSettings) {
                HStack(spacing: 12) {
                    AvatarView(name: nm)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(nm.isEmpty ? "Xin chào" : "Xin chào,")
                            .font(.system(size: 13)).foregroundColor(Theme.sec)
                        Text(nm.isEmpty ? "bạn" : nm)
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            connection
        }
    }

    @ViewBuilder private var connection: some View {
        switch link.phase {
        case .none:
            Button {
                EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { _ in }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: Sym.radio).font(.system(size: 14, weight: .bold))
                    Text("Kết nối").font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 17)
                .padding(.vertical, 11)
                .background(
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0x4aa6ff), Color(hex: 0x0a6cff)], startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                        .shadow(color: Color(hex: 0x0a6cff, opacity: 0.38), radius: 8, x: 0, y: 6)
                )
            }
            .buttonStyle(.plain)
        case .handshake:
            pill(dot: AnyView(Spinner()), sub: "Đang kết nối…", color: Theme.sec)
        case .ready:
            pill(dot: AnyView(StatusDot(color: Theme.orange)), sub: "Chờ bấm HOME", color: Theme.orange)
        case .showing:
            pill(dot: AnyView(StatusDot(color: Theme.green)), sub: "Đã kết nối", color: Theme.green)
        }
    }

    private func pill(dot: AnyView, sub: String, color: Color) -> some View {
        HStack(spacing: 8) {
            dot
            VStack(alignment: .leading, spacing: 0) {
                Text(link.accessoryName).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.text).lineLimit(1)
                Text(sub).font(.system(size: 11.5, weight: .semibold)).foregroundColor(color).lineLimit(1)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 176)
        .background(GlassBackground(radius: 24))
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .background(Circle().fill(color.opacity(0.22)).frame(width: 18, height: 18))
            .frame(width: 18, height: 18)
    }
}

/// Màn hình đồng hồ xem trước: ảnh do DashRenderer vẽ + nút ＋/－ và thanh dưới do đồng hồ tự vẽ.
private struct DashPreview: View {
    @ObservedObject var link: DashLink

    var body: some View {
        ZStack {
            if let img = link.preview {
                Image(uiImage: img).resizable().interpolation(.high)
            } else {
                Color.black
            }
            DashChrome(bar: link.barText)
        }
        .aspectRatio(480 / 234, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// ▲ ▼ [Enter: chạm = Enter, giữ 0,6 s = giữ Enter] Home.
private struct DashButtons: View {
    let link: DashLink

    var body: some View {
        HStack(spacing: 8) {
            Button("▲") { link.press(.up) }.buttonStyle(.pill)
            Button("▼") { link.press(.down) }.buttonStyle(.pill)
            Button("Home") { link.press(.home) }.buttonStyle(.pill)
        }
        .padding(.top, 12)
    }
}

/// Nút ＋/－ và thanh dưới do đồng hồ tự vẽ đè lên hình (chỉ để xem trước trên điện thoại).
struct DashChrome: View {
    let bar: String

    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 480
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: 29 * s, y: 68 * s)); p.addLine(to: CGPoint(x: 49 * s, y: 99.5 * s))
                    p.addLine(to: CGPoint(x: 9 * s, y: 99.5 * s)); p.closeSubpath()
                    p.move(to: CGPoint(x: 9 * s, y: 116 * s)); p.addLine(to: CGPoint(x: 49 * s, y: 116 * s))
                    p.addLine(to: CGPoint(x: 29 * s, y: 147.5 * s)); p.closeSubpath()
                }
                .fill(Color(white: 0.96))
                Text("▲ \(bar)")
                    .font(.system(size: 20 * s, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: g.size.width, height: g.size.height - 188 * s)
                    .background(Color.black.opacity(0.62))
                    .offset(y: 188 * s)
            }
        }
        .allowsHitTesting(false)
    }
}
