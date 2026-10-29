import CoreLocation
import DashCore
import SwiftUI
import UIKit

/// Tab Dẫn đường: thẻ trạng thái, dán link, địa điểm đã lưu (Nhà / Công ty / Yêu thích), quyền vị trí.
struct NavTab: View {
    @ObservedObject var nav: NavigationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var location: LocationService
    let toaster: Toaster

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PageTitle("Dẫn đường")
                statusCard
                GroupTitle("Bắt đầu")
                GroupCard {
                    LinkRow(title: "Dán link từ bộ nhớ tạm", icon: (Sym.clipboard, .blue)) {
                        guard let s = UIPasteboard.general.string, !s.isEmpty else {
                            toaster.show("Chưa có link trong bộ nhớ tạm")
                            return
                        }
                        nav.handleShared(text: s)
                    }
                }
                GroupFoot("Chỉ nhận link có toạ độ: trong Google Maps chạm giữ để ghim vị trí, rồi Chia sẻ và sao chép.")
                GroupTitle("Địa điểm đã lưu")
                places
                GroupFoot("Chạm một nơi để đi ngay. Thêm nơi mới: sao chép link Google Maps rồi bấm “Đặt … từ link”.")
                GroupTitle("Vị trí")
                locationRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Trạng thái

    @ViewBuilder private var statusCard: some View {
        GroupCard {
            switch nav.state {
            case .idle:
                Row("Chưa chỉ đường", value: "", icon: (Sym.arrow, .gray))
            case .resolving:
                busy("Đang đọc địa điểm…")
            case .confirm(let p):
                Row("Chờ xác nhận", value: p.name, icon: (Sym.pin, .orange))
            case .routing:
                busy("Đang tính đường…")
            case .active:
                activeRows
            case .failed(let why):
                Row("Không tính được đường", subtitle: why, icon: (Sym.shield, .red)) { EmptyView() }
                RowSeparator()
                HStack(spacing: 24) {
                    Button("Thử lại") { nav.retry() }
                    Button("Đóng") { nav.dismissFailure() }.foregroundColor(Theme.sec)
                    Spacer()
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 12) {
            Spinner()
            Text(text).font(.system(size: 16)).foregroundColor(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 50)
    }

    @ViewBuilder private var activeRows: some View {
        let info = nav.info
        HStack(spacing: 12) {
            IconTile(symbol: Sym.arrow, color: .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(info?.destination ?? "Đang dẫn đường")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(Theme.text).lineLimit(1)
                if let i = info {
                    Text("\(Fmt.dec(i.remainingKm)) km · đến lúc \(NavTab.time(i.eta))")
                        .font(.system(size: 13)).foregroundColor(Theme.sec)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 50)
        RowSeparator(inset: 58)
        Row("Nguồn tuyến", value: nav.routeSource == "Google" ? "Google · Valhalla kiểm tra" : "Valhalla",
            icon: (Sym.route, .blue))
        if let i = info {
            RowSeparator(inset: 58)
            Row("Rẽ kế tiếp", value: "\(NavTab.glyph(i.maneuver)) \(DashUI.formatDistance(i.distanceToTurnM).value) \(DashUI.formatDistance(i.distanceToTurnM).unit) · \(i.nextStreet)",
                icon: (Sym.arrow, .teal))
        }
        RowSeparator()
        LinkRow(title: "Dừng dẫn đường", destructive: true) { nav.stop() }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func glyph(_ m: NavInfo.Maneuver) -> String {
        switch m {
        case .right: return "↱"
        case .left: return "↰"
        case .straight: return "↑"
        case .uturn: return "↶"
        case .roundabout: return "⟳"
        }
    }

    // MARK: - Địa điểm đã lưu

    private var places: some View {
        let p = settings.places
        return GroupCard {
            slotRow(.home, place: p.home, color: .blue, emptyTitle: "Đặt nhà từ link")
            RowSeparator(inset: 58)
            slotRow(.work, place: p.work, color: .purple, emptyTitle: "Đặt công ty từ link")
            ForEach(Array(p.favs.enumerated()), id: \.offset) { i, f in
                RowSeparator(inset: 58)
                savedRow(title: f.name, sub: f.sub.isEmpty ? Fmt.coords(f.lat, f.lon) : f.sub, color: .orange, go: go(f)) {
                    settings.removeFavourite(at: i)
                    toaster.show("Đã xoá")
                }
            }
            RowSeparator(inset: 58)
            LinkRow(title: "Thêm yêu thích từ link", icon: (Sym.pin, .orange)) { add(.fav) }
        }
    }

    @ViewBuilder private func slotRow(_ slot: PlaceSlot, place: SavedPlace?, color: TileColor, emptyTitle: String) -> some View {
        if let pl = place {
            savedRow(title: slot.label, sub: pl.sub.isEmpty ? pl.name : "\(pl.name) · \(pl.sub)", color: color, go: go(pl)) {
                settings.removePlace(slot)
                toaster.show("Đã xoá")
            }
        } else {
            LinkRow(title: emptyTitle, icon: (Sym.pin, color)) { add(slot) }
        }
    }

    /// Chạm vào một nơi đã lưu: bắt đầu đi luôn (Xoá nằm riêng bên phải).
    private func go(_ place: SavedPlace) -> () -> Void {
        {
            nav.navigate(to: place)
            toaster.show("Đi tới \(place.name)")
        }
    }

    private func savedRow(title: String, sub: String, color: TileColor, go: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        Row(title, subtitle: sub, icon: (Sym.pin, color)) {
            HStack(spacing: 14) {
                Button("Đi", action: go)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.blue)
                    .buttonStyle(.plain)
                Button("Xoá", action: onDelete)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.red)
                    .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: go)
    }

    private func add(_ slot: PlaceSlot) {
        guard let s = UIPasteboard.general.string, !s.isEmpty else {
            toaster.show("Chưa có link trong bộ nhớ tạm")
            return
        }
        nav.beginAdd(slot: slot, text: s)
    }

    // MARK: - Quyền vị trí

    private var locationRow: some View {
        let (text, color, ok): (String, Color, Bool) = {
            switch location.authorization {
            case .authorizedAlways: return ("Luôn luôn", Theme.green, true)
            case .authorizedWhenInUse: return ("Khi dùng app", Theme.green, true)
            case .denied, .restricted: return ("Đã tắt", Theme.red, false)
            default: return ("Chưa cấp", Theme.sec, false)
            }
        }()
        return VStack(spacing: 0) {
            GroupCard {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Row("Quyền vị trí", value: text, valueColor: color, bold: true, icon: (Sym.shield, .green))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            GroupFoot(ok ? "Bấm để mở Cài đặt iPhone và đổi quyền vị trí."
                         : "Cần cho phép vị trí để dẫn đường. Bấm để mở Cài đặt iPhone.")
        }
    }
}

/// Bảng xác nhận điểm đến: "Đến đây?" (bắt đầu / lưu Nhà, Công ty, Yêu thích) hoặc "Lưu địa điểm này?" (luồng thêm).
struct ConfirmSheet: View {
    @ObservedObject var nav: NavigationController
    @State private var name = ""
    @State private var seenAlternatives: [NavigationController.Candidate] = []

    var body: some View {
        Group {
            if case .confirm(let p) = nav.state {
                content(p)
            } else {
                Color.clear
            }
        }
        .background(Theme.Background())
        .onChange(of: nav.state) { s in
            // Đổi lựa chọn trong danh sách thì giữ tên đang gõ; còn lại xoá như cũ.
            if case .confirm(let p) = s, !p.alternatives.isEmpty, p.alternatives == seenAlternatives { return }
            name = ""
            if case .confirm(let p) = s { seenAlternatives = p.alternatives } else { seenAlternatives = [] }
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
    }

    /// Cao hơn khi có danh sách phương án (cuộn được).
    private var sheetHeight: CGFloat {
        let base: CGFloat = nav.pendingSlot == nil ? 500 : 440
        if case .confirm(let p) = nav.state, p.source == .search, p.alternatives.count >= 2 {
            return base + CGFloat(min(p.alternatives.count, 5)) * 54 + 16
        }
        return base
    }

    private func badge(_ p: NavigationController.Pending) -> some View {
        let (text, color): (String, Color) = {
            switch p.source {
            case .pin: return ("Toạ độ từ ghim địa điểm", Theme.green)
            case .viewport: return ("Lấy theo khung nhìn, có thể lệch vài trăm m", Theme.orange)
            case .search: return ("Tìm theo tên, kiểm tra đúng chỗ chưa", Theme.orange)
            }
        }()
        return Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func alternativesList(_ p: NavigationController.Pending) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(p.alternatives.prefix(5).enumerated()), id: \.offset) { i, c in
                    Button { nav.selectAlternative(i) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: i == p.selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(i == p.selected ? Theme.blue : Theme.sec)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1)
                                Text(c.address).font(.system(size: 12)).foregroundColor(Theme.sec).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let d = c.distanceM {
                                Text("\(Fmt.dec(d / 1000)) km").font(.system(size: 13)).foregroundColor(Theme.sec)
                            }
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: CGFloat(min(p.alternatives.count, 5)) * 54)
    }

    private func content(_ p: NavigationController.Pending) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(nav.pendingSlot == nil ? "Đến đây?" : "Lưu địa điểm này?")
                .font(.system(size: 22, weight: .bold)).foregroundColor(Theme.text)
            badge(p)
            Text(p.name).font(.system(size: 19)).foregroundColor(Theme.text).lineLimit(2)
            if p.source == .search, p.alternatives.count >= 2 { alternativesList(p) }
            TextField("Tên gợi nhớ (không bắt buộc)", text: $name)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
                .submitLabel(.done)
            Text(Fmt.coords(p.point.lat, p.point.lon))
                .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.sec)
            Text("Link Google Maps đôi khi đọc sai địa điểm. Kiểm tra tên và toạ độ trước khi tiếp tục.")
                .font(.system(size: 13)).foregroundColor(Theme.sec)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let slot = nav.pendingSlot {
                HStack(spacing: 8) {
                    Button("Huỷ") { nav.cancelPending() }.buttonStyle(.pill)
                    Button("Lưu làm \(slot.label)") { nav.savePending(as: slot, name: name) }.buttonStyle(.pillProminent)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Lưu Nhà") { nav.savePending(as: .home, name: name) }.buttonStyle(.pill)
                    Button("Lưu Công ty") { nav.savePending(as: .work, name: name) }.buttonStyle(.pill)
                    Button("Yêu thích") { nav.savePending(as: .fav, name: name) }.buttonStyle(.pill)
                }
                HStack(spacing: 8) {
                    Button("Huỷ") { nav.cancelPending() }.buttonStyle(.pill)
                    Button("Bắt đầu") { nav.startConfirmed() }.buttonStyle(.pillProminent)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
