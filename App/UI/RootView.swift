import DashCore
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case dash, nav, car, set
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dash: return "Đồng hồ"
        case .nav: return "Dẫn đường"
        case .car: return "Xe"
        case .set: return "Cài đặt"
        }
    }

    var symbol: String {
        switch self {
        case .dash: return Sym.gauge
        case .nav: return Sym.nav
        case .car: return Sym.bike
        case .set: return Sym.tune
        }
    }
}

/// Gốc giao diện: nền gradient, 4 tab với thanh tab nổi kiểu kính, màn nhập tên lần đầu, bảng xác nhận điểm đến.
struct RootView: View {
    let link: DashLink
    @ObservedObject var settings: AppSettings
    @ObservedObject var nav: NavigationController
    @State private var tab: AppTab = RootView.initialTab()

    /// YALINK_TAB=dash|nav|car|set (chỉ để CI chụp ảnh).
    private static func initialTab() -> AppTab {
        let s = ProcessInfo.processInfo.environment["YALINK_TAB"] ?? ""
        return AppTab(rawValue: s) ?? .dash
    }

    var body: some View {
        ZStack {
            Theme.Background()
            if settings.onboarded {
                main
            } else {
                OnboardingView(settings: settings)
            }
        }
        .overlay(alignment: .bottom) {
            ToastView(toaster: link.toaster).padding(.bottom, settings.onboarded ? 100 : 40)
        }
        .sheet(isPresented: confirmBinding) { ConfirmSheet(nav: nav) }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { if case .confirm = nav.state { return true } else { return false } },
            set: { shown in
                if !shown, case .confirm = nav.state { nav.cancelPending() }
            })
    }

    private var main: some View {
        Group {
            switch tab {
            case .dash:
                DashTab(link: link, ccu: link.ccu, settings: settings, history: link.history,
                        goSettings: { tab = .set })
            case .nav:
                NavTab(nav: nav, settings: settings, location: link.location, toaster: link.toaster)
            case .car:
                CarTab(history: link.history, settings: settings)
            case .set:
                SettingsTab(link: link, settings: settings, photos: link.photos, ccu: link.ccu,
                            history: link.history, toaster: link.toaster, goDash: { tab = .dash })
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(tab: $tab)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
    }
}

/// Thanh tab nổi hình viên thuốc bằng kính mờ; tab đang chọn là viên thuốc sáng hơn.
struct FloatingTabBar: View {
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { t in
                let on = t == tab
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = t }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: t.symbol).font(.system(size: 21, weight: on ? .semibold : .regular))
                        Text(t.title).font(.system(size: 10.5, weight: on ? .semibold : .medium))
                    }
                    .foregroundColor(on ? Theme.blue : Theme.sec)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        Capsule().fill(on ? Theme.glassStrong : Color.clear)
                            .overlay(Capsule().strokeBorder(on ? Theme.edge : Color.clear, lineWidth: 1))
                            .shadow(color: on ? Theme.lift : .clear, radius: 5, x: 0, y: 3)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(GlassBackground(radius: 34, strong: false))
    }
}
