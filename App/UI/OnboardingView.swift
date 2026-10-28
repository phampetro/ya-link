import DashCore
import SwiftUI

/// Màn "Chào bạn!" lần đầu mở app: logo, hỏi tên, bật/tắt lời chào.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @State private var name = ""
    @State private var greeting = true
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LogoView(size: 108).padding(.top, 52)
                Text("Chào bạn!").font(.system(size: 32, weight: .heavy)).foregroundColor(Theme.text).padding(.top, 10)
                Text("Mình gọi bạn là gì nhỉ? Tên này sẽ hiện trên màn chào của đồng hồ mỗi khi bạn mở máy.")
                    .font(.system(size: 15)).foregroundColor(Theme.sec).multilineTextAlignment(.center)
                TextField("Tên của bạn", text: $name)
                    .focused($focused)
                    .font(.system(size: 20))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.text)
                    .submitLabel(.done)
                    .padding(15)
                    .glassCard(radius: 22)
                    .onChange(of: name) { v in if v.count > 30 { name = String(v.prefix(30)) } }
                Text(trimmed.isEmpty ? " " : "Xem trước: \(DashUI.greeting(hour: Calendar.current.component(.hour, from: Date()))), \(trimmed)")
                    .font(.system(size: 13)).foregroundColor(Theme.sec)
                HStack {
                    Text("Chào tôi mỗi khi mở máy").font(.system(size: 16)).foregroundColor(Theme.text)
                    Spacer()
                    Toggle("", isOn: $greeting).labelsHidden().tint(Theme.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassCard(radius: 22)
                Button("Tiếp tục") { finish(useName: true) }
                    .buttonStyle(.pillProminent)
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.4 : 1)
                    .padding(.top, 6)
                Button("Bỏ qua, không dùng tên") { finish(useName: false) }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.blue)
                Text("Đổi lại bất cứ lúc nào trong Cài đặt › Lời chào.")
                    .font(.system(size: 12.5)).foregroundColor(Theme.sec)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func finish(useName: Bool) {
        settings.userName = useName ? trimmed : ""
        settings.greetingEnabled = greeting
        settings.onboarded = true
    }
}
