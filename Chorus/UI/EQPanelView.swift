import ChorusCore
import SwiftUI

/// 每輸出裝置的等化面板（B6-5）。
///
/// 三條路徑：手動 10 段、AutoEq 耳機型號、貼上校正檔。
/// 一律**預設關閉**——EQ 開著代表該裝置的所有音訊要繞道 Chorus。
struct EQPanelView: View {
    @Environment(AppState.self) private var appState
    let device: AudioDeviceModel

    @State private var query = ""
    @State private var pastedText = ""
    @State private var showsPasteField = false
    /// A/B bypass：暫時停用 EQ 而**不動設定**。聽差異用的，
    /// 不是「關掉」——關掉會把 preset 一起丟了。
    @State private var bypassed = false

    private var settings: EQSettings {
        appState.audioManager.eqSettings(for: device)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if settings.isEnabled {
                if let reason = appState.audioManager.eqUnavailableReason(for: device) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                sourceRow
                bandSliders
                footer
            }
        }
    }

    // MARK: - 標頭

    private var header: some View {
        HStack(spacing: 8) {
            Toggle("等化器", isOn: Binding(
                get: { settings.isEnabled },
                set: { enable($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
            if settings.isEnabled {
                Button(bypassed ? "已旁通（A）" : "旁通比較（B）") {
                    bypassed.toggle()
                    apply(settings) // isEnabled 不變，只有送不送出去變了
                }
                .controlSize(.small)
                .help("暫時停用 EQ 以聽出差異。設定不會被清掉。")
            }
        }
    }

    // MARK: - 來源

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = settings.sourceName {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TextField("搜尋耳機型號（AutoEq）", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("手動 10 段") {
                    apply(EQSettings.tenBandDefault())
                }
                .controlSize(.small)
                Button(showsPasteField ? "收起" : "貼上校正檔") {
                    showsPasteField.toggle()
                }
                .controlSize(.small)
                .help("任何型號都適用，而且離線可用——內建清單找不到時走這條")
            }

            if !query.isEmpty {
                let matches = appState.autoEq.search(query).prefix(6)
                if matches.isEmpty {
                    Text("內建清單裡沒有這個型號——可到 AutoEq 的 results 目錄複製該型號的 ParametricEQ 內容，用「貼上校正檔」套用。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(matches)) { entry in
                        Button {
                            query = ""
                            Task {
                                if let downloaded = await appState.autoEq.settings(for: entry) {
                                    apply(downloaded)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "headphones")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                                Text(entry.name).font(.caption)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if appState.autoEq.isDownloading {
                ProgressView().controlSize(.small)
            }
            if let error = appState.autoEq.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsPasteField {
                TextEditor(text: $pastedText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 90)
                    .border(.quaternary)
                HStack {
                    Button("套用貼上的內容") {
                        if let parsed = appState.autoEq.settings(fromPastedText: pastedText) {
                            apply(parsed)
                            pastedText = ""
                            showsPasteField = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("格式：AutoEq 的 ParametricEQ.txt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 各段

    private var bandSliders: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(settings.bands.enumerated()), id: \.element.id) { index, band in
                HStack(spacing: 6) {
                    Text(Self.frequencyLabel(band.frequency))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { band.gainDB },
                            set: { setGain($0, at: index) }
                        ),
                        in: EQBand.gainRange
                    )
                    .controlSize(.mini)
                    .disabled(!band.isEnabled)
                    Text(String(format: "%+.1f", band.gainDB))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(band.isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(String(format: "前置增益 %.1f dB", settings.effectivePreampDB))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部歸零") { apply(EQSettings()) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(settings.usesAutomaticPreamp
                ? "前置增益由最大的正增益自動算出，用來抵銷提升、避免削波。"
                : "前置增益取自校正檔——AutoEq 已依整條曲線的峰值算好。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("等化資料來源：AutoEq（MIT）· jaakkopasanen/AutoEq")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 動作

    private func enable(_ enabled: Bool) {
        var updated = settings
        // 從未設定過就直接給 10 段——開了開關卻是一張白紙沒有用處
        if enabled, updated.bands.isEmpty {
            updated = EQSettings.tenBandDefault()
        }
        updated.isEnabled = enabled
        bypassed = false
        apply(updated)
    }

    private func setGain(_ value: Double, at index: Int) {
        var updated = settings
        guard updated.bands.indices.contains(index) else { return }
        updated.bands[index].gainDB = value
        // 手動一改就換回自動 preamp：校正檔的 preamp 是為它自己那組曲線
        // 算的，動過之後那個數字就不再對應畫面上的東西了
        updated.usesAutomaticPreamp = true
        if updated.sourceName != nil, updated.sourceName != "手動 10 段" {
            updated.sourceName = (updated.sourceName ?? "") + "（已手動調整）"
        }
        apply(updated)
    }

    /// 存設定並推到引擎。旁通時存的 `isEnabled` 不變，只有推出去的那份
    /// 被關掉——A/B 比較不該有「忘了打開」的風險。
    private func apply(_ updated: EQSettings) {
        var stored = updated
        appState.audioManager.setEQSettings(stored, for: device)
        if bypassed {
            stored.isEnabled = false
            appState.audioManager.setEQOverride(stored, for: device)
        } else {
            appState.audioManager.setEQOverride(nil, for: device)
        }
    }

    private static func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1000
            ? String(format: "%.4g k", frequency / 1000)
            : String(format: "%.0f", frequency)
    }
}
