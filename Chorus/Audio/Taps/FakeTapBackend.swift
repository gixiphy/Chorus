#if DEBUG
import ChorusCore
import CoreAudio
import Foundation

/// 可腳本化的 tap backend：E2E 與單元測試不需要權限、不碰 CoreAudio。
/// `mode` 控制 fake session 的統計走向——`.audio` 模擬有權限（樣本非零）、
/// `.zeros` 模擬權限被拒（回呼照跑、樣本全零，與實測的失敗形狀一致）。
@MainActor
final class FakeTapBackend: TapBackend {
    enum Mode { case audio, zeros }
    var mode: Mode = .audio
    private(set) var startedSessions: [(kind: TapSessionKind, target: String)] = []
    /// 各 bundle 目前的 session（測試查驗增益／靜音有沒有真的送到 realtime 端）。
    private(set) var liveSessions: [String: FakeTapSession] = [:]
    /// 每條 playthrough session 實際建在哪個裝置上（路由驗證用）。
    private(set) var startedOutputs: [String] = []

    var defaultOutputUID: String? = "fake-output-uid"
    /// 可路由的裝置。測試可增刪，模擬耳機插拔。
    var availableOutputUIDs: [String] = ["fake-output-uid", "fake-headphones"]

    func defaultOutputDeviceUID() -> String? { defaultOutputUID }
    func outputDeviceUIDs() -> [String] { availableOutputUIDs }

    func startProbeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID]
    ) throws -> any TapSession {
        startedSessions.append((.captureOnly, "probe"))
        return FakeTapSession(kind: .captureOnly, backend: self)
    }

    func startPlaythroughSession(
        bundleID: String, outputDeviceUID: String, initialGain: Float
    ) throws -> any TapSession {
        guard bundleID != Bundle.main.bundleIdentifier else {
            throw TapBackendError.refusedSelfTap
        }
        startedSessions.append((.playthrough, bundleID))
        startedOutputs.append(outputDeviceUID)
        let session = FakeTapSession(kind: .playthrough, backend: self, initialGain: initialGain)
        liveSessions[bundleID] = session
        return session
    }

    /// 目前的裝置級全域 session（B6-4）與它建立時的排除清單。
    private(set) var globalSession: FakeTapSession?
    private(set) var globalExclusions: [AudioObjectID] = []
    private(set) var globalStartCount = 0

    func startGlobalVolumeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID],
        initialGain: Float
    ) throws -> any TapSession {
        startedSessions.append((.playthrough, "global:\(outputDeviceUID)"))
        startedOutputs.append(outputDeviceUID)
        globalExclusions = excludingProcessObjects
        globalStartCount += 1
        let session = FakeTapSession(kind: .playthrough, backend: self, initialGain: initialGain)
        globalSession = session
        return session
    }

    private var outputChangedHandler: (@MainActor () -> Void)?
    func setDefaultOutputChangedHandler(_ handler: @escaping @MainActor () -> Void) {
        outputChangedHandler = handler
    }
    func simulateDefaultOutputChange() { outputChangedHandler?() }
}

@MainActor
final class FakeTapSession: TapSession {
    let kind: TapSessionKind
    private weak var backend: FakeTapBackend?
    private var accumulated = TapSessionStats()
    private(set) var stopped = false
    private(set) var lastGain: Float
    private(set) var lastMuted = false
    /// session 建立時的增益。與 `lastGain` 分開記，才驗得出「起步就在
    /// 正確的值上」而不是「建完再滑過去」。
    let initialGain: Float

    init(kind: TapSessionKind, backend: FakeTapBackend, initialGain: Float = 1) {
        self.kind = kind
        self.backend = backend
        self.initialGain = initialGain
        lastGain = initialGain
    }

    /// 每次讀 stats 前進約一秒的量（93 次回呼）；zeros 模式下非零數不動。
    var stats: TapSessionStats {
        guard !stopped else { return accumulated }
        accumulated.callbacks += 93
        if backend?.mode == .audio {
            accumulated.nonZeroCallbacks += 93
        }
        return accumulated
    }

    private(set) var lastEQ: EQSettings?

    func setGain(_ gain: Float) { lastGain = gain }
    func setMuted(_ muted: Bool) { lastMuted = muted }
    func setEQ(_ settings: EQSettings?) { lastEQ = settings }
    func stop() { stopped = true }
}
#endif
