import ChorusCore
import SwiftUI

/// 光環境顧問的建議清單：sceneSummary、可勾選的建議項
/// （offset／maxLux／minBrightness）、純顯示的 warnings、套用與還原。
/// 內嵌於裝置配置視窗的「建議」區塊，不自帶尺寸——由外層決定寬高。
struct AdvicePanelView: View {
    @Environment(AppState.self) private var appState
    let result: AdviceResult
    /// 關閉建議區（套用後與按下關閉時呼叫）。
    let onClose: () -> Void

    @State private var selectedOffsetIDs: Set<String> = []
    @State private var applyMaxLux = true
    @State private var applyMinBrightness = true

    private var advice: LightingAdvice { result.advice }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !advice.sceneSummary.isEmpty {
                        Text(advice.sceneSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasSuggestions {
                        suggestionList
                    } else {
                        Text("模型沒有給出可套用的調整建議")
                            .foregroundStyle(.secondary)
                    }
                    if !advice.warnings.isEmpty {
                        warningList
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        // 換一批建議（重新分析或改看歷史）時重設勾選，避免沿用上一批的選擇。
        .onChange(of: result.id, initial: true) {
            selectedOffsetIDs = Set(advice.offsets.map(\.displayID))
            applyMaxLux = true
            applyMinBrightness = true
        }
    }

    private var hasSuggestions: Bool {
        !advice.offsets.isEmpty || advice.maxLux != nil || advice.minBrightness != nil
    }

    private var header: some View {
        HStack {
            Label("光環境分析建議", systemImage: "lightbulb.max")
                .font(.headline)
            Spacer()
            Text(result.date, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            if result.fromHistory {
                Text("歷史")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(advice.offsets, id: \.displayID) { suggestion in
                Toggle(isOn: binding(for: suggestion.displayID)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(displayName(suggestion.displayID))
                                .fontWeight(.medium)
                            Text("\(formatOffset(currentOffset(suggestion.displayID))) → \(formatOffset(suggestion.offset))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(suggestion.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let maxLux = advice.maxLux {
                Toggle(isOn: $applyMaxLux) {
                    HStack(spacing: 6) {
                        Text("全亮環境光").fontWeight(.medium)
                        Text("\(Int(result.context.curve.maxLux)) lx → \(Int(maxLux)) lx")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let minBrightness = advice.minBrightness {
                Toggle(isOn: $applyMinBrightness) {
                    HStack(spacing: 6) {
                        Text("最暗亮度").fontWeight(.medium)
                        Text("\(percent(result.context.curve.minBrightness)) → \(percent(minBrightness))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var warningList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(advice.warnings, id: \.self) { warning in
                Label {
                    Text(warning)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if appState.advisor.canUndo {
                Button("還原上次套用") {
                    appState.advisor.undoLastApply()
                }
                .controlSize(.small)
                .help("還原本機 offset 與曲線參數；遠端裝置的差異值無法還原")
            }
            Spacer()
            Button("關閉") { onClose() }
                .controlSize(.small)
            Button("套用勾選項") {
                appState.advisor.apply(
                    advice,
                    selectedOffsetIDs: selectedOffsetIDs,
                    applyMaxLux: applyMaxLux && advice.maxLux != nil,
                    applyMinBrightness: applyMinBrightness && advice.minBrightness != nil
                )
                onClose()
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(!anySelected)
        }
        .padding(10)
    }

    private var anySelected: Bool {
        !selectedOffsetIDs.isEmpty
            || (applyMaxLux && advice.maxLux != nil)
            || (applyMinBrightness && advice.minBrightness != nil)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedOffsetIDs.contains(id) },
            set: { on in
                if on { selectedOffsetIDs.insert(id) } else { selectedOffsetIDs.remove(id) }
            }
        )
    }

    private func displayName(_ id: String) -> String {
        result.context.displays.first { $0.id == id }?.name ?? id
    }

    private func currentOffset(_ id: String) -> Double {
        result.context.displays.first { $0.id == id }?.currentOffset ?? 0
    }

    private func formatOffset(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
