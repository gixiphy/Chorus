import SwiftUI

/// 「還原到套用建議前」：點按鈕本體還原全部；展開選單可逐台螢幕或只還原曲線。
/// 沒有套用過建議時不顯示。配置圖顧問列與建議面板共用。
struct AdviceRestoreMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let baseline = appState.advisor.baseline {
            Menu {
                ForEach(baseline.displayIDs, id: \.self) { id in
                    Button(appState.advisor.baselineDisplayName(id)) {
                        appState.advisor.restoreDisplay(id)
                    }
                }
                if baseline.hasCurve {
                    Button("自動亮度曲線") { appState.advisor.restoreCurve() }
                }
                Divider()
                Button("全部還原") { appState.advisor.restoreBaseline() }
            } label: {
                Text("還原到套用建議前")
            } primaryAction: {
                appState.advisor.restoreBaseline()
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .controlSize(.small)
            .help("把套用過建議的螢幕差異值與曲線參數，還原到第一次套用建議之前的配置。展開選單可只還原單一螢幕。遠端螢幕離線時跳過並保留原值，連上後可再還原")
        }
    }
}
