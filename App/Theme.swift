import SwiftUI
import UIKit

// Phong cách "Liquid Glass" trên iOS 16: nền gradient mềm từ 3 màu logo, thẻ kính mờ (Material) có viền sáng,
// ô icon màu bo tròn, nút viên thuốc. Theo mockup design/phone/app.html.

extension Color {
    /// 0xRRGGBB
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Màu đổi theo giao diện sáng/tối.
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let h = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }

    static func dynA(_ light: UInt32, _ lightA: Double, _ dark: UInt32, _ darkA: Double) -> Color {
        Color(uiColor: UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let h = isDark ? dark : light
            return UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: CGFloat(isDark ? darkA : lightA))
        })
    }
}

enum Theme {
    static let text = Color.dyn(0x0b0d12, 0xf5f7fb)
    static let sec = Color.dyn(0x6d7280, 0x9aa1b2)
    static let blue = Color.dyn(0x0a7aff, 0x3d9bff)
    static let green = Color.dyn(0x22b857, 0x34d06a)
    static let red = Color.dyn(0xff3b30, 0xff5a4f)
    static let orange = Color.dyn(0xff8a00, 0xffa030)

    static let glass = Color.dynA(0xffffff, 0.40, 0x2c3242, 0.42)
    static let glassStrong = Color.dynA(0xffffff, 0.78, 0x343a4c, 0.80)
    static let edge = Color.dynA(0xffffff, 0.85, 0xffffff, 0.20)
    static let edgeFaint = Color.dynA(0xffffff, 0.25, 0xffffff, 0.05)
    static let sep = Color.dynA(0x5a647d, 0.16, 0xffffff, 0.10)
    static let fill = Color.dynA(0x78809a, 0.14, 0x96a0be, 0.18)
    static let lift = Color.dynA(0x283c6e, 0.13, 0x000000, 0.45)

    /// Nền: 3 quầng màu (xanh, hồng, lục) trên nền xám nhạt / đen xanh.
    struct Background: View {
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            GeometryReader { g in
                let dark = scheme == .dark
                ZStack {
                    (dark ? Color(hex: 0x05070c) : Color(hex: 0xf1f4f9))
                    RadialGradient(colors: [dark ? Color(hex: 0x0d3f84) : Color(hex: 0xbde0ff), .clear],
                                   center: UnitPoint(x: 0.12, y: 0.06), startRadius: 0, endRadius: g.size.width * 0.9)
                    RadialGradient(colors: [dark ? Color(hex: 0x5c1234) : Color(hex: 0xffd3e2), .clear],
                                   center: UnitPoint(x: 0.96, y: 0.22), startRadius: 0, endRadius: g.size.width * 0.85)
                    RadialGradient(colors: [dark ? Color(hex: 0x0c4d2c) : Color(hex: 0xc6f6d8), .clear],
                                   center: UnitPoint(x: 0.08, y: 0.80), startRadius: 0, endRadius: g.size.width * 0.9)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Kính

/// Nền kính mờ bo góc: vật liệu mờ + lớp trắng nhạt + viền sáng ở mép trên.
struct GlassBackground: View {
    var radius: CGFloat = 26
    var strong = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(strong ? Material.regularMaterial : Material.ultraThinMaterial)
            .overlay(shape.fill(strong ? Theme.glassStrong : Theme.glass))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Theme.edge, Theme.edgeFaint, Theme.edge.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
            .shadow(color: Theme.lift, radius: 14, x: 0, y: 8)
    }
}

extension View {
    func glassCard(radius: CGFloat = 26, strong: Bool = false) -> some View {
        background(GlassBackground(radius: radius, strong: strong))
    }
}

/// Nhóm các dòng trong một thẻ kính (các dòng tự đặt `RowSeparator` giữa chúng).
struct GroupCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .glassCard()
    }
}

struct RowSeparator: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(Theme.sep).frame(height: 1).padding(.leading, inset).padding(.trailing, 16)
    }
}

struct GroupTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12.5, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(Theme.sec)
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupFoot: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(Theme.sec)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PageTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .heavy))
            .foregroundColor(Theme.text)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Ô icon màu

enum TileColor {
    case blue, green, red, orange, purple, gray, teal

    var colors: [Color] {
        switch self {
        case .blue: return [Color(hex: 0x62c4ff), Color(hex: 0x0a7aff)]
        case .green: return [Color(hex: 0x74e590), Color(hex: 0x22b857)]
        case .red: return [Color(hex: 0xff7a85), Color(hex: 0xff2d55)]
        case .orange: return [Color(hex: 0xffc04a), Color(hex: 0xff8a00)]
        case .purple: return [Color(hex: 0xc58bff), Color(hex: 0x7b4dff)]
        case .gray: return [Color(hex: 0xaab0bc), Color(hex: 0x6c7382)]
        case .teal: return [Color(hex: 0x5eead4), Color(hex: 0x0e9f94)]
        }
    }
}

struct IconTile: View {
    let symbol: String
    var color: TileColor = .blue
    var size: CGFloat = 32

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: color.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: (color.colors.last ?? .blue).opacity(0.4), radius: 4, x: 0, y: 3)
    }
}

/// Tên SF Symbol an toàn cho iOS 16 (một số icon mới chỉ có từ iOS 17).
enum Sym {
    static var road: String { if #available(iOS 17.0, *) { return "road.lanes" } else { return "arrow.triangle.turn.up.right.diamond.fill" } }
    static var bike: String { if #available(iOS 17.0, *) { return "scooter" } else { return "bicycle" } }
    static let gauge = "speedometer"
    static let nav = "location.north.fill"
    static let tune = "slider.horizontal.3"
    static let thermo = "thermometer.medium"
    static let battery = "battery.100"
    static let drop = "drop.fill"
    static let pin = "mappin.and.ellipse"
    static let clipboard = "doc.on.clipboard"
    static let key = "key.fill"
    static let route = "point.topleft.down.curvedto.point.bottomright.up"
    static let shield = "checkmark.shield.fill"
    static let sparkles = "sparkles"
    static let person = "person.fill"
    static let play = "play.fill"
    static let photo = "photo.on.rectangle"
    static let list = "list.bullet"
    static let doc = "doc.text"
    static let radio = "antenna.radiowaves.left.and.right"
    static let arrow = "location.fill"
}

// MARK: - Dòng, nút, công tắc

/// Một dòng: icon (tuỳ chọn) + nhãn bên trái, nội dung bên phải.
struct Row<Trailing: View>: View {
    var icon: (String, TileColor)?
    let title: String
    var subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, icon: (String, TileColor)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let ic = icon { IconTile(symbol: ic.0, color: ic.1) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16)).foregroundColor(Theme.text)
                if let s = subtitle {
                    Text(s).font(.system(size: 13)).foregroundColor(Theme.sec)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 50)
    }
}

extension Row where Trailing == Text {
    init(_ title: String, value: String, valueColor: Color = Theme.sec, bold: Bool = false,
         icon: (String, TileColor)? = nil, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle, icon: icon) {
            Text(value)
                .font(.system(size: 16, weight: bold ? .bold : .regular))
                .foregroundColor(valueColor)
        }
    }
}

/// Dòng chỉ có một nút chữ (xanh hoặc đỏ), tuỳ chọn có icon.
struct LinkRow: View {
    let title: String
    var icon: (String, TileColor)?
    var destructive = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let ic = icon { IconTile(symbol: ic.0, color: ic.1) }
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(destructive ? Theme.red : Theme.blue)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(prominent ? .white : (destructive ? Theme.red : Theme.blue))
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    if prominent {
                        shape.fill(LinearGradient(colors: [Color(hex: 0x4aa6ff), Color(hex: 0x0a6cff)],
                                                  startPoint: .top, endPoint: .bottom))
                        shape.strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    } else {
                        shape.fill(Material.ultraThinMaterial)
                        shape.fill(Theme.glass)
                        shape.strokeBorder(Theme.edge, lineWidth: 1)
                    }
                }
                .shadow(color: prominent ? Color(hex: 0x0a6cff, opacity: 0.38) : Theme.lift, radius: 8, x: 0, y: 5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}

/// Nút chọn đoạn hình viên thuốc.
struct PillSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = opt.0 }
                } label: {
                    Text(opt.1)
                        .font(.system(size: 13, weight: on ? .bold : .regular))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(on ? Theme.glassStrong : Color.clear)
                                .overlay(Capsule().strokeBorder(on ? Theme.edge : Color.clear, lineWidth: 1))
                                .shadow(color: on ? Theme.lift : .clear, radius: 4, x: 0, y: 2)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.fill))
    }
}

struct Spinner: View {
    var body: some View { ProgressView().progressViewStyle(.circular).scaleEffect(0.9) }
}

/// Vòng tròn chữ cái đầu của tên (màu theo tên).
struct AvatarView: View {
    let name: String
    var size: CGFloat = 50

    static func initials(_ name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard let first = parts.first?.first else { return "" }
        if parts.count > 1, let last = parts.last?.first { return String([first, last]).uppercased() }
        return String(first).uppercased()
    }

    private var colors: [Color] {
        let pal: [[UInt32]] = [[0x62c4ff, 0x0a7aff], [0xff8fb0, 0xff2d55], [0x74e590, 0x1fa850],
                               [0xffc04a, 0xff7a00], [0xc58bff, 0x6f3dff]]
        var h: UInt32 = 0
        for u in name.unicodeScalars { h = h &* 31 &+ u.value }
        let p = pal[Int(h % UInt32(pal.count))]
        return [Color(hex: p[0]), Color(hex: p[1])]
    }

    var body: some View {
        let ini = Self.initials(name)
        ZStack {
            Circle().fill(ini.isEmpty
                          ? LinearGradient(colors: [Color(hex: 0xb4bac6), Color(hex: 0x7f8693)], startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
            if ini.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundColor(.white)
            } else {
                Text(ini).font(.system(size: size * 0.38, weight: .bold)).foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.lift, radius: 6, x: 0, y: 4)
    }
}

// MARK: - Định dạng

enum Fmt {
    /// 12.84 → "12,8"
    static func dec(_ v: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// 3214 → "3.214"
    static func thousands(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    static func coords(_ lat: Double, _ lon: Double) -> String { String(format: "%.5f, %.5f", lat, lon) }
}

// MARK: - Toast

@MainActor
final class Toaster: ObservableObject {
    @Published private(set) var text: String?
    private var task: Task<Void, Never>?

    func show(_ t: String) {
        text = t
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { self?.text = nil }
        }
    }
}

struct ToastView: View {
    @ObservedObject var toaster: Toaster

    var body: some View {
        Group {
            if let t = toaster.text {
                Text(t)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(GlassBackground(radius: 22, strong: true))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: toaster.text)
        .allowsHitTesting(false)
    }
}
