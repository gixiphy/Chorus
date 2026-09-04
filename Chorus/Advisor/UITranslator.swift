import AppKit
import ChorusCore
import Foundation
import Observation

/// 「用本機 CLI 翻譯介面」的協調器（DESIGN-20260902-user-cli-translation）。
/// 讀內建英文 → 分批送引擎 → 驗證 → 寫進 `UITranslationStore`。每批寫回一次，
/// 取消或中途失敗不白做；補翻只送缺的 key。
@MainActor
@Observable
final class UITranslator {
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        /// 這一輪翻好了（或補翻好了）；`needsRelaunch` 表示目前跑的不是這個語言。
        case finished(translated: Int, skipped: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 目標語言（BCP 47：ja、ko、pt-BR…）。預設系統語言裡第一個非內建的。
    var targetLanguage: String

    @ObservationIgnored private let store: UITranslationStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let registry: AdviceEngineRegistry
    /// 寫 `AppleLanguages` 的 domain。見 `languageDefaults(instance:environment:)`。
    @ObservationIgnored private let languageDefaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 測試用：換掉真的 CLI。
    @ObservationIgnored var batchRunner: (any UITranslationBatchRunning)?

    /// 已翻好的語言、它們的 manifest 與待補條數。**快取在可觀察的狀態裡**：
    /// `store` 不是 `@Observable`，View 直接讀檔的話 SwiftUI 追蹤不到檔案系統的變化，
    /// 移除語言後那一列不會消失（2026-09-04 回報）。順帶也省掉每次重算 body 的讀檔。
    private(set) var installedLanguages: [String] = []
    private(set) var manifests: [String: UITranslationStore.Manifest] = [:]
    private(set) var missingCounts: [String: Int] = [:]

    /// 起始批量。之後**依引擎實際表現動態調整**：一批完整回來又夠快就加量，
    /// 回覆缺條（輸出被截斷）或整批失敗就砍半重送。不同 CLI 的輸出上限與速度
    /// 差很多（claude 一批 40 條約 8 秒，agy 同一份 prompt 會卡死），寫死一個
    /// 數字不是太保守就是會截斷。
    static let batchSize = 40
    static let minBatchSize = 10
    static let maxBatchSize = 120
    /// 每次加量的幅度（加法成長，不用倍增：一次跨太大踩到上限代價高）。
    static let batchGrowStep = 20
    /// 一批在這個秒數內回完才加量。
    static let batchGrowSeconds: TimeInterval = 60
    /// 同一條字串被模型漏掉時最多重送幾次，之後就退回英文。
    static let maxItemAttempts = 2
    /// 整批硬失敗（逾時、decode 壞掉）幾次之後收手。降批量重送救得回截斷，
    /// 救不回卡死的引擎——不設上限就會一直重試下去。
    static let maxBatchFailures = 2
    /// 同時在跑的批數。批與批之間互不相干（各是一次獨立的 CLI 呼叫），循序送
    /// 15 批要半小時（2026-09-04 實測一批約兩分鐘），開併發把牆鐘時間壓下來。
    static let maxConcurrentBatches = 4

    /// 內建英文來源只讀一次：600 條字串、執行期不會變，但 `missingCount`
    /// 與設定頁每次重算 body 都會用到。
    static let builtinSource = UITranslationStore.builtinSource()

    init(
        store: UITranslationStore,
        settings: SettingsStore,
        registry: AdviceEngineRegistry,
        /// 刻意沒有預設值：測試行程的 `.standard` 就是 test host（Chorus.app 本尊）的
        /// domain，寫錯地方會把使用者的介面語言改掉。每個呼叫端自己講清楚寫哪裡。
        languageDefaults: UserDefaults
    ) {
        self.store = store
        self.settings = settings
        self.registry = registry
        self.languageDefaults = languageDefaults
        targetLanguage = settings.uiTranslationLanguage
            ?? Self.suggestedLanguage(preferred: Locale.preferredLanguages)
            ?? "ja"
        refreshInstalled()
    }

    // MARK: - 狀態

    /// 介面語言的三種選法。內建語言靠 App domain 的 `AppleLanguages` 生效，
    /// 自翻語言靠 `TranslatedBundle` 覆蓋 `Bundle.main`——兩者都要重啟才會換，
    /// Foundation 在行程啟動時就把語言決定好了。
    enum Selection: Hashable {
        /// 跟隨系統：系統語言是三種內建語言之一就用它，否則由 Foundation 挑。
        case system
        /// 指定一種內建語言（zh-Hant／zh-Hans／en）。
        case builtin(String)
        /// 使用者自翻的語言；沒翻到的字串退回英文。
        case translated(String)
    }

    /// 使用者選定要用的介面語言。切走**不會**刪翻譯檔，之後還能再切回來。
    var selection: Selection {
        get {
            if let language = settings.uiTranslationLanguage { return .translated(language) }
            if let builtin = settings.builtinLanguage { return .builtin(builtin) }
            return .system
        }
        set {
            switch newValue {
            case .system:
                settings.uiTranslationLanguage = nil
                settings.builtinLanguage = nil
                applyAppleLanguages(nil)
            case let .builtin(code):
                settings.uiTranslationLanguage = nil
                settings.builtinLanguage = code
                applyAppleLanguages(code)
            case let .translated(code):
                settings.uiTranslationLanguage = code
                settings.builtinLanguage = nil
                // 覆蓋查不到的 key 會落到內建語言：釘成英文，才是翻譯的來源那份
                // （README 與 DESIGN 講的「未翻的退回英文」）。
                applyAppleLanguages("en")
            }
        }
    }

    /// 寫 App domain 的 `AppleLanguages`；nil＝拿掉，回到系統語言。
    /// 只有下次啟動才會生效——這也是設定頁一律提示重啟的原因。
    private func applyAppleLanguages(_ code: String?) {
        if let code {
            languageDefaults.set([code], forKey: "AppleLanguages")
        } else {
            languageDefaults.removeObject(forKey: "AppleLanguages")
        }
    }

    /// `AppleLanguages` 要寫進 App 自己的 domain 才會生效，所以正常情境是 `.standard`。
    /// `--instance` 與測試行程改寫各自的 suite：同一個 App bundle 只有一種語言，
    /// 不能讓 E2E 或單元測試把使用者本尊的介面語言改掉（代價是那些情境選內建語言
    /// 不會生效，都是開發用途，可接受）。
    static func languageDefaults(instance: InstanceConfig, environment: [String: String]) -> UserDefaults {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return UserDefaults(suiteName: "com.hermes.Chorus.tests.language") ?? .standard
        }
        guard instance.name == nil else { return instance.defaults }
        return .standard
    }

    /// 這個行程實際跑的是哪個語言：`AppState` 掛完覆蓋後設一次。
    nonisolated(unsafe) static var runningSelection: Selection = .system

    func manifest(for language: String) -> UITranslationStore.Manifest? { manifests[language] }

    /// 重讀檔案系統，更新上面三份快取。啟動、翻完一批、移除語言時各叫一次——
    /// 檔案只有我們自己會動，不必每次畫面更新都掃一遍。
    func refreshInstalled() {
        let languages = store.installedLanguages()
        var manifests: [String: UITranslationStore.Manifest] = [:]
        var missing: [String: Int] = [:]
        for language in languages {
            manifests[language] = store.manifest(for: language)
            missing[language] = missingItems(for: language, source: Self.builtinSource).count
        }
        installedLanguages = languages
        self.manifests = manifests
        missingCounts = missing
    }

    /// 選定的與正在執行的不同：要重啟才會生效（含切回內建語言）。
    var needsRelaunch: Bool {
        var desired = selection
        // 翻譯檔不在（被手動刪掉）就當作沒選——重啟也救不回來，別掛著一個假提示
        if case let .translated(code) = desired, manifests[code] == nil { desired = .system }
        return desired != Self.runningSelection
    }

    /// 某個已翻語言裡，內建字串尚未翻的條數（升版後會長出來）。
    func missingCount(for language: String) -> Int { missingCounts[language] ?? 0 }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var activeEngine: AdviceEngineRegistry.DetectedEngine? { registry.activeEngine }

    /// 系統語言裡第一個 App 沒內建的；全都內建就 nil。
    /// "ja-JP" → "ja"；中文保留 script（zh-Hans-CN → zh-Hans）；其餘保留 region
    /// 只在 Apple 有分開在地化的情況（pt-BR、pt-PT、es-419），其他去掉。
    static func suggestedLanguage(preferred: [String]) -> String? {
        for identifier in preferred {
            let normalized = normalize(identifier)
            if !UITranslationStore.builtinLanguages.contains(normalized) { return normalized }
        }
        return nil
    }

    static func normalize(_ identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        guard let code = locale.language.languageCode?.identifier else { return identifier }
        if code == "zh" {
            let script = locale.language.script?.identifier
                ?? (locale.region?.identifier == "CN" || locale.region?.identifier == "SG" ? "Hans" : "Hant")
            return "zh-\(script)"
        }
        if let region = locale.region?.identifier {
            let keepRegion: Set<String> = ["pt-BR", "pt-PT", "es-419", "en-GB", "fr-CA"]
            let candidate = "\(code)-\(region)"
            if keepRegion.contains(candidate) { return candidate }
        }
        return code
    }

    /// 設定頁 Picker 的候選：系統建議 ＋ 常用語言，去重。
    var candidateLanguages: [String] {
        var list: [String] = []
        if let suggested = Self.suggestedLanguage(preferred: Locale.preferredLanguages) { list.append(suggested) }
        // 不列內建語言（zh-Hant／zh-Hans／en）——那幾個在上面的「介面語言」選單裡
        for code in ["ja", "ko", "de", "fr", "es", "pt-BR", "it", "ru", "vi", "th", "id", "nl", "pl", "tr", "uk", "ar"]
        where !list.contains(code) && !UITranslationStore.builtinLanguages.contains(code) {
            list.append(code)
        }
        if !list.contains(targetLanguage) { list.insert(targetLanguage, at: 0) }
        return list
    }

    /// 「日本語（Japanese）」：本地名＋介面語言裡的名字。
    static func displayName(for language: String) -> String {
        let endonym = Locale(identifier: language).localizedString(forIdentifier: language) ?? language
        let exonym = Locale.current.localizedString(forIdentifier: language) ?? language
        return endonym == exonym ? endonym : "\(endonym)（\(exonym)）"
    }

    // MARK: - 動作

    /// 一批送出去的結果。TaskGroup 的結果型別必須是 Sendable，而 `any Error`
    /// 不是，所以錯誤在這裡先收斂成可搬運的形狀。
    private struct BatchOutcome: Sendable {
        var items: [UITranslationItem]
        var reply: UITranslationBatch?
        var failure: BatchFailure?
        /// 這批花了多久：加量與否看它。
        var elapsed: TimeInterval
    }

    private enum BatchFailure: Error, Sendable {
        case advice(AdviceError)
        case other(String)

        var message: String {
            switch self {
            case let .advice(error): error.userMessage
            case let .other(text): text
            }
        }
    }

    /// 翻譯（或補翻）目標語言。`onlyMissing` 為 true 時保留既有譯文、只送缺的。
    func translate(onlyMissing: Bool) {
        guard !isRunning else { return }
        guard let engine = registry.activeEngine else {
            phase = .failed(String(localized: "未找到可用的 AI 引擎（設定 → AI 引擎）"))
            return
        }
        let language = targetLanguage
        let source = Self.builtinSource
        let existing: (strings: [String: String], plurals: [String: [String: String]]) =
            onlyMissing ? store.existingTranslations(for: language) : (strings: [:], plurals: [:])
        var strings = existing.strings
        var plurals = existing.plurals
        var skipped = Set(onlyMissing ? (store.manifest(for: language)?.skipped ?? []) : [])

        // 沒有中日韓文字、英文又等於 key 的（"%@ — %@"、"DDC/CI"）不用問模型
        var items: [UITranslationItem] = []
        for (key, english) in source.strings.sorted(by: { $0.key < $1.key }) where strings[key] == nil {
            if english == key, !Self.containsCJK(key) {
                strings[key] = english
                continue
            }
            items.append(UITranslationItem(id: items.count, key: key, english: english))
        }
        for (key, forms) in source.plurals.sorted(by: { $0.key < $1.key }) where plurals[key] == nil {
            items.append(UITranslationItem(id: items.count, key: key, english: forms["other"], plural: forms))
        }

        let total = items.count
        guard total > 0 else {
            phase = .finished(translated: strings.count + plurals.count, skipped: skipped.count)
            return
        }
        phase = .running(done: 0, total: total)
        let runner = batchRunner ?? CLIUITranslationBatchRunner(
            engine: engine.engine, executable: engine.url, model: settings.advisorModelIDs[engine.id]
        )
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let languageName = AdviceLanguage.name(forLocalization: language)

        task = Task { [weak self] in
            defer { self?.task = nil }
            // 待送佇列：批量是動態的，所以不預先切好批，每次從佇列前面取「當下批量」條。
            var pending = items
            var attempts: [Int: Int] = [:]
            var batchSize = Self.batchSize
            var resolved = 0
            var failures = 0
            var inFlight = 0
            let started = Date()
            ChorusLog.app.notice(
                "介面翻譯開始：\(language) \(total) 條，起始批量 \(batchSize)、同時 \(Self.maxConcurrentBatches) 批，引擎 \(engine.id)"
            )
            do {
                // 併發跑批：收一批補一批，補的時候用**當下**的批量，
                // 所以前一批的結果會影響下一批送多少。每批各自落地，
                // 取消或中途失敗時已翻的都在。
                try await withThrowingTaskGroup(of: BatchOutcome.self) { group in
                    while true {
                        while inFlight < Self.maxConcurrentBatches, !pending.isEmpty {
                            let chunk = Array(pending.prefix(batchSize))
                            pending.removeFirst(chunk.count)
                            group.addTask {
                                let sent = Date()
                                do {
                                    let reply = try await runner.translate(chunk, targetLanguage: languageName)
                                    return BatchOutcome(items: chunk, reply: reply, failure: nil,
                                                        elapsed: Date().timeIntervalSince(sent))
                                } catch let error as AdviceError {
                                    return BatchOutcome(items: chunk, reply: nil, failure: .advice(error),
                                                        elapsed: Date().timeIntervalSince(sent))
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    return BatchOutcome(items: chunk, reply: nil,
                                                        failure: .other(error.localizedDescription),
                                                        elapsed: Date().timeIntervalSince(sent))
                                }
                            }
                            inFlight += 1
                        }
                        guard inFlight > 0, let outcome = try await group.next() else { break }
                        inFlight -= 1
                        try Task.checkCancellation()

                        if let failure = outcome.failure {
                            failures += 1
                            // 還有降的空間就砍半重送：引擎吃不下這個量是最常見的死法
                            if failures <= Self.maxBatchFailures, batchSize > Self.minBatchSize {
                                batchSize = max(Self.minBatchSize, batchSize / 2)
                                pending.insert(contentsOf: outcome.items, at: 0)
                                ChorusLog.app.notice("介面翻譯批次失敗，批量降到 \(batchSize) 重送：\(failure.message)")
                                continue
                            }
                            throw failure
                        }

                        let entries = Dictionary(
                            (outcome.reply?.translations ?? []).map { ($0.id, $0) },
                            uniquingKeysWith: { first, _ in first }
                        )
                        // 模型整條沒回的（多半是輸出被截斷）退回佇列再試，不是直接放棄
                        var missing: [UITranslationItem] = []
                        for item in outcome.items {
                            guard let entry = entries[item.id] else {
                                let tried = (attempts[item.id] ?? 0) + 1
                                attempts[item.id] = tried
                                if tried <= Self.maxItemAttempts {
                                    missing.append(item)
                                } else {
                                    skipped.insert(item.key)
                                    resolved += 1
                                }
                                continue
                            }
                            if let plural = item.plural {
                                if let forms = entry.plural,
                                   let other = forms["other"],
                                   forms.values.allSatisfy({ UITranslationValidator.isAcceptable(candidate: $0, source: plural["other"] ?? other) }) {
                                    plurals[item.key] = forms
                                    skipped.remove(item.key)
                                } else {
                                    skipped.insert(item.key)
                                }
                            } else if let text = entry.text,
                                      UITranslationValidator.isAcceptable(candidate: text, source: item.english ?? item.key) {
                                strings[item.key] = text
                                skipped.remove(item.key)
                            } else {
                                skipped.insert(item.key)
                            }
                            resolved += 1
                        }

                        if missing.isEmpty {
                            // 完整回來又夠快：這個引擎還吃得下，往上加量
                            if outcome.elapsed < Self.batchGrowSeconds, batchSize < Self.maxBatchSize {
                                batchSize = min(Self.maxBatchSize, batchSize + Self.batchGrowStep)
                            }
                        } else {
                            batchSize = max(Self.minBatchSize, batchSize / 2)
                            pending.insert(contentsOf: missing, at: 0)
                            ChorusLog.app.notice("介面翻譯回覆缺 \(missing.count) 條，批量降到 \(batchSize) 重送")
                        }

                        guard let self else { return }
                        try self.store.write(
                            language: language, strings: strings, plurals: plurals,
                            pluralValueTypes: source.pluralValueTypes,
                            manifest: .init(
                                language: language, engineID: engine.id,
                                model: self.settings.advisorModelIDs[engine.id],
                                date: Date(), sourceBuild: build,
                                translated: strings.count + plurals.count,
                                skipped: skipped.sorted()
                            )
                        )
                        self.phase = .running(done: resolved, total: total)
                        self.refreshInstalled()
                        ChorusLog.app.info(
                            "介面翻譯進度：\(language) \(resolved)/\(total)，批量 \(batchSize)，本批 \(Int(outcome.elapsed)) 秒，累計 \(Int(Date().timeIntervalSince(started))) 秒"
                        )
                    }
                }
                guard let self else { return }
                self.selection = .translated(language)
                self.phase = .finished(translated: strings.count + plurals.count, skipped: skipped.count)
                self.refreshInstalled()
                ChorusLog.app.notice("介面翻譯完成：\(language) \(strings.count + plurals.count) 條、跳過 \(skipped.count)，引擎 \(engine.id)，收斂批量 \(batchSize)，耗時 \(Int(Date().timeIntervalSince(started))) 秒")
            } catch is CancellationError {
                self?.phase = .idle
                self?.refreshInstalled()
                ChorusLog.app.notice("介面翻譯取消：\(language) 已完成 \(resolved)/\(total)")
            } catch let failure as BatchFailure {
                self?.phase = .failed(failure.message)
                self?.refreshInstalled()
                ChorusLog.app.error("介面翻譯失敗：\(language) 於 \(resolved)/\(total)，\(failure.message)")
            } catch {
                self?.phase = .failed(error.localizedDescription)
                self?.refreshInstalled()
                ChorusLog.app.error("介面翻譯失敗：\(language) 於 \(resolved)/\(total)，\(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 刪掉某個語言的翻譯檔；若它正被選用，選回內建。覆蓋還在記憶體裡，重啟才變。
    func remove(language: String) {
        try? store.remove(language: language)
        if settings.uiTranslationLanguage == language { selection = .system }
        phase = .idle
        // 清單／manifest 都在快取裡，刪完要當場更新，畫面那一列才會馬上消失
        refreshInstalled()
    }

    /// 重新啟動 App 套用語言：`open -n` 拉起新實例（連同啟動參數），自己退出。
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-n", Bundle.main.bundleURL.path]
        let passthrough = Array(CommandLine.arguments.dropFirst())
        if !passthrough.isEmpty { arguments += ["--args"] + passthrough }
        process.arguments = arguments
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - 內部

    private func missingItems(for language: String, source: UITranslationStore.BuiltinSource) -> [String] {
        let existing = store.existingTranslations(for: language)
        let skipped = Set(store.manifest(for: language)?.skipped ?? [])
        var missing: [String] = []
        for (key, english) in source.strings where existing.strings[key] == nil && !skipped.contains(key) {
            if english == key, !Self.containsCJK(key) { continue }
            missing.append(key)
        }
        for key in source.plurals.keys where existing.plurals[key] == nil && !skipped.contains(key) {
            missing.append(key)
        }
        return missing
    }

    nonisolated static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

/// 一批字串 → 引擎 → 回覆。抽成 protocol 讓測試不用 spawn 真的 CLI。
protocol UITranslationBatchRunning: Sendable {
    func translate(_ items: [UITranslationItem], targetLanguage: String) async throws -> UITranslationBatch
}

/// 正式版：與顧問共用 `CLIAdviceExecution`（重試、錯誤映射、環境白名單同一份）。
struct CLIUITranslationBatchRunner: UITranslationBatchRunning {
    let engine: KnownCLIEngine
    let executable: URL
    var model: String?
    /// 一批 40 條對慢的模型可能要兩三分鐘；比顧問寬。
    var timeout: Duration = .seconds(300)

    func translate(_ items: [UITranslationItem], targetLanguage: String) async throws -> UITranslationBatch {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-translate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let run = KnownCLIEngine.RunContext(
            sandbox: sandbox,
            schemaFile: CLIAdviceExecution.writeSchema(UITranslationPrompt.schemaJSON, into: sandbox),
            model: model,
            timeout: timeout
        )
        return try await CLIAdviceExecution.perform(
            engine: engine, executable: executable,
            basePrompt: UITranslationPrompt.prompt(items: items, targetLanguage: targetLanguage),
            run: run, as: UITranslationBatch.self
        )
    }
}
