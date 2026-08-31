import AppKit
import ChorusCore
import SwiftUI

/// AI 調音建議區（DESIGN-20260831-audio-tuning-advisor §1.4）。
/// 裝置展開面板與 App 音訊處理視窗共用；引擎與光環境顧問同一組。
/// 建議**不自動套用**——結果卡列出思路與理由，使用者按「套用」。
struct AudioAdviceSection: View {
    @Environment(AppState.self) private var appState
    let target: AudioTuningTarget

    /// 需求描述（例：「玩 FPS 想聽清腳步」）。與照片標註同一個角色：
    /// 補模型看不到的使用情境。
    @State private var request = ""

    private var tuner: AudioTuningAdvisor { appState.audioTuner }
    /// 只顯示屬於本區目標的結果——兩個掛載點共用同一個 advisor。
    private var result: AudioTuningResult? {
        tuner.result?.target == target ? tuner.result : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI 調音建議").font(.callout)
                Spacer()
                if tuner.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("取消") { tuner.cancelAnalysis() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            HStack(spacing: 6) {
                TextField("需求描述（例：玩 FPS 想聽清腳步；可留空）", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("取得建議") { tuner.analyze(target: target, request: request) }
                    .controlSize(.small)
                    .disabled(tuner.isAnalyzing || !tuner.canAnalyze)
            }
            if !tuner.canAnalyze {
                Text("未偵測到分析引擎——與光環境顧問共用同一組（設定 → 分析引擎）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let message = tuner.lastErrorMessage {
                HStack(spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    errorAssistButton
                }
            }
            if let result {
                resultCard(result)
            } else if tuner.canUndo {
                Button("還原上次套用") { tuner.undoLastApply() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    // MARK: - 結果卡

    @ViewBuilder
    private func resultCard(_ result: AudioTuningResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.advice.summary)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let eq = result.advice.eq {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EQ：\(bandSummary(eq, frequencies: result.context.bandFrequencies))")
                        .font(.caption)
                        .monospacedDigit()
                    Text(eq.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(result.advice.effects, id: \.componentKey) { effect in
                VStack(alignment: .leading, spacing: 2) {
                    Text("效果：\(effect.name)").font(.caption)
                    Text(effect.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(result.advice.warnings, id: \.self) { warning in
                Text("⚠︎ \(warning)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if result.advice.eq != nil || !result.advice.effects.isEmpty {
                    Button("套用") { tuner.apply(result) }
                        .controlSize(.small)
                }
                if tuner.canUndo {
                    Button("還原上次套用") { tuner.undoLastApply() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Button("關閉") { tuner.result = nil }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 非零段的摘要（「125 Hz +3.0、2 k −2.0」）；全零不會出現在這裡
    /// （sanitize 已把全零 EQ 收成 nil）。
    private func bandSummary(_ eq: AudioTuningAdvice.EQAdvice, frequencies: [Double]) -> String {
        zip(frequencies, eq.bandsGainDB)
            .filter { $0.1 != 0 }
            .map { "\(EQBandSliders.frequencyLabel($0.0)) \(String(format: "%+.1f", $0.1))" }
            .joined(separator: "、")
    }

    /// 錯誤訊息旁的協助按鈕（與光環境顧問同一套語彙）。
    @ViewBuilder
    private var errorAssistButton: some View {
        switch tuner.lastErrorAssist {
        case let .copyLoginCommand(command):
            Button("複製登入指令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .controlSize(.small)
            .help("複製「\(command)」，到終端機貼上執行完成登入後再重試")
        case .openEngineSettings:
            SettingsLink { Text("開啟設定") }
                .controlSize(.small)
                .help("設定 → 分析引擎：確認 CLI 已安裝或指定路徑")
        case nil:
            EmptyView()
        }
    }
}
