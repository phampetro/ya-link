import DashCore
import AVFoundation
import Darwin
import Foundation
import MediaPlayer
import UIKit

/// Nhạc của bất kỳ app nào (Spotify, YouTube Music, Zing, Apple Music…) qua MediaRemote, thứ Trung tâm điều khiển của iOS dùng.
/// Đây là framework riêng của iOS (không có API công khai), nên nạp lúc chạy; nếu bị chặn thì tự chuyển sang trình phát Apple Music.
@MainActor
final class MusicController {
    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias PlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias CommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias AppIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFString?) -> Void) -> Void

    private enum Command: UInt32 { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let getInfo: InfoFn?
    private let getPlaying: PlayingFn?
    private let sendCommand: CommandFn?
    private let register: RegisterFn?
    private let getAppID: AppIDFn?
    private var remoteApp = "?"
    private var remoteDictState = "chưa trả lời"

    /// Dòng nhật ký (DashLink nối vào `add`).
    var onLog: ((String) -> Void)?

    private var cached: MusicInfo?
    private var remoteReplies = 0
    private var remoteHadTrack = false
    private var loggedState = ""

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        func load<T>(_ name: String, as: T.Type) -> T? {
            guard let h = handle, let s = dlsym(h, name) else { return nil }
            return unsafeBitCast(s, to: T.self)
        }
        getInfo = load("MRMediaRemoteGetNowPlayingInfo", as: InfoFn.self)
        getPlaying = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: PlayingFn.self)
        sendCommand = load("MRMediaRemoteSendCommand", as: CommandFn.self)
        register = load("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
        getAppID = load("MRMediaRemoteGetNowPlayingApplicationDisplayID", as: AppIDFn.self)
    }

    func requestAccess() {
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            MPMediaLibrary.requestAuthorization { _ in }
        }
        register?(DispatchQueue.main)      // đăng ký nhận thông tin "đang phát" như Trung tâm điều khiển
        let ok = getInfo != nil && sendCommand != nil
        onLog?("nhạc: MediaRemote \(ok ? "nạp được" : "không nạp được, dùng Apple Music")")
    }

    /// Bài đang phát (lần đọc gần nhất, cập nhật mỗi lần gọi `refresh()`).
    var info: MusicInfo? { cached }

    /// Đọc lại bài đang phát (không chặn); kết quả nằm ở `info` cho lần gọi sau.
    func refresh() {
        guard let getInfo = getInfo else { cached = appleMusicInfo(); return }
        getInfo(DispatchQueue.main) { [weak self] dict in
            let snapshot = dict as? [String: Any]
            Task { @MainActor in
                guard let self = self else { return }
                self.remoteReplies += 1
                if let s = snapshot {
                    self.remoteDictState = s.isEmpty ? "từ điển rỗng" : "có \(s.count) mục: " + s.keys.sorted().map { $0.replacingOccurrences(of: "kMRMediaRemoteNowPlayingInfo", with: "") }.joined(separator: ",")
                } else {
                    self.remoteDictState = "không có từ điển"
                }
                self.apply(remote: snapshot)
            }
        }
        getAppID?(DispatchQueue.main) { [weak self] id in
            let name = (id as String?) ?? "không có"
            Task { @MainActor in self?.remoteApp = name }
        }
        getPlaying?(DispatchQueue.main) { [weak self] playing in
            Task { @MainActor in
                guard let self = self, var m = self.cached else { return }
                m.playing = playing
                self.cached = m
            }
        }
    }

    private func apply(remote: [String: Any]?) {
        if let d = remote, let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty {
            let rate = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
            var pos = (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double) ?? 0
            if rate > 0, let stamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                pos += max(0, Date().timeIntervalSince(stamp)) * rate
            }
            let duration = (d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double) ?? 0
            cached = MusicInfo(title: title,
                               artist: (d["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? "",
                               duration: duration, position: duration > 0 ? min(pos, duration) : pos,
                               playing: d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] == nil ? (cached?.playing ?? false) : rate > 0,
                               album: (d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? "")
            remoteHadTrack = true
            logState("đọc được từ MediaRemote: \(title)")
        } else {
            cached = appleMusicInfo()
            logState(remoteHadTrack || cached != nil
                     ? "MediaRemote không có bài, dùng Apple Music: \(cached?.title ?? "không có bài")"
                     : "MediaRemote không có tên bài (\(remoteReplies) lần), app đang phát: \(remoteApp), \(remoteDictState)")
        }
    }

    /// Chỉ ghi nhật ký khi trạng thái nguồn nhạc đổi, tránh tràn mỗi giây.
    private func logState(_ text: String) {
        // So sánh bỏ phần số lần đọc trong ngoặc để không ghi lặp mỗi giây
        let key = text.replacingOccurrences(of: #" \(\d+ lần\)"#, with: "", options: .regularExpression)
        guard key != loggedState else { return }
        loggedState = key
        onLog?("nhạc: \(text)")
    }

    private func appleMusicInfo() -> MusicInfo? {
        guard let item = player.nowPlayingItem else { return nil }
        let pos = player.currentPlaybackTime
        return MusicInfo(title: item.title ?? "Không rõ tên bài", artist: item.artist ?? "",
                         duration: item.playbackDuration, position: pos.isFinite ? pos : 0,
                         playing: player.playbackState == .playing, album: item.albumTitle ?? "")
    }

    private func send(_ c: Command, fallback: () -> Void) {
        if let sendCommand = sendCommand, remoteHadTrack || cached == nil {
            let ok = sendCommand(c.rawValue, nil)
            onLog?("nhạc: gửi lệnh \(c) → \(ok ? "được nhận" : "bị từ chối")")
            if ok { return }
        }
        fallback()
    }

    func play() { send(.play) { player.play() } }
    func pause() { send(.pause) { player.pause() } }
    func next() { send(.next) { player.skipToNextItem() } }
    func previous() { send(.previous) { player.skipToPreviousItem() } }
    /// Bật/tắt phát bằng lệnh của iOS, không phụ thuộc việc đọc được trạng thái hay không (app khác thường bị chặn đọc).
    func togglePlay() {
        send(.toggle) { cached?.playing == true ? player.pause() : player.play() }
    }

    // MARK: - Âm lượng

    private var volumeView: MPVolumeView?

    /// Âm lượng hiện tại của điện thoại, 0…100.
    var systemVolume: Int { Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded()) }

    /// Chỉnh âm lượng hệ thống (delta theo thang 0…100) bằng thanh âm lượng ẩn của iOS.
    /// Thường chỉ chạy khi app đang mở; khoá máy hoặc ở nền có thể không có tác dụng, kết quả ghi vào nhật ký.
    func adjustVolume(by delta: Int) {
        let view: MPVolumeView
        if let v = volumeView {
            view = v
        } else {
            view = MPVolumeView(frame: CGRect(x: -400, y: -400, width: 200, height: 40))
            view.alpha = 0.01
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
            window?.addSubview(view)
            volumeView = view
        }
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else {
            onLog?("nhạc: không tìm thấy thanh âm lượng")
            return
        }
        let before = AVAudioSession.sharedInstance().outputVolume
        let target = min(1, max(0, before + Float(delta) / 100))
        slider.value = target
        slider.sendActions(for: .valueChanged)
        onLog?("nhạc: âm lượng \(Int(before * 100)) → \(Int(target * 100)) %")
    }
}
