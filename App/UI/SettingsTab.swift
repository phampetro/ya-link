import DashCore
import PhotosUI
import SwiftUI

/// Tab Cài đặt: hồ sơ, lời chào, ảnh nền, thanh dưới trang chủ, trip và nhớt, tính đường;
/// chế độ nhà phát triển (chạm 5 lần vào dòng phiên bản) thêm lịch sử sử dụng, log và danh sách thử trên xe.
struct SettingsTab: View {
    let link: DashLink
    @ObservedObject var settings: AppSettings
    @ObservedObject var photos: PhotoStore
    @ObservedObject var ccu: CCULink
    @ObservedObject var history: HistoryStore
    let toaster: Toaster
    let goDash: () -> Void

    @State private var picked: [PhotosPickerItem] = []
    @State private var saving = false
    @State private var keyInput = ""
    @State private var keyMessage: (ok: Bool, text: String)?
    @State private var testingKey = false
    @State private var versionTaps = 0
    @State private var tapReset: DispatchWorkItem?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    PageTitle("Cài đặt")
                    profileGroup
                    greetingGroup
                    photoGroup
                    barGroup
                    tripGroup
                    routingGroup
                    if settings.devMode {
                        DevHistoryGroup(history: history, toaster: toaster).id("dev")
                        DevLogGroup(link: link, settings: settings)
                    }
                    versionLine(proxy)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: picked) { items in importPhotos(items) }
    }

    private var odo: Double? { ccu.data.odoKm }

    // MARK: - Hồ sơ, lời chào

    private var profileGroup: some View {
        VStack(spacing: 0) {
            GroupTitle("Hồ sơ").padding(.top, 0)
            GroupCard {
                HStack(spacing: 12) {
                    IconTile(symbol: Sym.person, color: .blue)
                    Text("Tên của bạn").font(.system(size: 16)).foregroundColor(Theme.text)
                    Spacer(minLength: 8)
                    TextField("Chưa đặt tên", text: $settings.userName)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.blue)
                        .frame(maxWidth: 170)
                        .submitLabel(.done)
                        .onChange(of: settings.userName) { v in
                            if v.count > 30 { settings.userName = String(v.prefix(30)) }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 50)
            }
        }
    }

    private var greetingGroup: some View {
        let nm = settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hello = DashUI.greeting(hour: Calendar.current.component(.hour, from: Date())) + (nm.isEmpty ? "" : ", \(nm)")
        return VStack(spacing: 0) {
            GroupTitle("Lời chào")
            GroupCard {
                HStack(spacing: 12) {
                    IconTile(symbol: Sym.sparkles, color: .orange)
                    Text("Chào khi mở máy").font(.system(size: 16)).foregroundColor(Theme.text)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $settings.greetingEnabled).labelsHidden().tint(Theme.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 50)
                if settings.greetingEnabled {
                    RowSeparator(inset: 58)
                    LinkRow(title: "Phát xem thử màn chào", icon: (Sym.play, .green)) {
                        goDash()
                        link.replayWelcome()
                    }
                }
            }
            GroupFoot(settings.greetingEnabled ? "Đồng hồ chào: \(hello)" : "Đang tắt: đồng hồ vào thẳng trang chủ.")
        }
    }

    // MARK: - Ảnh nền

    private var photoGroup: some View {
        let intervalBinding = Binding<Int>(get: { Int(photos.interval) }, set: { photos.interval = Double($0) })
        return VStack(spacing: 0) {
            GroupTitle("Ảnh nền")
            GroupCard {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(photos.thumbs.enumerated()), id: \.offset) { _, img in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Image(uiImage: img).resizable().scaledToFill())
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 3)
                    }
                    PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .images) {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Image(systemName: "plus").font(.system(size: 24, weight: .medium)).foregroundColor(Theme.blue))
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
                    }
                    .disabled(saving)
                }
                .padding(14)
                RowSeparator()
                PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .images) {
                    HStack(spacing: 12) {
                        IconTile(symbol: Sym.photo, color: .purple)
                        Text(photos.count == 0 ? "Chọn bộ ảnh nền" : "Đổi bộ ảnh (\(photos.count) ảnh)")
                            .font(.system(size: 16, weight: .medium)).foregroundColor(Theme.blue)
                        Spacer(minLength: 0)
                        if saving { Spinner() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .disabled(saving)
                RowSeparator()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Đổi ảnh mỗi").font(.system(size: 16)).foregroundColor(Theme.text)
                    PillSegmented(selection: intervalBinding, options: [(4, "4 giây"), (8, "8 giây"), (15, "15 giây")])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            GroupFoot((photos.count == 0 ? "Đang dùng 2 ảnh mẫu. " : "")
                      + "Ảnh nền dùng cho trang chủ và trang Nhạc. Bấm Enter ở trang chủ để đổi ảnh ngay.")
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

    // MARK: - Thanh dưới, trip, nhớt

    private var barGroup: some View {
        let binding = Binding<OdometerBook.BarItem>(
            get: { settings.odometer.barItem },
            set: { settings.odometer.barItem = $0; link.refreshBarText() })
        return VStack(spacing: 0) {
            GroupTitle("Thanh dưới trang chủ")
            GroupCard {
                PillSegmented(selection: binding, options: [(.odo, "ODO"), (.trip1, "TRIP 1"), (.trip2, "TRIP 2"), (.oil, "OIL")])
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            GroupFoot("Đồng hồ hiện: \(settings.odometer.barText(odoKm: odo))")
        }
    }

    private func km(_ v: Double?) -> String { v.map { "\(Fmt.dec($0)) km" } ?? "--" }

    private var tripGroup: some View {
        let book = settings.odometer
        let oil = book.oilRemainingKm(odoKm: odo)
        let oilText: String = {
            guard let r = oil else { return "--" }
            return r < 0 ? "quá \(Int(abs(r).rounded())) km" : "\(Int(r.rounded())) km"
        }()
        return VStack(spacing: 0) {
            GroupTitle("Trip và nhớt")
            GroupCard {
                Row("TRIP 1", value: km(book.trip1Km(odoKm: odo)), icon: (Sym.route, .blue))
                RowSeparator(inset: 58)
                Row("TRIP 2", value: km(book.trip2Km(odoKm: odo)), icon: (Sym.route, .purple))
                RowSeparator(inset: 58)
                Row("Nhớt còn", value: oilText, valueColor: (oil ?? 999) < 200 ? Theme.orange : Theme.sec,
                    bold: (oil ?? 999) < 200, icon: (Sym.drop, .orange))
                RowSeparator()
                HStack {
                    Button("Reset TRIP 1") { link.resetTrip(1) }
                    Spacer()
                    Button("Reset TRIP 2") { link.resetTrip(2) }
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.blue)
                .buttonStyle(.plain)
                .disabled(odo == nil)
                .opacity(odo == nil ? 0.35 : 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                RowSeparator()
                Row("Chu kỳ thay nhớt", subtitle: "\(Int(book.oilIntervalKm)) km") {
                    HStack(spacing: 0) {
                        stepButton("−") { step(-100) }
                        Rectangle().fill(Theme.sep).frame(width: 1, height: 34)
                        stepButton("+") { step(100) }
                    }
                    .background(Capsule().fill(Theme.fill))
                    .clipShape(Capsule())
                }
                RowSeparator()
                LinkRow(title: "Vừa thay nhớt", disabled: odo == nil) { link.oilChanged() }
            }
            GroupFoot(odo == nil
                      ? "Chưa đọc được ODO từ xe nên chưa tính được trip và nhớt."
                      : "Trip và nhớt tính từ ODO của xe, không đồng bộ với TRIP và OIL trên đồng hồ gốc.")
        }
    }

    private func stepButton(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 20)).foregroundColor(Theme.text).frame(width: 48, height: 34)
        }
        .buttonStyle(.plain)
    }

    private func step(_ d: Double) {
        settings.odometer.oilIntervalKm = min(5000, max(500, settings.odometer.oilIntervalKm + d))
        link.refreshBarText()
    }

    // MARK: - Tính đường

    private var routingGroup: some View {
        let src = Binding<AppSettings.RouteSource>(get: { settings.routeSource }, set: { settings.routeSource = $0 })
        return VStack(spacing: 0) {
            GroupTitle("Tính đường")
            GroupCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nguồn").font(.system(size: 16)).foregroundColor(Theme.text)
                    PillSegmented(selection: src, options: AppSettings.RouteSource.allCases.map { ($0, $0.title) })
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                if settings.routeSource == .auto {
                    RowSeparator()
                    Row("Google key", value: settings.maskedKey, icon: (Sym.key, .blue))
                    if settings.googleKey != nil {
                        RowSeparator(inset: 58)
                        Row("Số lần gọi Google tháng này", value: "\(settings.googleCalls)", icon: (Sym.tune, .teal))
                        RowSeparator()
                        LinkRow(title: "Xoá key", destructive: true) { settings.removeKey(); keyMessage = nil }
                    }
                    RowSeparator()
                    SecureField("Dán Google Routes API key", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 16))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    RowSeparator()
                    Button {
                        testKey()
                    } label: {
                        HStack {
                            if testingKey { Spinner() } else {
                                Text("Kiểm tra và lưu key").font(.system(size: 16, weight: .medium)).foregroundColor(Theme.blue)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testingKey)
                    .opacity(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                    if let m = keyMessage {
                        Text(m.text)
                            .font(.system(size: 13))
                            .foregroundColor(m.ok ? Theme.green : Theme.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if settings.routeSource == .auto { GroupFoot("Key chỉ được lưu khi thử thành công.") }
        }
    }

    private func testKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        testingKey = true
        keyMessage = nil
        Task {
            let result = await RoutePlanner.testGoogleKey(key)
            switch result {
            case .ok:
                settings.saveTestedKey(key)
                keyInput = ""
                keyMessage = (true, "✅ Key hợp lệ, hỗ trợ xe máy. Đã lưu.")
            case .invalidKey:
                keyMessage = (false, "❌ Key không hợp lệ hoặc chưa bật Routes API. Chưa lưu.")
            case .twoWheelerUnsupported:
                keyMessage = (false, "❌ Key đúng nhưng Google chưa hỗ trợ chế độ xe máy ở đây. Chưa lưu.")
            case .network(let m):
                keyMessage = (false, "❌ Lỗi mạng: \(m). Chưa lưu.")
            }
            testingKey = false
        }
    }

    // MARK: - Dòng phiên bản (chạm 5 lần: bật chế độ nhà phát triển)

    private func versionLine(_ proxy: ScrollViewProxy) -> some View {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        return Text("Ya Link \(v) · Không chính thức, không liên quan tới Yamaha Motor hay Garmin.")
            .font(.system(size: 12.5))
            .foregroundColor(Theme.sec)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .contentShape(Rectangle())
            .onTapGesture { tapVersion(proxy) }
    }

    private func tapVersion(_ proxy: ScrollViewProxy) {
        guard !settings.devMode else { return }
        versionTaps += 1
        tapReset?.cancel()
        let w = DispatchWorkItem { versionTaps = 0 }
        tapReset = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
        if versionTaps >= 5 {
            versionTaps = 0
            settings.devMode = true
            toaster.show("Đã bật chế độ nhà phát triển")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation { proxy.scrollTo("dev", anchor: .top) }
            }
        } else if versionTaps >= 3 {
            toaster.show("Còn \(5 - versionTaps) lần nữa")
        }
    }
}

// MARK: - Chế độ nhà phát triển

/// Lịch sử sử dụng: xuất CSV (chia sẻ file) và xoá.
private struct DevHistoryGroup: View {
    @ObservedObject var history: HistoryStore
    let toaster: Toaster
    @State private var csv: URL?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            GroupTitle("Lịch sử sử dụng")
            GroupCard {
                if let url = csv, !history.history.isEmpty {
                    SwiftUI.ShareLink(item: url) {
                        HStack(spacing: 12) {
                            IconTile(symbol: Sym.doc, color: .blue)
                            Text("Xuất lịch sử (CSV)").font(.system(size: 16, weight: .medium)).foregroundColor(Theme.blue)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    LinkRow(title: "Xuất lịch sử (CSV)", icon: (Sym.doc, .blue), disabled: true) {}
                }
                RowSeparator(inset: 58)
                LinkRow(title: "Xoá lịch sử", icon: (Sym.shield, .red), destructive: true, disabled: history.history.isEmpty) {
                    confirmClear = true
                }
            }
            GroupFoot("Mỗi ngày một dòng (km, lít). Sao lưu cùng iCloud.")
        }
        .onAppear { csv = history.exportURL() }
        .onChange(of: history.history) { _ in csv = history.exportURL() }
        .confirmationDialog("Xoá toàn bộ lịch sử?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Xoá lịch sử", role: .destructive) {
                history.clear()
                toaster.show("Đã xoá lịch sử")
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Không thể khôi phục. Trip và nhớt không bị ảnh hưởng.")
        }
    }
}

/// Trạng thái kết nối, log, danh sách thử trên xe, nút tắt chế độ nhà phát triển.
private struct DevLogGroup: View {
    let link: DashLink
    @ObservedObject var settings: AppSettings
    @State private var lines: [String] = []
    @State private var fullText = ""
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            GroupTitle("Nhà phát triển · Trạng thái")
            DevStatus(link: link)
            GroupTitle("Nhà phát triển · Log")
            GroupCard {
                VStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("Chưa có dòng log nào.")
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l) }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.sec)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                RowSeparator(inset: 58)
                SwiftUI.ShareLink(item: fullText) {
                    HStack(spacing: 12) {
                        IconTile(symbol: Sym.list, color: .gray)
                        Text("Xuất log").font(.system(size: 16, weight: .medium)).foregroundColor(Theme.blue)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RowSeparator()
                LinkRow(title: "Tắt chế độ nhà phát triển", destructive: true) { settings.devMode = false }
            }
            GroupFoot("Ghi mọi lệnh xe gửi về (nút Enter, ấn giữ, Home…) để dò lỗi khi thử trên xe.")
            GroupTitle("Thử trên xe (ghi lại kết quả)")
            GroupCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Bấm HOME → màn chào rồi trang chủ hiện lên đồng hồ?")
                    Text("2. Bấm UP, DOWN, bấm đúp từng nút.")
                    Text("3. Bấm ENTER (nút giữa ＋/－) 1 lần, rồi ấn giữ 2 giây.")
                    Text("4. Ấn giữ UP 2 giây, ấn giữ DOWN 2 giây.")
                    Text("5. Đang ở màn hình app, bấm HOME thêm 1 lần.")
                    Text("6. Tắt máy khi đang ở màn hình app, mở lại: có tự quay về không?")
                }
                .font(.system(size: 14))
                .foregroundColor(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        let recent = link.log.suffix(40).reversed()
        lines = recent.map { String(format: "%.3f  ", Double($0.ms) / 1000) + $0.text }
        fullText = link.logText
    }
}

private struct DevStatus: View {
    @ObservedObject var link: DashLink

    var body: some View {
        GroupCard {
            Row("Đồng hồ", value: link.partNumber)
            RowSeparator()
            Row("Kết nối", subtitle: link.status) { EmptyView() }
            RowSeparator()
            Row("Tốc độ xe", value: link.speed.map { "\($0) km/h" } ?? "--")
            RowSeparator()
            Row("Nút cuối", value: link.lastButton)
            RowSeparator()
            Row("Khung đã gửi", value: "\(link.framesSent) · \(String(format: "%.1f", link.lastFrameKB)) KB")
            RowSeparator()
            Row("Gửi → ACK", value: link.lastRoundTripMs.map { "\($0) ms" } ?? "--")
            RowSeparator()
            DevCCU(ccu: link.ccu)
        }
    }
}

private struct DevCCU: View {
    @ObservedObject var ccu: CCULink

    var body: some View {
        VStack(spacing: 0) {
            Row("CCU", subtitle: ccu.status) { EmptyView() }
            RowSeparator()
            Row("Khoá điện", value: ccu.data.ignitionOn.map { $0 ? "Bật" : "Tắt" } ?? "--")
            RowSeparator()
            Row("Vòng tua (chưa chắc)", value: ccu.data.rpm.map { "\($0)" } ?? "--")
            RowSeparator()
            Row("Xăng đã dùng", value: ccu.data.fuelUsedL.map { String(format: "%.2f L", $0) } ?? "--")
        }
    }
}
