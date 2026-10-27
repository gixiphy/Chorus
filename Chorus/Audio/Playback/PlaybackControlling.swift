import ChorusCore

/// 對其他 App 的播放控制（來電接手，D-2026-10-27）。可假的接縫。
///
/// **契約**：`canAddress` 只在實作能把指令**確定送到這個 bundle**時回 true
/// ——送一個作用在 Now Playing 的全域切換鍵不算。`send` 回 `.delivered`
/// 也必須是同一個保證。引擎在 `canAddress == false` 時不送任何指令。
@MainActor
protocol PlaybackControlling: AnyObject {
    func canAddress(bundleID: String) -> Bool
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome
}

/// 無法定址任何 bundle：不送、不播。正式版在 Fi 決定媒體鍵／MediaRemote 之前用它。
@MainActor
final class NullPlaybackController: PlaybackControlling {
    func canAddress(bundleID: String) -> Bool { false }
    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome { .unsupported }
}
