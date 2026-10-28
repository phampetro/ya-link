import DashCore
import SwiftUI

@main
struct YaLinkApp: App {
    @StateObject private var link = DashLink()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Chỉ để CI chụp ảnh giao diện: YALINK_SKIP_ONBOARD=1 bỏ qua màn nhập tên, YALINK_DEV=1 bật chế độ nhà phát triển.
        let env = ProcessInfo.processInfo.environment
        if env["YALINK_SKIP_ONBOARD"] == "1" {
            UserDefaults.standard.set(true, forKey: "onboarded")
            if (UserDefaults.standard.string(forKey: "userName") ?? "").isEmpty {
                UserDefaults.standard.set("Trọng", forKey: "userName")
            }
        }
        if env["YALINK_DEV"] == "1" { UserDefaults.standard.set(true, forKey: "devMode") }
    }

    var body: some Scene {
        WindowGroup {
            RootView(link: link, settings: link.settings, nav: link.navigation)
                .onAppear { link.start() }
                .onOpenURL { link.handleOpen($0) }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { link.checkPasteboardForShare() }
                }
        }
    }
}
