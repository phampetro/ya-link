import AVFoundation
import Foundation
import UIKit

/// Ảnh chụp trạng thái điện thoại gửi cho CCU (cmd 316). Đọc nhanh, so sánh được để biết có đổi không.
struct PhoneStatusSnapshot: Equatable {
    /// 0…100, nil nếu iOS chưa biết.
    var battery: Int?
    /// Âm lượng cuộc gọi: iOS không cho app đọc, luôn nil (byte không hợp lệ).
    var callVolume: Int?
    /// Âm lượng media 0…100 (AVAudioSession.outputVolume).
    var mediaVolume: Int?
    var btAudio: Bool
    /// 0 bình thường, 1 hơi nóng, 2 nóng / rất nóng.
    var thermal: Int
    /// iOS không có API công khai đọc vạch sóng di động: luôn báo 5 (đầy) để xe không hiện "mất sóng".
    var signalBars: Int
}

@MainActor
enum PhoneStatusProbe {
    static func enable() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    static func read() -> PhoneStatusSnapshot {
        let level = UIDevice.current.batteryLevel            // -1 khi chưa biết
        let battery: Int? = level >= 0 ? Int((level * 100).rounded()) : nil
        let session = AVAudioSession.sharedInstance()
        let vol = Int((session.outputVolume * 100).rounded())
        let bt = session.currentRoute.outputs.contains { out in
            out.portType == .bluetoothA2DP || out.portType == .bluetoothHFP || out.portType == .bluetoothLE
        }
        let thermal: Int
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = 0
        case .fair: thermal = 1
        default: thermal = 2
        }
        return PhoneStatusSnapshot(battery: battery, callVolume: nil, mediaVolume: min(max(vol, 0), 100),
                                   btAudio: bt, thermal: thermal, signalBars: 5)
    }
}
