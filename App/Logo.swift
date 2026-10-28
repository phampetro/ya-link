import SwiftUI

/// Cung tròn vẽ bằng điểm (tránh nhầm chiều `clockwise` của SwiftUI): góc tăng dần = quay theo chiều kim đồng hồ trên màn hình.
private struct Arc: Shape {
    var cx: Double, cy: Double, r: Double
    var from: Double, to: Double       // độ

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = max(2, Int(abs(to - from) / 2))
        for i in 0...steps {
            let a = (from + (to - from) * Double(i) / Double(steps)) * .pi / 180
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Mũi kim lơ lửng (không chạm tâm vòng).
private struct Needle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 512, y: 366))
        p.addLine(to: CGPoint(x: 562, y: 574))
        p.addQuadCurve(to: CGPoint(x: 549, y: 588), control: CGPoint(x: 563, y: 588))
        p.addLine(to: CGPoint(x: 475, y: 588))
        p.addQuadCurve(to: CGPoint(x: 462, y: 574), control: CGPoint(x: 461, y: 588))
        p.closeSubpath()
        return p
    }
}

/// Logo Ya Link: ba cung hồng / xanh dương / xanh lá trên nền xanh đen, mũi kim lơ lửng phía trên tâm.
/// Vẽ theo hệ toạ độ 1024×1024 của file thiết kế rồi co lại theo `size`.
struct LogoView: View {
    var size: CGFloat = 108

    private let cx = 512.0, cy = 600.0, r = 330.0

    private func arc(_ a: Double, _ b: Double, grad: [Color], top: Double, bottom: Double) -> some View {
        ZStack {
            Arc(cx: cx, cy: cy, r: r, from: a, to: b)
                .stroke(LinearGradient(colors: grad,
                                       startPoint: UnitPoint(x: 0.5, y: top / 1024),
                                       endPoint: UnitPoint(x: 0.5, y: bottom / 1024)),
                        style: StrokeStyle(lineWidth: 92, lineCap: .round))
                .shadow(color: Color.black.opacity(0.38), radius: 16, x: 0, y: 14)
            Arc(cx: cx, cy: cy, r: r + 15, from: a, to: b)
                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 9, lineCap: .round))
            Arc(cx: cx, cy: cy, r: r - 17, from: a, to: b)
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
    }

    var body: some View {
        let clip = RoundedRectangle(cornerRadius: 230, style: .continuous)
        ZStack {
            clip.fill(LinearGradient(colors: [Color(hex: 0x16204a), Color(hex: 0x060914)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Group {
                RadialGradient(colors: [Color(hex: 0x2a7bff, opacity: 0.65), .clear], center: .center, startRadius: 0, endRadius: 440)
                    .frame(width: 880, height: 880).position(x: 190, y: 160)
                RadialGradient(colors: [Color(hex: 0xff2d78, opacity: 0.55), .clear], center: .center, startRadius: 0, endRadius: 400)
                    .frame(width: 800, height: 800).position(x: 900, y: 330)
                RadialGradient(colors: [Color(hex: 0x2fe07a, opacity: 0.5), .clear], center: .center, startRadius: 0, endRadius: 440)
                    .frame(width: 880, height: 880).position(x: 300, y: 950)
                LinearGradient(colors: [Color.white.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(width: 1024, height: 430).position(x: 512, y: 215)
            }
            arc(150, 226, grad: [Color(hex: 0xffa3b8), Color(hex: 0xff2d55)], top: 362, bottom: 765)
            arc(234, 306, grad: [Color(hex: 0x9bd6ff), Color(hex: 0x0a7aff)], top: 270, bottom: 333)
            arc(314, 390, grad: [Color(hex: 0x9cf4b0), Color(hex: 0x22b857)], top: 362, bottom: 765)
            Needle()
                .fill(LinearGradient(colors: [.white, Color.white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .overlay(Needle().stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 8, lineJoin: .round)))
                .shadow(color: Color.black.opacity(0.38), radius: 16, x: 0, y: 14)
            Circle().fill(Color.white.opacity(0.16))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 8))
                .frame(width: 100, height: 100).position(x: 512, y: 700)
            Circle().fill(Color.white).frame(width: 30, height: 30).position(x: 512, y: 700)
        }
        .frame(width: 1024, height: 1024)
        .clipShape(clip)
        .scaleEffect(size / 1024, anchor: .topLeading)
        .frame(width: size, height: size, alignment: .topLeading)
        .shadow(color: Color.black.opacity(0.3), radius: size * 0.1, x: 0, y: size * 0.12)
    }
}
