import ChorusCore
import Foundation
import ObjectiveC
import Testing
@testable import Chorus

@Suite("UI translation store")
struct UITranslationStoreTests {
    private func makeStore() -> UITranslationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-uitranslation-\(UUID().uuidString)", isDirectory: true)
        return UITranslationStore(directory: directory)
    }

    private let manifest = UITranslationStore.Manifest(
        language: "ja", engineID: "codex", model: nil, date: Date(),
        sourceBuild: "72", translated: 2, skipped: []
    )

    @Test("寫入後 Bundle(url:) 讀得到字串與複數形，即使使用者偏好裡沒有這個語言")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(
            language: "ja",
            strings: ["結束 Chorus": "Chorus を終了"],
            plurals: ["%lld 個動作": ["other": "%lld 件のアクション"]],
            pluralValueTypes: ["%lld 個動作": "lld"],
            manifest: manifest
        )
        let bundle = try #require(Bundle(url: store.bundleURL(for: "ja")))
        #expect(TranslatedBundle.resolve(key: "結束 Chorus", table: nil, overlay: bundle) == "Chorus を終了")
        // 沒翻的 key 回 nil，讓上層退回內建語言，而不是把 key 本身顯示出來
        #expect(TranslatedBundle.resolve(key: "不存在的 key", table: nil, overlay: bundle) == nil)
        #expect(TranslatedBundle.resolve(key: "結束 Chorus", table: nil, overlay: nil) == nil)

        // 複數形交給 Foundation：格式字串套上數字後是日文
        let format = try #require(TranslatedBundle.resolve(key: "%lld 個動作", table: nil, overlay: bundle))
        let rendered = String(format: format, locale: Locale(identifier: "ja"), 3)
        #expect(rendered == "3 件のアクション")

        #expect(store.manifest(for: "ja")?.engineID == "codex")
        #expect(store.installedLanguages() == ["ja"])
        let existing = store.existingTranslations(for: "ja")
        #expect(existing.strings["結束 Chorus"] == "Chorus を終了")
        #expect(existing.plurals["%lld 個動作"]?["other"] == "%lld 件のアクション")
    }

    @Test("換掉 class 後查表先走 overlay，查不到再退回原本的 bundle")
    func overrideMechanics() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(language: "ja", strings: ["結束 Chorus": "Chorus を終了"], plurals: [:],
                        pluralValueTypes: [:], manifest: manifest)
        // 用 test host 的 bundle 複本當「Bundle.main」替身，不動真的 Bundle.main
        let victim = try #require(Bundle(url: Bundle.main.bundleURL))
        TranslatedBundle.overlay = Bundle(url: store.bundleURL(for: "ja"))
        defer { TranslatedBundle.overlay = nil }
        object_setClass(victim, TranslatedBundle.self)
        #expect(victim.localizedString(forKey: "結束 Chorus", value: nil, table: nil) == "Chorus を終了")
        // Swift Foundation 的入口（String(localized:) 那條）也要接住
        #expect(victim.__localizedString(forKey: "結束 Chorus", value: nil, table: nil, localizations: ["en"]) == "Chorus を終了")
        #expect(victim.__localizedAttributedString(forKey: "結束 Chorus", value: nil, table: nil).string == "Chorus を終了")
        // overlay 沒有的 key 走原本邏輯：內建 en／zh-Hant 都沒有就回 key 本身
        #expect(victim.localizedString(forKey: "chorus.test.nokey", value: nil, table: nil) == "chorus.test.nokey")
        #expect(victim.__localizedString(forKey: "chorus.test.nokey", value: nil, table: nil, localizations: []) == "chorus.test.nokey")
    }

    @Test("移除後 bundle 與 manifest 都不在")
    func remove() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(language: "ko", strings: ["a": "b"], plurals: [:], pluralValueTypes: [:], manifest: manifest)
        try store.remove(language: "ko")
        #expect(store.manifest(for: "ko") == nil)
        #expect(store.installedLanguages().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.bundleURL(for: "ko").path))
    }

    @Test("候選清單不含內建語言——那三個在上面的介面語言選單裡")
    @MainActor
    func candidatesExcludeBuiltins() {
        let suite = "chorus.tests.candidates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let translator = UITranslator(
            store: UITranslationStore(directory: FileManager.default.temporaryDirectory),
            settings: settings,
            registry: AdviceEngineRegistry(settings: settings, scanOnInit: false),
            languageDefaults: defaults
        )
        for builtin in UITranslationStore.builtinLanguages {
            #expect(!translator.candidateLanguages.contains(builtin))
        }
        #expect(translator.candidateLanguages.contains("ja"))
    }

    @Test("內建英文來源從 test host（Chorus.app）的 en.lproj 讀得到字串與複數形")
    func builtinSource() {
        let source = UITranslationStore.builtinSource()
        #expect(source.strings.count > 300)
        #expect(source.strings["結束 Chorus"] == "Quit Chorus")
        #expect(source.plurals["%lld 個動作"]?["one"] == "%lld action")
        #expect(source.pluralValueTypes["%lld 個動作"] == "lld")
    }

    @Test("測試行程的預設目錄落在暫存目錄，不碰使用者的 Application Support")
    func testDirectoryIsIsolated() {
        let url = UITranslationStore.defaultDirectory(
            instance: InstanceConfig(arguments: []),
            environment: ["XCTestConfigurationFilePath": "/x"]
        )
        #expect(url.path.contains("chorus-tests"))
        let real = UITranslationStore.defaultDirectory(instance: InstanceConfig(arguments: ["--instance", "e2e"]), environment: [:])
        #expect(real.path.hasSuffix("Chorus/UITranslations-e2e"))
    }
}

@Suite("UI translator")
@MainActor
struct UITranslatorTests {
    /// 假引擎：把英文倒過來當譯文，複數只回 other；第 2 條故意漏掉 specifier。
    struct FakeRunner: UITranslationBatchRunning {
        func translate(_ items: [UITranslationItem], targetLanguage: String) async throws -> UITranslationBatch {
            UITranslationBatch(translations: items.map { item in
                if let plural = item.plural {
                    return .init(id: item.id, plural: ["other": "JA " + (plural["other"] ?? "")])
                }
                return .init(id: item.id, text: "JA " + (item.english ?? item.key))
            })
        }
    }

    @Test("系統語言建議：跳過內建語言、正規化 region 與中文 script")
    func suggestedLanguage() {
        #expect(UITranslator.suggestedLanguage(preferred: ["zh-Hant-TW", "en-US"]) == nil)
        // 簡中自 1.4.0 起是內建語言，不該再被建議去自翻
        #expect(UITranslator.suggestedLanguage(preferred: ["zh-Hans-CN", "en-US"]) == nil)
        #expect(UITranslationStore.builtinLanguages.contains("zh-Hans"))
        #expect(UITranslator.suggestedLanguage(preferred: ["en-US", "ja-JP"]) == "ja")
        #expect(UITranslator.normalize("zh-Hans-CN") == "zh-Hans")
        #expect(UITranslator.normalize("zh-CN") == "zh-Hans")
        #expect(UITranslator.normalize("pt-BR") == "pt-BR")
        #expect(UITranslator.normalize("de-AT") == "de")
    }

    @Test("翻譯流程：分批、驗證、寫檔、記設定；specifier 壞掉的退回英文並記進 skipped")
    func translateEndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-uitranslator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UITranslationStore(directory: directory)
        let suite = "chorus.tests.uitranslator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let registry = AdviceEngineRegistry(settings: settings, scanOnInit: false)
        registry.injectDetected([.init(
            engine: KnownCLIEngine.catalog.first { $0.id == "codex" }!,
            url: URL(fileURLWithPath: "/usr/bin/true"), version: nil
        )])
        let translator = UITranslator(
            store: store, settings: settings, registry: registry, languageDefaults: defaults
        )
        translator.batchRunner = FakeRunner()
        translator.targetLanguage = "ja"

        translator.translate(onlyMissing: false)
        // 等背景 Task 收工
        for _ in 0..<200 where translator.isRunning {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case let .finished(translated, _) = translator.phase else {
            Issue.record("phase=\(translator.phase)")
            return
        }
        let source = UITranslationStore.builtinSource()
        #expect(translated > 0)
        #expect(settings.uiTranslationLanguage == "ja")
        let written = store.existingTranslations(for: "ja")
        #expect(written.strings["結束 Chorus"] == "JA Quit Chorus")
        // 沒有中日韓文字、英文等於 key 的直接照抄，不經模型
        #expect(written.strings["%@ — %@"] == "%@ — %@")
        #expect(written.plurals["%lld 個動作"]?["other"] == "JA %lld actions")
        #expect(store.manifest(for: "ja")?.translated == translated)
        #expect(translated == source.strings.count + source.plurals.count - (store.manifest(for: "ja")?.skipped.count ?? 0))
        // 全部翻完就沒有缺的
        #expect(translator.missingCount(for: "ja") == 0)
        #expect(translator.installedLanguages == ["ja"])
        #expect(translator.needsRelaunch)
        #expect(translator.selection == .translated("ja"))
        // 沒翻到的字串要落在英文——選定自翻語言時把 AppleLanguages 釘成 en
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
        // 選回跟隨系統：檔還在、設定清掉；沒有覆蓋在跑就不用重啟
        translator.selection = .system
        #expect(settings.uiTranslationLanguage == nil)
        // 拿掉我們寫的那筆就好——讀 defaults 會落到全域偏好（＝跟隨系統），所以查 domain
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        #expect(translator.installedLanguages == ["ja"])
        #expect(!translator.needsRelaunch)
        // 移除選用中的語言會一起選回跟隨系統
        translator.selection = .translated("ja")
        translator.remove(language: "ja")
        #expect(translator.installedLanguages.isEmpty)
        #expect(translator.selection == .system)
    }

    @Test("選內建語言：寫 AppleLanguages、清掉自翻的選擇，與執行中的不同就要重啟")
    @MainActor
    func builtinSelection() {
        let suite = "chorus.tests.builtinlang.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let translator = UITranslator(
            store: UITranslationStore(directory: FileManager.default.temporaryDirectory),
            settings: settings,
            registry: AdviceEngineRegistry(settings: settings, scanOnInit: false),
            languageDefaults: defaults
        )
        UITranslator.runningSelection = .system
        defer { UITranslator.runningSelection = .system }

        #expect(translator.selection == .system)
        #expect(!translator.needsRelaunch)

        translator.selection = .builtin("zh-Hans")
        #expect(settings.builtinLanguage == "zh-Hans")
        #expect(settings.uiTranslationLanguage == nil)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        // 這個行程還在跑跟隨系統的語言：要重啟才會換
        #expect(translator.needsRelaunch)

        // 已經是這個語言在跑就不提示
        UITranslator.runningSelection = .builtin("zh-Hans")
        #expect(!translator.needsRelaunch)

        translator.selection = .system
        #expect(settings.builtinLanguage == nil)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        #expect(translator.needsRelaunch)
    }
}
