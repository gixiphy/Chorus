import SwiftUI

/// 設定 → 一般 → 介面語言（DESIGN-20260902-user-cli-translation §4）。
/// 內建繁中／簡中／英文；其他語言讓使用者用本機 AI CLI 翻，翻好重啟生效。
/// 「用哪個語言」與「翻譯哪個語言」是兩件事：前者是一個 Picker（跟隨系統、三種內建、
/// 已翻好的），切走不會刪檔；後者在下面另一組控制項。
struct InterfaceLanguageSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var translator = appState.uiTranslator
        Section("介面語言") {
            Picker("介面語言", selection: Binding(
                get: { translator.selection },
                set: { translator.selection = $0 }
            )) {
                Text("跟隨系統").tag(UITranslator.Selection.system)
                ForEach(UITranslationStore.builtinLanguages, id: \.self) { code in
                    Text(UITranslator.displayName(for: code)).tag(UITranslator.Selection.builtin(code))
                }
                if !translator.installedLanguages.isEmpty {
                    Divider()
                    ForEach(translator.installedLanguages, id: \.self) { code in
                        Text(UITranslator.displayName(for: code)).tag(UITranslator.Selection.translated(code))
                    }
                }
            }
            .disabled(translator.isRunning)

            if translator.needsRelaunch {
                HStack {
                    Button("重新啟動以套用") { translator.relaunch() }
                    Text("選好的語言要重新啟動 Chorus 才會切換。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(translator.installedLanguages, id: \.self) { code in
                if let manifest = translator.manifest(for: code) {
                    installedRow(code: code, manifest: manifest, translator: translator)
                }
            }

            Text("Chorus 內建繁體中文、简体中文與英文，跟隨系統或在上面直接指定。其他語言可以交給本機的 AI CLI（設定 → AI 引擎裡選的那個）翻譯全部介面文字；翻好的檔只存在這台 Mac，隨時可以切回內建語言。這是機器翻譯，翻不好或還沒翻的字串會顯示英文。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("翻譯成", selection: $translator.targetLanguage) {
                ForEach(translator.candidateLanguages, id: \.self) { code in
                    Text(UITranslator.displayName(for: code)).tag(code)
                }
            }
            .disabled(translator.isRunning)

            if let engine = translator.activeEngine {
                LabeledContent("使用引擎") {
                    Text(engine.engine.displayName)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("沒有可用的 AI 引擎——先到「AI 引擎」分頁安裝或啟用一個 CLI。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch translator.phase {
            case let .running(done, total):
                HStack {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("翻譯中 \(done)／\(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("取消") { translator.cancel() }
                        .controlSize(.small)
                }
            case let .finished(translated, skipped):
                Label(
                    skipped == 0
                        ? "已翻譯 \(translated) 條。"
                        : "已翻譯 \(translated) 條，\(skipped) 條翻不好、退回英文。",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .idle:
                EmptyView()
            }

            HStack {
                Button(translator.installedLanguages.contains(translator.targetLanguage) ? "全部重翻" : "開始翻譯") {
                    translator.translate(onlyMissing: false)
                }
                .disabled(translator.isRunning || translator.activeEngine == nil)
                Text("約 \(UITranslator.builtinSource.strings.count) 條字串，分批送出，批量依引擎的速度與回覆完整度自動調整，通常幾分鐘內完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 一個已翻好語言的狀態列：條數、日期、引擎，加上補翻與移除。
    @ViewBuilder
    private func installedRow(code: String, manifest: UITranslationStore.Manifest, translator: UITranslator) -> some View {
        let missing = translator.missingCount(for: code)
        LabeledContent(UITranslator.displayName(for: code)) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(manifest.translated) 條 · \(manifest.engineID)")
                    Text(manifest.date, format: .dateTime.year().month().day())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if missing > 0 {
                    Button("補翻 \(missing) 條新字串") {
                        translator.targetLanguage = code
                        translator.translate(onlyMissing: true)
                    }
                    .controlSize(.small)
                    .disabled(translator.isRunning || translator.activeEngine == nil)
                }
                Button("移除", role: .destructive) { translator.remove(language: code) }
                    .controlSize(.small)
                    .disabled(translator.isRunning)
            }
        }
    }
}
