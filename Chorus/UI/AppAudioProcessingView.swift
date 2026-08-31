import AppKit
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

    /// 捲動區內容的實際高度，決定視窗要多高（見 `scrollHeight`）。
    @State private var contentHeight: CGFloat = 0

    /// 標頭與引擎狀態釘在上緣、其餘捲動：建議卡的高度不可預期，
    /// 讓它把「這是哪個 App」和「權限有沒有到手」推出視野是最糟的取捨。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            if let reason = engineReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    eqSection
                    Divider()
                    EffectChainView(target: .app(bundleID))
                    Divider()
                    AudioAdviceSection(target: .app(bundleID: bundleID))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: scrollHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 440)
    }

    /// 捲動區的高度＝內容高度，但夾在上限之內。
    ///
    /// 必須自己量：SwiftUI 的 ScrollView 沿捲動軸是貪心的，理想高度不會
    /// 貼著內容，只給 `.frame(maxHeight:)` 的話短內容也會撐出一大片空白。
    /// 視窗走 `.contentSize` 跟著這個高度走——內容縮短會收回去，長到超過
    /// 上限就在這裡打住、改由內部捲動，而不是把視窗撐出螢幕。
    private var scrollHeight: CGFloat? {
        guard contentHeight > 0 else { return nil } // 還沒量到：先讓它自然排版
        // 扣掉標題列與釘住的標頭區，再留一點邊
        let cap = max(320, (NSScreen.main?.visibleFrame.height ?? 900) * 0.85 - 140)
        return min(contentHeight, cap)
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

    /// 標題用 .callout 的 Text＋labelsHidden 的開關，而不是 Toggle 自己的
    /// label：三個分區（等化器／效果鏈／AI 調音建議）才會是同一階層——
    /// Toggle label 的字級與 .callout 不同，混用時看起來像三種層級。
    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("等化器（只套這個 App）").font(.callout)
                Toggle("等化器（只套這個 App）", isOn: Binding(
                    get: { eq.isEnabled },
                    set: { enable($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
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
