import ChorusCore
import Foundation
import Observation

/// 音訊調音顧問的引擎接縫（DESIGN-20260831-audio-tuning-advisor）。
/// 純文字任務——不需要 vision；sandbox 只放 schema 檔。
protocol AudioAdviceProviding: Sendable {
    func advise(context: AudioTuningContext, sandbox: URL?) async throws -> AudioTuningAdvice
}

/// 正式引擎：與光環境顧問共用 CLIAdviceExecution（重試與錯誤映射同一份）。
struct CLIAudioAdviceProvider: AudioAdviceProviding {
    let engine: KnownCLIEngine
    let executable: URL
    var model: String?
    var timeout: Duration = .seconds(120)

    func advise(context: AudioTuningContext, sandbox: URL?) async throws -> AudioTuningAdvice {
        let run = KnownCLIEngine.RunContext(
            sandbox: sandbox,
            schemaFile: CLIAdviceExecution.writeSchema(AudioAdvicePrompt.schemaJSON, into: sandbox),
            model: engine.supportsModelSelection ? model : nil,
            timeout: timeout
        )
        return try await CLIAdviceExecution.perform(
            engine: engine, executable: executable,
            basePrompt: AudioAdvicePrompt.cliPrompt(context: context),
            run: run, as: AudioTuningAdvice.self
        )
    }
}

#if DEBUG
/// 測試／E2E 用：跳過 CLI，直接回注入的建議（與 FakeAdviceProvider 同構）。
struct FakeAudioAdviceProvider: AudioAdviceProviding {
    let advice: AudioTuningAdvice

    func advise(context: AudioTuningContext, sandbox: URL?) async throws -> AudioTuningAdvice {
        advice
    }
}
#endif

/// 調音目標：一個 App 或一個輸出裝置。
enum AudioTuningTarget: Equatable, Sendable {
    case app(bundleID: String)
    case device(uid: String)
}

/// 一次完成的分析結果（結果卡的資料源）。advice 已過 `sanitized(for:)`。
struct AudioTuningResult: Identifiable {
    let id = UUID()
    let target: AudioTuningTarget
    let advice: AudioTuningAdvice
    let context: AudioTuningContext
    let date: Date
}

/// 音訊調音顧問協調者：組 context、呼叫引擎、sanitize、套用／單層還原。
/// 引擎選擇與模型設定**共用**光環境顧問的 registry——設定頁只有一組。
@MainActor
@Observable
final class AudioTuningAdvisor {
    private(set) var isAnalyzing = false
    private(set) var lastErrorMessage: String?
    private(set) var lastErrorAssist: AdviceError.Assist?
    /// 設定後 UI 顯示結果卡；換目標或關閉時清 nil。
    var result: AudioTuningResult?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var tapEngine: TapEngine?
    @ObservationIgnored private weak var audioManager: AudioDeviceManager?
    @ObservationIgnored private weak var catalog: AUEffectCatalog?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    /// 光環境顧問的同一份 registry（引擎偵測與選擇不重複做）。
    /// nil＝無引擎（單元測試走 debugInject，不經 CLI）。
    @ObservationIgnored private let registry: AdviceEngineRegistry?

    init(
        settings: SettingsStore,
        registry: AdviceEngineRegistry?,
        tapEngine: TapEngine,
        audioManager: AudioDeviceManager?,
        catalog: AUEffectCatalog
    ) {
        self.settings = settings
        self.registry = registry
        self.tapEngine = tapEngine
        self.audioManager = audioManager
        self.catalog = catalog
    }

    var canAnalyze: Bool { registry?.activeEngine != nil }

    func analyze(target: AudioTuningTarget, request: String) {
        guard !isAnalyzing else { return }
        guard let engine = registry?.activeEngine else {
            lastErrorMessage = "未找到可用的分析引擎（設定 → 分析引擎）"
            lastErrorAssist = .openEngineSettings
            return
        }
        let provider = CLIAudioAdviceProvider(
            engine: engine.engine,
            executable: engine.url,
            model: settings.advisorModelIDs[engine.id]
        )
        run(provider: provider, target: target, request: request)
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    private func run(provider: any AudioAdviceProviding, target: AudioTuningTarget, request: String) {
        isAnalyzing = true
        lastErrorMessage = nil
        lastErrorAssist = nil
        let context = buildContext(target: target, request: request)
        analysisTask = Task { [weak self] in
            defer {
                self?.isAnalyzing = false
                self?.analysisTask = nil
            }
            // 沙箱只放 schema 檔（agy --json-schema 要檔案路徑）；用完即刪
            let sandbox = Self.makeSandbox()
            defer { if let sandbox { try? FileManager.default.removeItem(at: sandbox) } }
            do {
                let raw = try await provider.advise(context: context, sandbox: sandbox)
                guard let self, !Task.isCancelled else { return }
                self.result = AudioTuningResult(
                    target: target,
                    advice: raw.sanitized(for: context),
                    context: context,
                    date: Date()
                )
            } catch is CancellationError {
                // 使用者取消：不顯示錯誤
            } catch let error as AdviceError {
                self?.lastErrorMessage = error.userMessage
                self?.lastErrorAssist = error.assist
            } catch {
                self?.lastErrorMessage = "分析失敗：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Context 組裝

    func buildContext(target: AudioTuningTarget, request: String) -> AudioTuningContext {
        if let catalog, catalog.items.isEmpty { catalog.refresh() }
        let options = (catalog?.items ?? []).map {
            AudioTuningContext.EffectOption(
                key: $0.component.key, name: $0.name, manufacturerName: $0.manufacturerName
            )
        }
        let frequencies = EQSettings.tenBandDefault().bands.map(\.frequency)

        switch target {
        case let .app(bundleID):
            let setting = tapEngine?.setting(for: bundleID) ?? AppAudioSetting()
            return AudioTuningContext(
                targetKind: "app",
                targetName: tapEngine?.registry.displayName(bundleID: bundleID) ?? bundleID,
                targetDetail: "（bundle id：\(bundleID)）",
                request: request,
                bandFrequencies: frequencies,
                availableEffects: options,
                currentEQDescription: Self.describeEQ(setting.eq),
                currentEffectsDescription: Self.describeEffects(setting.effects)
            )
        case let .device(uid):
            let device = audioManager?.devices.first { $0.uid == uid }
            var details: [String] = []
            if let transport = device?.transportLabel { details.append(transport) }
            let eq = settings.deviceEQ[uid]
            if eq?.sourceName?.contains("AutoEq") == true {
                details.append("已套 AutoEq 校正")
            }
            return AudioTuningContext(
                targetKind: "device",
                targetName: device?.name ?? uid,
                targetDetail: details.isEmpty ? "" : "（\(details.joined(separator: "、"))）",
                request: request,
                bandFrequencies: frequencies,
                availableEffects: options,
                currentEQDescription: Self.describeEQ(eq),
                currentEffectsDescription: Self.describeEffects(settings.deviceEffects[uid] ?? [])
            )
        }
    }

    private static func describeEQ(_ eq: EQSettings?) -> String {
        guard let eq, eq.isActive else { return "" }
        let source = eq.sourceName ?? "手動"
        let gains = eq.bands.map { String(format: "%+.1f", locale: nil, $0.gainDB) }
            .joined(separator: ", ")
        return "\(source)（增益 dB：\(gains)）"
    }

    private static func describeEffects(_ effects: [AUEffectEntry]) -> String {
        guard !effects.isEmpty else { return "" }
        return effects.map { "\($0.name)\($0.enabled ? "" : "（關）")" }.joined(separator: " → ")
    }

    // MARK: - 套用與還原（單層、僅記憶體）

    private struct UndoSnapshot {
        var target: AudioTuningTarget
        var appEQ: EQSettings?
        var appEffects: [AUEffectEntry] = []
        var deviceEQ: EQSettings?
        var deviceEffects: [AUEffectEntry] = []
        var replacedEQ = false
        var replacedEffects = false
    }

    private var undoSnapshot: UndoSnapshot?
    var canUndo: Bool { undoSnapshot != nil }

    /// 套用建議：EQ 有建議才動 EQ、效果有建議才動效果鏈（模型沒建議的
    /// 部分不碰使用者現狀）。套用前 snapshot 舊值供單層還原。
    func apply(_ result: AudioTuningResult) {
        let advice = result.advice
        var snapshot = UndoSnapshot(target: result.target)

        let suggestedEQ = advice.eq.map { suggestion -> EQSettings in
            var eq = EQSettings.tenBandDefault()
            for (index, gain) in suggestion.bandsGainDB.enumerated() where index < eq.bands.count {
                eq.bands[index].gainDB = gain
            }
            eq.sourceName = "AI 建議"
            return eq
        }
        let suggestedEffects = advice.effects.compactMap { suggestion -> AUEffectEntry? in
            guard let item = catalog?.items.first(where: { $0.component.key == suggestion.componentKey })
            else { return nil }
            return catalog?.makeEntry(item)
        }

        switch result.target {
        case let .app(bundleID):
            let current = tapEngine?.setting(for: bundleID) ?? AppAudioSetting()
            if let suggestedEQ {
                snapshot.appEQ = current.eq
                snapshot.replacedEQ = true
                tapEngine?.setAppEQ(suggestedEQ, bundleID: bundleID)
            }
            if !suggestedEffects.isEmpty {
                snapshot.appEffects = current.effects
                snapshot.replacedEffects = true
                tapEngine?.setAppEffects(suggestedEffects, bundleID: bundleID)
            }
        case let .device(uid):
            guard let device = audioManager?.devices.first(where: { $0.uid == uid }) else {
                lastErrorMessage = "裝置目前不在，無法套用"
                return
            }
            if let suggestedEQ {
                snapshot.deviceEQ = settings.deviceEQ[uid]
                snapshot.replacedEQ = true
                audioManager?.setEQSettings(suggestedEQ, for: device)
            }
            if !suggestedEffects.isEmpty {
                snapshot.deviceEffects = settings.deviceEffects[uid] ?? []
                snapshot.replacedEffects = true
                audioManager?.setDeviceEffects(suggestedEffects, for: device)
            }
        }
        if snapshot.replacedEQ || snapshot.replacedEffects {
            undoSnapshot = snapshot
        }
    }

    /// 還原上次套用（單層）。
    func undoLastApply() {
        guard let snapshot = undoSnapshot else { return }
        switch snapshot.target {
        case let .app(bundleID):
            if snapshot.replacedEQ { tapEngine?.setAppEQ(snapshot.appEQ, bundleID: bundleID) }
            if snapshot.replacedEffects {
                tapEngine?.setAppEffects(snapshot.appEffects, bundleID: bundleID)
            }
        case let .device(uid):
            guard let device = audioManager?.devices.first(where: { $0.uid == uid }) else { break }
            if snapshot.replacedEQ {
                audioManager?.setEQSettings(snapshot.deviceEQ ?? EQSettings(), for: device)
            }
            if snapshot.replacedEffects {
                audioManager?.setDeviceEffects(snapshot.deviceEffects, for: device)
            }
        }
        undoSnapshot = nil
    }

    private nonisolated static func makeSandbox() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-audio-advisor-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return url
        } catch {
            return nil
        }
    }

    // MARK: - DEBUG 注入（TestHooks／單元測試）

    #if DEBUG
    /// 以 FakeAudioAdviceProvider 走完整管線（context → sanitize → result）。
    func debugInject(target: AudioTuningTarget, adviceJSON: String) {
        guard !isAnalyzing,
              let data = adviceJSON.data(using: .utf8),
              let advice = try? JSONDecoder().decode(AudioTuningAdvice.self, from: data) else { return }
        run(provider: FakeAudioAdviceProvider(advice: advice), target: target, request: "")
    }

    /// 無頭套用目前結果（E2E 斷言用）。
    func debugApply() {
        guard let result else { return }
        apply(result)
    }
    #endif
}
