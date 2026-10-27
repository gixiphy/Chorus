#if DEBUG
import ChorusCore

@MainActor
final class FakePlaybackController: PlaybackControlling {
    /// 模擬「目前能確定送達的 bundle」（例如 Now Playing 是誰）。測試可隨時改。
    var addressable: Set<String> = []
    var nextOutcome: PlaybackCommandOutcome = .delivered
    private(set) var commands: [(command: PlaybackCommand, bundleID: String)] = []
    /// 送出時呼叫（測試用它改 registry 的發聲狀態，模擬對方真的停了或播了）。
    var onSend: ((PlaybackCommand, String) -> Void)?

    func canAddress(bundleID: String) -> Bool { addressable.contains(bundleID) }

    func send(_ command: PlaybackCommand, bundleID: String) -> PlaybackCommandOutcome {
        commands.append((command, bundleID))
        onSend?(command, bundleID)
        return nextOutcome
    }
}
#endif
