import CallKit
import DashCore
import Foundation

/// Theo dõi cuộc gọi bằng CXCallObserver (không cần quyền đặc biệt). Chỉ biết trạng thái, không biết tên người gọi.
/// iOS không cho app trả lời / từ chối cuộc gọi, nên chỉ để báo lên đồng hồ và cho xe.
@MainActor
final class CallMonitor: NSObject, ObservableObject {
    @Published private(set) var state: DashUI.CallState = .none
    /// Lúc trạng thái đổi gần nhất.
    @Published private(set) var changedAt = Date()
    /// Gọi mỗi khi trạng thái đổi (đã so với trạng thái cũ).
    var onChange: ((DashUI.CallState) -> Void)?

    private let observer = CXCallObserver()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        observer.setDelegate(self, queue: .main)
        refresh()
    }

    /// Tổng hợp từ danh sách cuộc gọi: đang nói > đang đổ chuông (đến, chưa nghe) > không có.
    private func refresh() {
        var next: DashUI.CallState = .none
        for c in observer.calls where !c.hasEnded {
            if c.hasConnected {
                next = .active
                break
            }
            if !c.isOutgoing { next = .ringing }
        }
        guard next != state else { return }
        state = next
        changedAt = Date()
        onChange?(next)
    }
}

extension CallMonitor: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in self.refresh() }
    }
}
