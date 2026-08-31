import ChorusCore
import CoreGraphics
import SwiftUI

/// 選單列上那顆圖示。把散在各 manager 的狀態收成一份量化過的
/// `StatusIconState`，交給 `StatusIconRenderer` 畫。
///
/// 讀哪一份：
/// - 亮度：**主顯示器**（選單列所在的那台）。取平均會讓單台的調整看不出來。
/// - 音量：**預設輸出裝置**。就是媒體鍵會動到的那個。
/// - 倒數：防睡眠計時的剩餘時間。
struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let state = state
        Image(nsImage: StatusIconRenderer.image(for: state))
            .accessibilityLabel(accessibilityLabel(state))
    }

    private var state: StatusIconState {
        let displays = appState.displayManager.displays
        let display = displays.first { $0.id == CGMainDisplayID() } ?? displays.first
        let device = appState.audioManager.defaultDevice
        return StatusIconState(
            brightness: StatusIcon.quantize(display?.brightness),
            volume: StatusIcon.quantize(device?.volume),
            isMuted: device?.muted ?? false,
            badge: StatusIcon.keepAwakeBadge(
                remainingSeconds: appState.keepAwake.remainingSeconds,
                isHolding: appState.keepAwake.isHolding
            )
        )
    }

    private func accessibilityLabel(_ state: StatusIconState) -> String {
        StatusIconRenderer.image(for: state).accessibilityDescription ?? "Chorus"
    }
}
