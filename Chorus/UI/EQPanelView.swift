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
    /// A/B 試聽切到「原聲」：暫時不送出等化，但**不動設定**。
    /// 這不是「關掉」——關掉會把整組 preset 一起丟了。
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
                Text("試聽")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("試聽", selection: Binding(
                    get: { bypassed ? Comparison.raw : .equalized },
                    set: {
                        bypassed = ($0 == .raw)
                        apply(settings) // isEnabled 不變，只有送不送出去變了
                    }
                )) {
                    Text("原聲").tag(Comparison.raw)
                    Text("等化後").tag(Comparison.equalized)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("左右切著聽，判斷這組等化有沒有讓聲音變好。切到「原聲」只是暫時不送出等化，設定不會被清掉。")
            }
        }
    }

    /// A/B 試聽的兩端。用「聽到的是什麼」當標籤而不是「旁通／bypass」——
    /// 後者是器材術語，而且做成會翻面的按鈕時，沒人分得出標題寫的是
    /// 「現在的狀態」還是「按下去會變成的狀態」。分段控制沒有這個歧義：
    /// 亮起來的那一段就是耳朵聽到的那一份。
    private enum Comparison: Hashable {
        /// 不套等化——原本的聲音。
        case raw
        /// 套上目前這組等化。
        case equalized
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
                // 風格 preset：口味，不是校正——與 AutoEq 是不同責任。
                // 套用後照樣可以逐段微調（會走同一條手動編輯路徑）
                Menu("風格") {
                    ForEach(EQGenrePreset.all) { preset in
                        Button(preset.name) { apply(preset.settings()) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .help("約兩打常見風格曲線，一鍵套用；套用後仍可逐段微調")
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
        EQBandSliders(settings: settings) { value, index in
            setGain(value, at: index)
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

    /// 存設定並推到引擎。試聽切到「原聲」時存的 `isEnabled` 不變，只有推出去
    /// 的那份被關掉——A/B 比較不該有「忘了打開」的風險。
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

/// 10 段滑桿（裝置面板與 App 層面板共用——機制只寫一份）。
/// 呼叫端負責「改了增益之後要做什麼」（preamp 政策、sourceName 標註）。
struct EQBandSliders: View {
    let settings: EQSettings
    let onGainChange: (Double, Int) -> Void

    var body: some View {
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
                            set: { onGainChange($0, index) }
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

    static func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1000
            ? String(format: "%.4g k", frequency / 1000)
            : String(format: "%.0f", frequency)
    }
}

/// 每輸出裝置的左右平衡列（B6 缺口批）。
///
/// 兩後端：裝置有原生平衡（HAL 的 vmbc 或 stereo pan——內建喇叭、藍牙
/// 耳機、虛擬裝置都有）就直接寫 HAL，隨時生效、不需要任何權限；
/// 沒有的（DP/HDMI 直接輸出）走裝置級 tap 鏈，與等化同一組成立條件。
struct DeviceBalanceRow: View {
    @Environment(AppState.self) private var appState
    let device: AudioDeviceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("左右平衡").font(.callout)
                Spacer()
                if device.balance != 0 {
                    Button("置中") { appState.audioManager.setBalance(0, for: device) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            HStack(spacing: 8) {
                Text("左").font(.caption2).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { device.balance },
                        set: { appState.audioManager.setBalance($0, for: device) }
                    ),
                    in: -1...1
                )
                Text("右").font(.caption2).foregroundStyle(.secondary)
                Text(balanceLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            if let reason = appState.audioManager.balanceUnavailableReason(for: device) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isMirrorModeVirtual, device.balance != 0 {
                // driver 在 DDC 鏡射模式下樣本原樣通過（不做數位處理），
                // L/R 因子會被略過——誠實說明而不是裝作有效
                Text("DDC 鏡射模式下音訊原樣通過，平衡暫不生效")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var balanceLabel: String {
        if device.balance == 0 { return "置中" }
        let percent = Int((abs(device.balance) * 100).rounded())
        return device.balance < 0 ? "左 \(percent)%" : "右 \(percent)%"
    }

    private var isMirrorModeVirtual: Bool {
        device.uid == VirtualAudioDriverController.deviceUID
            && appState.virtualDriver.mirrorMode == true
    }
}
