import SwiftUI

@main
struct YaLinkApp: App {
    @StateObject private var link = DashLink()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .onAppear { link.start() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var link: DashLink

    var body: some View {
        NavigationStack {
            List {
                Section("Kết nối") {
                    Text(link.status)
                    LabeledContent("Đồng hồ", value: link.partNumber)
                    LabeledContent("Tốc độ", value: link.speed.map { "\($0) km/h" } ?? "—")
                    LabeledContent("Nút cuối", value: link.lastButton)
                    LabeledContent("Khung đã gửi", value: "\(link.framesSent)")
                    LabeledContent("Gửi → ACK", value: link.lastRoundTripMs.map { "\($0) ms" } ?? "—")
                }
                Section("Thử trên xe (ghi lại kết quả)") {
                    Text("1. Bấm HOME → màn hình thử hiện lên đồng hồ?")
                    Text("2. Bấm UP, DOWN, bấm đúp từng nút.")
                    Text("3. Bấm ENTER (nút giữa ＋/－) 1 lần, rồi ấn giữ 2 giây.")
                    Text("4. Ấn giữ UP 2 giây, ấn giữ DOWN 2 giây.")
                    Text("5. Đang ở màn hình app, bấm HOME thêm 1 lần.")
                    Text("6. Tắt máy khi đang ở màn hình app, mở lại: có tự quay về không?")
                }
                Section("Log (mới nhất ở trên)") {
                    ForEach(link.log.reversed()) { line in
                        Text(String(format: "%.3f  ", Double(line.ms) / 1000) + line.text)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Ya Link")
            .toolbar {
                ShareLink(item: link.logText) { Label("Xuất log", systemImage: "square.and.arrow.up") }
            }
        }
    }
}
