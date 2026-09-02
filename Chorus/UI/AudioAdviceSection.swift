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
    /// 注意事項預設收起：一次五、六條警告會把「建議是什麼」擠出視野，
    /// 但它們又不能不給——摺疊起來並在標題掛上條數是兩者的折衷。
    @State private var showsWarnings = false

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
        // 換一份建議＝換一組注意事項，收合狀態不該跨份沿用
        .onChange(of: result?.id) { _, _ in showsWarnings = false }
    }

    // MARK: - 結果卡

    /// 動作列放在卡片**頂端**：建議正文長度不可預期，把「套用」擺在
    /// 最下面等於要求使用者先捲到底才找得到唯一要按的按鈕。
    @ViewBuilder
    private func resultCard(_ result: AudioTuningResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow(result)
            Divider()
            Text(result.advice.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let eq = result.advice.eq {
                Divider()
                eqComparison(eq, context: result.context)
            }
            if !result.advice.effects.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("效果鏈").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.advice.effects, id: \.componentKey) { effect in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(effect.name).font(.caption).monospaced()
                            Text(effect.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !result.advice.warnings.isEmpty {
                Divider()
                warnings(result.advice.warnings)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func actionRow(_ result: AudioTuningResult) -> some View {
        HStack(spacing: 10) {
            Text("建議").font(.callout)
            Text(result.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if result.advice.eq != nil || !result.advice.effects.isEmpty {
                Button("套用") { tuner.apply(result) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if tuner.canUndo {
                Button("還原上次套用") { tuner.undoLastApply() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Button(String(localized: "close", defaultValue: "關閉")) { tuner.result = nil }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    // MARK: - EQ：現在 → 建議

    /// 逐段對照而不是只印一串建議值：套用會**整組換掉**這 10 段，
    /// 使用者要判斷的是「哪幾段會動、動多少」，不是那串數字本身。
    @ViewBuilder
    private func eqComparison(_ eq: AudioTuningAdvice.EQAdvice, context: AudioTuningContext) -> some View {
        let frequencies = context.bandFrequencies
        let current = tuner.currentEQGains(for: target, bandCount: frequencies.count)
        let rows = changedRows(eq, frequencies: frequencies, current: current)
        let unchanged = min(frequencies.count, eq.bandsGainDB.count) - rows.count

        VStack(alignment: .leading, spacing: 4) {
            Text("等化器").font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("與目前這組等化相同——套用不會改變任何一段。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 2) {
                    ForEach(rows, id: \.index) { row in
                        GridRow {
                            Text(EQBandSliders.frequencyLabel(row.frequency))
                                .foregroundStyle(.secondary)
                            Text(row.current.map { String(format: "%+.1f", $0) } ?? "—")
                                .foregroundStyle(.tertiary)
                            Image(systemName: "arrow.right")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%+.1f", row.suggested))
                            Text("dB").foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.caption)
                .monospacedDigit()
                if current == nil {
                    Text("目前沒有可逐段對照的等化——套用會建立一組 10 段。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if unchanged > 0 {
                    Text("其餘 \(unchanged) 段不變")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(eq.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct BandDelta {
        let index: Int
        let frequency: Double
        /// nil＝目前沒有這一段的現值可比（沒設過 EQ 或段數對不上）。
        let current: Double?
        let suggested: Double
    }

    /// 會**動到**的段。沒有現值可比時，退回「建議不為 0 的段」——
    /// 這時 0 dB 就是不動它。
    private func changedRows(
        _ eq: AudioTuningAdvice.EQAdvice, frequencies: [Double], current: [Double]?
    ) -> [BandDelta] {
        zip(frequencies, eq.bandsGainDB).enumerated().compactMap { index, pair in
            let (frequency, suggested) = pair
            guard let currentGain = current?[index] else {
                return suggested == 0
                    ? nil
                    : BandDelta(index: index, frequency: frequency, current: nil, suggested: suggested)
            }
            // 0.05 dB 以下的差在滑桿上顯示成同一個數字，別列成「有變」
            guard abs(currentGain - suggested) >= 0.05 else { return nil }
            return BandDelta(
                index: index, frequency: frequency, current: currentGain, suggested: suggested
            )
        }
    }

    // MARK: - 注意事項

    private func warnings(_ items: [String]) -> some View {
        DisclosureGroup(isExpanded: $showsWarnings) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { warning in
                    Text("・\(warning)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 4)
        } label: {
            // DisclosureGroup 的 label 預設不吃點擊——只有那個小三角是熱區。
            // 整行都可按才符合這張卡其他地方的手感。
            Text("注意事項（\(items.count)）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showsWarnings.toggle() } }
        }
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
