import DashCore
import DashRender
import PhotosUI
import SwiftUI

@main
struct YaLinkApp: App {
    @StateObject private var link = DashLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .environmentObject(link.photos)
                .environmentObject(link.settings)
                .environmentObject(link.ccu)
                .environmentObject(link.location)
                .environmentObject(link.navigation)
                .onAppear { link.start() }
                .onOpenURL { link.handleOpen($0) }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { link.checkPasteboardForShare() }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var link: DashLink
    @EnvironmentObject private var photos: PhotoStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ccu: CCULink
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var nav: NavigationController

    @State private var picked: [PhotosPickerItem] = []
    @State private var saving = false
    @State private var keyInput = ""
    @State private var keyMessage = ""
    @State private var testingKey = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    dashSection.id("dash")
                    navigationSection.id("nav")
                    vehicleSection.id("vehicle")
                    tripSection.id("trip")
                    routingSection.id("routing")
                    photoSection.id("photo")
                    fieldTestSection.id("test")
                    logSection.id("log")
                }
                .onAppear {
                    // Chỉ dùng cho CI chụp ảnh màn hình trên trình giả lập: YALINK_SECTION=trip cuộn tới mục đó
                    guard let s = ProcessInfo.processInfo.environment["YALINK_SECTION"] else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { proxy.scrollTo(s, anchor: .top) }
                }
            }
            .navigationTitle("Ya Link")
            .toolbar {
                ShareLink(item: link.logText) { Label("Xuất log", systemImage: "square.and.arrow.up") }
            }
            .sheet(isPresented: confirmBinding) { confirmSheet }
            .onChange(of: picked) { items in importPhotos(items) }
        }
    }

    // MARK: - Màn hình đồng hồ

    private var dashSection: some View {
        Section("Màn hình đồng hồ") {
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

            HStack(spacing: 8) {
                simButton("▲", .up)
                simButton("▼", .down)
                simButton("Enter", .enter)
                simButton("Giữ", .enterHold)
                simButton("Home", .home)
                Button("Chào") { link.replayWelcome() }.buttonStyle(.bordered)
            }
            .font(.callout.weight(.semibold))

            Text(link.status)
            LabeledContent("Đồng hồ", value: link.partNumber)
            LabeledContent("Tốc độ xe", value: link.speed.map { "\($0) km/h" } ?? "—")
            LabeledContent("Nút cuối", value: link.lastButton)
            LabeledContent("Khung đã gửi", value: "\(link.framesSent) · \(String(format: "%.1f", link.lastFrameKB)) KB")
            LabeledContent("Gửi → ACK", value: link.lastRoundTripMs.map { "\($0) ms" } ?? "—")
        }
    }

    private func simButton(_ title: String, _ b: DashUI.Button) -> some View {
        Button(title) { link.press(b) }.buttonStyle(.bordered)
    }

    // MARK: - Dẫn đường

    private var navigationSection: some View {
        Section("Dẫn đường") {
            switch nav.state {
            case .idle:
                Text("Trong Google Maps: chọn địa điểm › Chia sẻ › Ya Link.")
            case .resolving:
                HStack { ProgressView(); Text("Đang đọc địa điểm…") }
            case .confirm(let p):
                Text("Chờ xác nhận: \(p.name)")
            case .routing:
                HStack { ProgressView(); Text("Đang tính đường…") }
            case .active:
                Label("Đang dẫn đường (\(nav.routeSource))", systemImage: "location.fill")
                Button("Dừng dẫn đường", role: .destructive) { nav.stop() }
            case .failed(let why):
                Text(why).foregroundColor(.red)
            }
            Button("Dán link từ bộ nhớ tạm") {
                if let s = UIPasteboard.general.string { nav.handleShared(text: s) }
            }
            .disabled(!UIPasteboard.general.hasStrings)
            Toggle("Giả lập đang dẫn đường", isOn: $link.simulateNav)
            LabeledContent("Vị trí", value: location.location.map {
                String(format: "%.5f, %.5f", $0.coordinate.latitude, $0.coordinate.longitude)
            } ?? locationHint)
        }
    }

    private var locationHint: String {
        switch location.authorization {
        case .denied, .restricted: return "Bị tắt: bật trong Cài đặt"
        case .notDetermined: return "Chưa cấp quyền"
        default: return "Đang tìm…"
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { if case .confirm = nav.state { return true } else { return false } },
                set: { if !$0 { nav.cancelPending() } })
    }

    @ViewBuilder private var confirmSheet: some View {
        if case .confirm(let p) = nav.state {
            VStack(alignment: .leading, spacing: 16) {
                Text("Đến đây?").font(.title2.bold())
                Text(p.name).font(.title3)
                Text(String(format: "%.5f, %.5f", p.point.lat, p.point.lon))
                    .font(.system(.footnote, design: .monospaced)).foregroundColor(.secondary)
                Text("Link Google Maps đôi khi đọc sai địa điểm. Kiểm tra tên và toạ độ rồi bắt đầu.")
                    .font(.footnote).foregroundColor(.secondary)
                HStack {
                    Button("Huỷ") { nav.cancelPending() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Bắt đầu") { nav.startConfirmed() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .presentationDetents([.height(300)])
        }
    }

    // MARK: - Xe (Link B)

    private var vehicleSection: some View {
        Section("Xe (Link B)") {
            Text(ccu.status)
            LabeledContent("Khoá điện", value: ccu.data.ignitionOn.map { $0 ? "Bật" : "Tắt" } ?? "—")
            LabeledContent("ODO", value: ccu.data.odoKm.map { String(format: "%.1f km", $0) } ?? "—")
            LabeledContent("Nước làm mát", value: ccu.data.coolantC.map { "\($0) °C" } ?? "—")
            LabeledContent("Ắc quy", value: ccu.data.batteryV.map { String(format: "%.1f V", $0) } ?? "—")
            LabeledContent("Vòng tua (chưa chắc)", value: ccu.data.rpm.map { "\($0)" } ?? "—")
            LabeledContent("Xăng đã dùng", value: ccu.data.fuelUsedL.map { String(format: "%.2f L", $0) } ?? "—")
        }
    }

    // MARK: - Trip, nhớt

    private var tripSection: some View {
        let odo = ccu.data.odoKm
        return Section("Thanh dưới trang chủ: ODO / Trip / Nhớt") {
            Picker("Hiện", selection: $settings.odometer.barItem) {
                Text("ODO").tag(OdometerBook.BarItem.odo)
                Text("TRIP 1").tag(OdometerBook.BarItem.trip1)
                Text("TRIP 2").tag(OdometerBook.BarItem.trip2)
                Text("OIL").tag(OdometerBook.BarItem.oil)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.odometer.barItem) { _ in link.refreshBarText() }
            LabeledContent("TRIP 1", value: settings.odometer.trip1Km(odoKm: odo).map { String(format: "%.1f km", $0) } ?? "—")
            LabeledContent("TRIP 2", value: settings.odometer.trip2Km(odoKm: odo).map { String(format: "%.1f km", $0) } ?? "—")
            LabeledContent("Nhớt còn", value: settings.odometer.oilRemainingKm(odoKm: odo).map { String(format: "%.0f km", $0) } ?? "—")
            HStack {
                Button("Reset TRIP 1") { link.resetTrip(1) }
                Spacer()
                Button("Reset TRIP 2") { link.resetTrip(2) }
            }
            .buttonStyle(.bordered)
            .disabled(odo == nil)
            Stepper("Chu kỳ thay nhớt: \(Int(settings.odometer.oilIntervalKm)) km",
                    value: $settings.odometer.oilIntervalKm, in: 500...5000, step: 100)
                .onChange(of: settings.odometer.oilIntervalKm) { _ in link.refreshBarText() }
            Button("Vừa thay nhớt") { link.oilChanged() }
                .disabled(odo == nil)
            if odo == nil {
                Text("Chưa đọc được ODO từ xe nên chưa tính được trip và nhớt.")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Tính đường

    private var routingSection: some View {
        Section("Tính đường") {
            Picker("Nguồn", selection: $settings.routeSource) {
                ForEach(AppSettings.RouteSource.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Google key", value: settings.maskedKey)
            if settings.googleKey != nil {
                LabeledContent("Số lần gọi Google tháng này", value: "\(settings.googleCalls)")
                Button("Xoá key", role: .destructive) { settings.removeKey(); keyMessage = "" }
            }
            SecureField("Dán Google Routes API key", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                testKey()
            } label: {
                if testingKey { ProgressView() } else { Text("Kiểm tra và lưu key") }
            }
            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || testingKey)
            if !keyMessage.isEmpty {
                Text(keyMessage).font(.footnote)
            }
        }
    }

    private func testKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        testingKey = true
        keyMessage = ""
        Task {
            let result = await RoutePlanner.testGoogleKey(key)
            switch result {
            case .ok:
                settings.saveTestedKey(key)
                keyInput = ""
                keyMessage = "✅ Key hợp lệ, hỗ trợ xe máy. Đã lưu."
            case .invalidKey:
                keyMessage = "❌ Key không hợp lệ hoặc chưa bật Routes API. Chưa lưu."
            case .twoWheelerUnsupported:
                keyMessage = "❌ Key đúng nhưng Google chưa hỗ trợ chế độ xe máy ở đây. Chưa lưu."
            case .network(let m):
                keyMessage = "❌ Lỗi mạng: \(m). Chưa lưu."
            }
            testingKey = false
        }
    }

    // MARK: - Ảnh nền

    private var photoSection: some View {
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
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
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

    // MARK: - Thử trên xe, log

    private var fieldTestSection: some View {
        Section("Thử trên xe (ghi lại kết quả)") {
            Text("1. Bấm HOME → màn chào rồi trang chủ hiện lên đồng hồ?")
            Text("2. Bấm UP, DOWN, bấm đúp từng nút.")
            Text("3. Bấm ENTER (nút giữa ＋/－) 1 lần, rồi ấn giữ 2 giây.")
            Text("4. Ấn giữ UP 2 giây, ấn giữ DOWN 2 giây.")
            Text("5. Đang ở màn hình app, bấm HOME thêm 1 lần.")
            Text("6. Tắt máy khi đang ở màn hình app, mở lại: có tự quay về không?")
        }
    }

    private var logSection: some View {
        Section("Log (mới nhất ở trên)") {
            ForEach(link.log.suffix(300).reversed()) { line in
                Text(String(format: "%.3f  ", Double(line.ms) / 1000) + line.text)
                    .font(.system(.caption, design: .monospaced))
            }
        }
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
