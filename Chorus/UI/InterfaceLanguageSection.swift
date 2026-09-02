import SwiftUI

/// 設定 → 一般 → 介面語言（DESIGN-20260902-user-cli-translation §4）。
/// 內建中英；其他語言讓使用者用本機 AI CLI 翻，翻好重啟生效。
struct InterfaceLanguageSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var translator = appState.uiTranslator
        Section("介面語言") {
            Text("Chorus 內建繁體中文與英文。其他語言可以交給本機的 AI CLI（設定 → 分析引擎裡選的那個）翻譯全部介面文字；翻好的檔只存在這台 Mac，重新啟動後生效。這是機器翻譯，翻不好的字串會退回英文。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let installed = translator.installed {
                LabeledContent("已安裝的翻譯") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(UITranslator.displayName(for: installed.language)) · \(installed.translated) 條 · \(installed.engineID)")
                        Text(installed.date, format: .dateTime.year().month().day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if translator.needsRelaunch {
                        Button("重新啟動以套用") { translator.relaunch() }
                    }
                    let missing = translator.missingCount
                    if missing > 0 {
                        Button("補翻 \(missing) 條新字串") {
                            translator.targetLanguage = installed.language
                            translator.translate(onlyMissing: true)
                        }
                        .disabled(translator.isRunning || translator.activeEngine == nil)
                    }
                    Button("移除翻譯", role: .destructive) { translator.removeInstalled() }
                        .disabled(translator.isRunning)
                }
                if translator.needsRelaunch {
                    Text("翻譯已就位，但目前執行中的還是舊語言；重新啟動 Chorus 才會切換。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                Label("沒有可用的分析引擎——先到「分析引擎」分頁安裝或啟用一個 CLI。", systemImage: "exclamationmark.triangle")
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
                Button(translator.installed?.language == translator.targetLanguage ? "全部重翻" : "開始翻譯") {
                    translator.translate(onlyMissing: false)
                }
                .disabled(translator.isRunning || translator.activeEngine == nil)
                Text("約 \(UITranslationStore.builtinSource().strings.count) 條字串，40 條一批送出，通常幾分鐘內完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
