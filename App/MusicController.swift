import DashCore
import MediaPlayer

/// Điều khiển Apple Music qua trình phát hệ thống. Spotify / YouTube Music cần SDK riêng của từng hãng.
@MainActor
final class MusicController {
    private let player = MPMusicPlayerController.systemMusicPlayer

    func requestAccess() {
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            MPMediaLibrary.requestAuthorization { _ in }
        }
    }

    var info: MusicInfo? {
        guard let item = player.nowPlayingItem else { return nil }
        let pos = player.currentPlaybackTime
        return MusicInfo(title: item.title ?? "Không rõ tên bài", artist: item.artist ?? "",
                         duration: item.playbackDuration, position: pos.isFinite ? pos : 0,
                         playing: player.playbackState == .playing, album: item.albumTitle ?? "")
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func next() { player.skipToNextItem() }
    func previous() { player.skipToPreviousItem() }
    func togglePlay() {
        if player.playbackState == .playing { player.pause() } else { player.play() }
    }
}
