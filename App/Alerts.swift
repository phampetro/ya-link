import Foundation
import UserNotifications

/// Thông báo trên iPhone của chính Ya Link (báo khi mất kết nối với xe lúc xe vẫn bật khoá điện).
/// Không liên quan tới tin nhắn / cuộc gọi hiện lên xe: phần đó do iOS tự gửi qua Bluetooth.
enum Alerts {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func connectionLost() {
        let content = UNMutableNotificationContent()
        content.title = "Ya Link"
        content.body = "Mất kết nối với xe, đang nối lại."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "link-lost", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
