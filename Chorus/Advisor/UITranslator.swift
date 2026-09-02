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
    /// 目標語言（BCP 47：ja、ko、zh-Hans、pt-BR…）。預設系統語言裡第一個非內建的。
    var targetLanguage: String

    @ObservationIgnored private let store: UITranslationStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let registry: AdviceEngineRegistry
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 測試用：換掉真的 CLI。
    @ObservationIgnored var batchRunner: (any UITranslationBatchRunning)?

    static let batchSize = 40

    init(store: UITranslationStore, settings: SettingsStore, registry: AdviceEngineRegistry) {
        self.store = store
        self.settings = settings
        self.registry = registry
        targetLanguage = settings.uiTranslationLanguage
            ?? Self.suggestedLanguage(preferred: Locale.preferredLanguages)
            ?? "ja"
    }

    // MARK: - 狀態

    /// 使用者選定要用的介面語言：nil＝內建（跟隨系統的繁中／英文）。
    /// 選回內建**不會**刪翻譯檔，之後還能再切回來。
    var selectedLanguage: String? {
        get { settings.uiTranslationLanguage }
        set { settings.uiTranslationLanguage = newValue }
    }

    /// 已翻好、檔還在的語言。
    var installedLanguages: [String] { store.installedLanguages() }

    func manifest(for language: String) -> UITranslationStore.Manifest? { store.manifest(for: language) }

    /// 選定的與正在執行的不同：要重啟才會生效（含選回內建）。
    var needsRelaunch: Bool {
        let selected = selectedLanguage.flatMap { store.manifest(for: $0) != nil ? $0 : nil }
        return TranslatedBundle.activeLanguage != selected
    }

    /// 某個已翻語言裡，內建字串尚未翻的條數（升版後會長出來）。
    func missingCount(for language: String) -> Int {
        missingItems(for: language, source: UITranslationStore.builtinSource()).count
    }

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
        for code in ["ja", "ko", "zh-Hans", "de", "fr", "es", "pt-BR", "it", "ru", "vi", "th", "id", "nl", "pl", "tr", "uk"]
        where !list.contains(code) {
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

    /// 翻譯（或補翻）目標語言。`onlyMissing` 為 true 時保留既有譯文、只送缺的。
    func translate(onlyMissing: Bool) {
        guard !isRunning else { return }
        guard let engine = registry.activeEngine else {
            phase = .failed(String(localized: "未找到可用的 AI 引擎（設定 → AI 引擎）"))
            return
        }
        let language = targetLanguage
        let source = UITranslationStore.builtinSource()
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
            var done = 0
            let batches = stride(from: 0, to: items.count, by: Self.batchSize).map {
                Array(items[$0..<min($0 + Self.batchSize, items.count)])
            }
            do {
                for batch in batches {
                    try Task.checkCancellation()
                    let reply = try await runner.translate(batch, targetLanguage: languageName)
                    let entries = Dictionary(reply.translations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for item in batch {
                        if let plural = item.plural {
                            if let forms = entries[item.id]?.plural,
                               let other = forms["other"],
                               forms.values.allSatisfy({ UITranslationValidator.isAcceptable(candidate: $0, source: plural["other"] ?? other) }) {
                                plurals[item.key] = forms
                                skipped.remove(item.key)
                            } else {
                                skipped.insert(item.key)
                            }
                        } else if let text = entries[item.id]?.text,
                                  UITranslationValidator.isAcceptable(candidate: text, source: item.english ?? item.key) {
                            strings[item.key] = text
                            skipped.remove(item.key)
                        } else {
                            skipped.insert(item.key)
                        }
                    }
                    done += batch.count
                    guard let self else { return }
                    // 每批落地：取消或下一批失敗時已翻的都在
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
                    self.phase = .running(done: done, total: total)
                }
                guard let self else { return }
                self.settings.uiTranslationLanguage = language
                self.phase = .finished(translated: strings.count + plurals.count, skipped: skipped.count)
                ChorusLog.app.notice("介面翻譯完成：\(language) \(strings.count + plurals.count) 條、跳過 \(skipped.count)，引擎 \(engine.id)")
            } catch is CancellationError {
                self?.phase = .idle
                ChorusLog.app.notice("介面翻譯取消：\(language) 已完成 \(done)/\(total)")
            } catch let error as AdviceError {
                self?.phase = .failed(error.userMessage)
                ChorusLog.app.error("介面翻譯失敗：\(language) 於 \(done)/\(total)，\(error.userMessage)")
            } catch {
                self?.phase = .failed(error.localizedDescription)
                ChorusLog.app.error("介面翻譯失敗：\(language) 於 \(done)/\(total)，\(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 刪掉某個語言的翻譯檔；若它正被選用，選回內建。覆蓋還在記憶體裡，重啟才變。
    func remove(language: String) {
        try? store.remove(language: language)
        if settings.uiTranslationLanguage == language { settings.uiTranslationLanguage = nil }
        phase = .idle
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
