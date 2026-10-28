import DashCore
import PhotosUI
import SwiftUI

@main
struct YaLinkApp: App {
    @StateObject private var link = DashLink()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .environmentObject(link.photos)
                .onAppear { link.start() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var link: DashLink
    @EnvironmentObject private var photos: PhotoStore
    @State private var picked: [PhotosPickerItem] = []
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section("Màn hình đồng hồ") {
                    preview
                    simulator
                    Toggle("Giả lập đang dẫn đường", isOn: $link.simulateNav)
                }
                Section("Kết nối") {
                    Text(link.status)
                    LabeledContent("Đồng hồ", value: link.partNumber)
                    LabeledContent("Tốc độ", value: link.speed.map { "\($0) km/h" } ?? "—")
                    LabeledContent("Nút cuối", value: link.lastButton)
                    LabeledContent("Khung đã gửi", value: "\(link.framesSent) · \(String(format: "%.1f", link.lastFrameKB)) KB")
                    LabeledContent("Gửi → ACK", value: link.lastRoundTripMs.map { "\($0) ms" } ?? "—")
                }
                Section("Ảnh nền") {
                    PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .images) {
                        Label(photos.count == 0 ? "Chọn bộ ảnh nền" : "Đổi bộ ảnh (\(photos.count) ảnh)",
                              systemImage: "photo.on.rectangle")
                    }
                    .disabled(saving)
                    Picker("Đổi ảnh mỗi", selection: $photos.interval) {
                        Text("4 giây").tag(4.0)
                        Text("8 giây").tag(8.0)
                        Text("15 giây").tag(15.0)
                    }
                }
                Section("Thử trên xe (ghi lại kết quả)") {
                    Text("1. Bấm HOME → màn chào rồi trang chủ hiện lên đồng hồ?")
                    Text("2. Bấm UP, DOWN, bấm đúp từng nút.")
                    Text("3. Bấm ENTER (nút giữa ＋/－) 1 lần, rồi ấn giữ 2 giây.")
                    Text("4. Ấn giữ UP 2 giây, ấn giữ DOWN 2 giây.")
                    Text("5. Đang ở màn hình app, bấm HOME thêm 1 lần.")
                    Text("6. Tắt máy khi đang ở màn hình app, mở lại: có tự quay về không?")
                }
                Section("Log (mới nhất ở trên)") {
                    ForEach(link.log.suffix(300).reversed()) { line in
                        Text(String(format: "%.3f  ", Double(line.ms) / 1000) + line.text)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Ya Link")
            .toolbar {
                ShareLink(item: link.logText) { Label("Xuất log", systemImage: "square.and.arrow.up") }
            }
            .onChange(of: picked) { items in
                guard !items.isEmpty else { return }
                saving = true
                Task {
                    var datas: [Data] = []
                    for item in items {
                        if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) }
                    }
                    photos.replace(with: datas)
                    picked = []
                    saving = false
                }
            }
        }
    }

    /// Đúng khung hình gửi lên đồng hồ (480×234), có vẽ thêm nút ＋/－ và thanh dưới mà đồng hồ tự vẽ.
    private var preview: some View {
        ZStack {
            if let img = link.preview {
                Image(uiImage: img).resizable().interpolation(.high)
            } else {
                Color.black
            }
            DashChrome(bar: link.barText)
        }
        .aspectRatio(480 / 234, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    private var simulator: some View {
        HStack(spacing: 8) {
            simButton("▲", .up)
            simButton("▼", .down)
            simButton("Enter", .enter)
            simButton("Giữ", .enterHold)
            simButton("Home", .home)
            Button("Chào") { link.replayWelcome() }.buttonStyle(.bordered)
        }
        .font(.callout.weight(.semibold))
    }

    private func simButton(_ title: String, _ b: DashUI.Button) -> some View {
        Button(title) { link.press(b) }.buttonStyle(.bordered)
    }
}

/// Nút ＋/－ và thanh dưới do đồng hồ tự vẽ đè lên hình (chỉ để xem trước trên điện thoại).
private struct DashChrome: View {
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
