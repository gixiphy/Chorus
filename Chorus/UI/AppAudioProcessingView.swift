import ChorusCore
import SwiftUI

/// App 層的等化與效果面板（AU-3；DESIGN §1.2 的 per-app 擴充）。
/// 從選單列 App 列右鍵「等化與效果…」開，一個 App 一個視窗。
///
/// 與裝置面板的差異是**責任層**：這裡的 EQ／效果只套在這個 App 的
/// 音訊上（render 順序在裝置層之前），與裝置層是不同責任的兩次。
/// AutoEq 不在這裡——耳機校正是裝置的事。
struct AppAudioProcessingView: View {
    @Environment(AppState.self) private var appState
    let bundleID: String

    private var setting: AppAudioSetting {
        appState.tapEngine.setting(for: bundleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            eqSection
            Divider()
            EffectChainView(target: .app(bundleID))
            if let reason = engineReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = appState.tapEngine.registry.icon(bundleID: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(appState.tapEngine.registry.displayName(bundleID: bundleID))
                    .font(.headline)
                Text(bundleID).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - App 層 EQ

    private var eq: EQSettings {
        setting.eq ?? EQSettings()
    }

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("等化器（只套這個 App）", isOn: Binding(
                    get: { eq.isEnabled },
                    set: { enable($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                if eq.isEnabled {
                    Menu("風格") {
                        ForEach(EQGenrePreset.all) { preset in
                            Button(preset.name) { apply(preset.settings()) }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if eq.isEnabled {
                if let source = eq.sourceName {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
                EQBandSliders(settings: eq) { value, index in
                    var updated = eq
                    guard updated.bands.indices.contains(index) else { return }
                    updated.bands[index].gainDB = value
                    updated.usesAutomaticPreamp = true
                    apply(updated)
                }
                Text(String(format: "前置增益 %.1f dB（自動抵銷最大提升、防削波）", eq.effectivePreampDB))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func enable(_ enabled: Bool) {
        var updated = eq
        if enabled, updated.bands.isEmpty {
            updated = EQSettings.tenBandDefault()
        }
        updated.isEnabled = enabled
        apply(updated)
    }

    /// 「EQ 存著但關掉」要保留設定（與裝置版同一態度）；
    /// 完全空白（關著且全零）就存 nil，不留一筆空紀錄。
    private func apply(_ updated: EQSettings) {
        let isBlank = !updated.isEnabled && !updated.bands.contains { $0.gainDB != 0 }
        appState.tapEngine.setAppEQ(isBlank ? nil : updated, bundleID: bundleID)
    }

    private var engineReason: String? {
        switch appState.tapEngine.state {
        case .active: nil
        case .denied: "系統音訊錄製權限被拒——App 層處理無法運作"
        case .off: "需要先在設定 → 音訊開啟「App 音訊接管」"
        default: "正在確認權限…"
        }
    }
}
