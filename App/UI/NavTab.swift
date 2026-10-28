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
                GroupFoot("Trong Google Maps chọn địa điểm › Chia sẻ › Ya Link.")
                GroupTitle("Địa điểm đã lưu")
                places
                GroupFoot("Sao chép link Google Maps rồi bấm “Đặt … từ link”. Giữ Enter khi bản đồ đang mở để đi nhanh tới các nơi này.")
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
                savedRow(title: f.name, sub: f.sub.isEmpty ? Fmt.coords(f.lat, f.lon) : f.sub, color: .orange) {
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
            savedRow(title: slot.label, sub: pl.sub.isEmpty ? pl.name : "\(pl.name) · \(pl.sub)", color: color) {
                settings.removePlace(slot)
                toaster.show("Đã xoá")
            }
        } else {
            LinkRow(title: emptyTitle, icon: (Sym.pin, color)) { add(slot) }
        }
    }

    private func savedRow(title: String, sub: String, color: TileColor, onDelete: @escaping () -> Void) -> some View {
        Row(title, subtitle: sub, icon: (Sym.pin, color)) {
            Button("Xoá", action: onDelete)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.red)
                .buttonStyle(.plain)
        }
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
            case .authorizedWhenInUse: return ("Khi dùng app", Theme.orange, false)
            case .denied, .restricted: return ("Đã tắt", Theme.red, false)
            default: return ("Chưa cấp", Theme.sec, false)
            }
        }()
        return VStack(spacing: 0) {
            GroupCard {
                Button {
                    if !ok, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Row("Quyền vị trí", value: text, valueColor: color, bold: true, icon: (Sym.shield, .green))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !ok {
                GroupFoot("Cần “Luôn luôn” để dẫn đường khi khoá máy. Bấm để mở Cài đặt iPhone.")
            }
        }
    }
}

/// Bảng xác nhận điểm đến: "Đến đây?" (bắt đầu / lưu Nhà, Công ty, Yêu thích) hoặc "Lưu địa điểm này?" (luồng thêm).
struct ConfirmSheet: View {
    @ObservedObject var nav: NavigationController

    var body: some View {
        Group {
            if case .confirm(let p) = nav.state {
                content(p)
            } else {
                Color.clear
            }
        }
        .background(Theme.Background())
        .presentationDetents([.height(nav.pendingSlot == nil ? 410 : 350)])
        .presentationDragIndicator(.visible)
    }

    private func content(_ p: NavigationController.Pending) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(nav.pendingSlot == nil ? "Đến đây?" : "Lưu địa điểm này?")
                .font(.system(size: 22, weight: .bold)).foregroundColor(Theme.text)
            Text(p.name).font(.system(size: 19)).foregroundColor(Theme.text)
            Text(Fmt.coords(p.point.lat, p.point.lon))
                .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.sec)
            Text("Link Google Maps đôi khi đọc sai địa điểm. Kiểm tra tên và toạ độ trước khi tiếp tục.")
                .font(.system(size: 13)).foregroundColor(Theme.sec)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let slot = nav.pendingSlot {
                HStack(spacing: 8) {
                    Button("Huỷ") { nav.cancelPending() }.buttonStyle(.pill)
                    Button("Lưu làm \(slot.label)") { nav.savePending(as: slot) }.buttonStyle(.pillProminent)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Lưu Nhà") { nav.savePending(as: .home) }.buttonStyle(.pill)
                    Button("Lưu Công ty") { nav.savePending(as: .work) }.buttonStyle(.pill)
                    Button("Yêu thích") { nav.savePending(as: .fav) }.buttonStyle(.pill)
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
