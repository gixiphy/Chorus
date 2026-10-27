#if DEBUG
import AudioToolbox
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

    /// 沒設＝48000。
    var nominalRates: [String: NominalSampleRate] = [:]
    /// 依序記錄：「play:<bundle>@<uid>」「stop:<bundle>」「silencer+:<bundle>」「silencer-:<bundle>」
    private(set) var events: [String] = []
    private(set) var startedSilencers: [String] = []
    private(set) var liveSilencers: [String: FakeTapSilencer] = [:]
    /// > 0：下一次 startSilencer 丟錯並遞減。
    var silencerFailuresRemaining = 0
    /// 對這些 UID 建 playthrough 會丟錯。
    var failingPlaythroughOutputs: Set<String> = []

    func defaultOutputDeviceUID() -> String? { defaultOutputUID }
    func outputDeviceUIDs() -> [String] { availableOutputUIDs }

    /// 目前的探測 session。測試要對它觸發 `simulateDeviceReconfigured()`
    /// （模擬探測期間藍牙耳機切降噪），沒有參照就摸不到。
    private(set) var probeSession: FakeTapSession?

    func startProbeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID]
    ) throws -> any TapSession {
        startedSessions.append((.captureOnly, "probe"))
        let rate = nominalRates[outputDeviceUID] ?? NominalSampleRate(hertz: 48000)
        let session = FakeTapSession(
            kind: .captureOnly, backend: self, nominalSampleRate: rate, label: nil
        )
        probeSession = session
        return session
    }

    func startPlaythroughSession(
        bundleID: String, memberBundleIDs: [String], outputDeviceUID: String, initialGain: Float
    ) throws -> any TapSession {
        try rejectSelfTap(bundleID: bundleID, memberBundleIDs: memberBundleIDs)
        if failingPlaythroughOutputs.contains(outputDeviceUID) {
            throw TapBackendError.createAggregateFailed(-1)
        }
        startedSessions.append((.playthrough, bundleID))
        startedOutputs.append(outputDeviceUID)
        events.append("play:\(bundleID)@\(outputDeviceUID)")
        let rate = nominalRates[outputDeviceUID] ?? NominalSampleRate(hertz: 48000)
        let session = FakeTapSession(
            kind: .playthrough, backend: self, initialGain: initialGain,
            nominalSampleRate: rate, label: bundleID
        )
        liveSessions[bundleID] = session
        return session
    }

    /// 目前的裝置級調整 session（B6-4）與它建立時的排除清單。
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
        let rate = nominalRates[outputDeviceUID] ?? NominalSampleRate(hertz: 48000)
        let session = FakeTapSession(
            kind: .playthrough, backend: self, initialGain: initialGain,
            nominalSampleRate: rate, label: nil
        )
        globalSession = session
        return session
    }

    func startSilencer(bundleID: String, memberBundleIDs: [String]) throws -> any TapSilencer {
        try rejectSelfTap(bundleID: bundleID, memberBundleIDs: memberBundleIDs)
        if silencerFailuresRemaining > 0 {
            silencerFailuresRemaining -= 1
            throw TapBackendError.createTapFailed(-1)
        }
        startedSilencers.append(bundleID)
        events.append("silencer+:\(bundleID)")
        let silencer = FakeTapSilencer(bundleID: bundleID, backend: self)
        liveSilencers[bundleID] = silencer
        return silencer
    }

    /// 模擬來源的原生路徑：這個 bundle 目前有沒有被任何 tap 靜音（活著的 playthrough
    /// 或活著的 silencer）。沒有 → 原生輸出就是 `defaultOutputUID`；有 → nil。
    func sourceOutput(for bundleID: String) -> String? {
        let playthroughAlive = liveSessions[bundleID].map { !$0.stopped } ?? false
        let silencerAlive = liveSilencers[bundleID].map { !$0.stopped } ?? false
        if playthroughAlive || silencerAlive { return nil }
        return defaultOutputUID
    }

    /// 從 `events` 重播：自第一次 play 這個 bundle 起，靜音持有者（play +1、stop −1、
    /// silencer+ +1、silencer− −1）降到 0 的每個事件索引。空陣列＝從未解除靜音。
    func muteGaps(for bundleID: String, since index: Int = 0) -> [Int] {
        let playPrefix = "play:\(bundleID)@"
        let stopKey = "stop:\(bundleID)"
        let silencerPlus = "silencer+:\(bundleID)"
        let silencerMinus = "silencer-:\(bundleID)"
        var holders = 0
        var started = false
        var gaps: [Int] = []
        for (i, event) in events.enumerated() where i >= index {
            if event.hasPrefix(playPrefix) {
                holders += 1
                started = true
            } else if event == stopKey {
                holders -= 1
            } else if event == silencerPlus {
                holders += 1
                started = true
            } else if event == silencerMinus {
                holders -= 1
            } else {
                continue
            }
            if started && holders == 0 {
                gaps.append(i)
            }
        }
        return gaps
    }

    fileprivate func recordStop(label: String) {
        events.append("stop:\(label)")
    }

    fileprivate func recordSilencerStop(bundleID: String) {
        events.append("silencer-:\(bundleID)")
        if liveSilencers[bundleID]?.stopped == true {
            liveSilencers.removeValue(forKey: bundleID)
        }
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
    let nominalSampleRate: NominalSampleRate?
    private let label: String?

    init(
        kind: TapSessionKind,
        backend: FakeTapBackend,
        initialGain: Float = 1,
        nominalSampleRate: NominalSampleRate? = NominalSampleRate(hertz: 48000),
        label: String? = nil
    ) {
        self.kind = kind
        self.backend = backend
        self.initialGain = initialGain
        self.nominalSampleRate = nominalSampleRate
        self.label = label
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
    private(set) var lastAppEQ: EQSettings?
    var onDeviceReconfigured: (@MainActor (NominalSampleRate?) -> Void)?

    /// 測試鉤：模擬輸出裝置中途重新配置（藍牙耳機切降噪模式）。
    /// 保留原本無參數的呼叫方式；也可傳入新的名義取樣率。
    func simulateDeviceReconfigured(to rate: NominalSampleRate? = nil) {
        onDeviceReconfigured?(rate)
    }

    private(set) var lastBalance: Float = 0
    private(set) var lastDeviceEffects: [AUEffectEntry] = []
    private(set) var lastAppEffects: [AUEffectEntry] = []
    var effectLatch: ((String?) -> Void)?
    private(set) var effectFailures: [String] = []

    func setGain(_ gain: Float) { lastGain = gain }
    func setMuted(_ muted: Bool) { lastMuted = muted }
    func setBalance(_ balance: Float) { lastBalance = balance }
    func setEQ(_ settings: EQSettings?) { lastEQ = settings }
    func setAppEQ(_ settings: EQSettings?) { lastAppEQ = settings }

    func effectUnit(layer: AUEffectLayer, id: UUID) -> AudioUnit? { nil }

    func setDeviceEffects(_ entries: [AUEffectEntry]) {
        // 與真實 backend 同語意：只留 enabled 的格；latch 走一輪
        // （fake 不會真的實例化，但引擎端的閂流程要能被測到）
        lastDeviceEffects = simulateChainBuild(entries)
    }

    func setAppEffects(_ entries: [AUEffectEntry]) {
        lastAppEffects = simulateChainBuild(entries)
    }

    private func simulateChainBuild(_ entries: [AUEffectEntry]) -> [AUEffectEntry] {
        let active = entries.filter(\.enabled)
        for entry in active {
            effectLatch?(entry.component.key)
            effectLatch?(nil)
        }
        return active
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let label {
            backend?.recordStop(label: label)
        }
    }
}

@MainActor
final class FakeTapSilencer: TapSilencer {
    private let bundleID: String
    private weak var backend: FakeTapBackend?
    private(set) var stopped = false

    init(bundleID: String, backend: FakeTapBackend) {
        self.bundleID = bundleID
        self.backend = backend
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        backend?.recordSilencerStop(bundleID: bundleID)
    }
}
#endif
