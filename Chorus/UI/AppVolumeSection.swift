import ChorusCore
import SwiftUI

/// 選單列的「各 App 音量」區（B6-2）。
///
/// 只在引擎 `active` 時出現——權限被拒／未啟用時**整組隱藏**而不是
/// 停用後留在畫面上（DESIGN §6 降級表）。裝置音量、亮度、同步不受影響。
struct AppVolumeSection: View {
    @Environment(AppState.self) private var appState
    /// 展開後才顯示「沒在發聲、也沒調整過」的 App。預設收合的理由：
    /// 一台機器上有音訊行程的 App 動輒十幾個（各種 helper），
    /// 全列出來會把選單撐爆，而使用者九成是要調現在正在響的那個。
    @State private var showAll = false

    var body: some View {
        if case .active = appState.tapEngine.state {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 6) {
                    Text("各 App 音量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !dormantApps.isEmpty {
                        Button(showAll ? "只看使用中" : "全部 \(dormantApps.count + activeApps.count)") {
                            showAll.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                if listedApps.isEmpty {
                    Text("目前沒有 App 在播放聲音")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(listedApps, id: \.self) { bundleID in
                            AppVolumeRow(bundleID: bundleID)
                        }
                    }
                }

                if let error = appState.tapEngine.lastTapError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { appState.tapEngine.registry.refresh() }
        }
    }

    /// 現在正在發聲、或已經被調整過的 App——這兩類永遠列出來。
    /// 「已調整但已退出」也要在：不然使用者找不到地方把它調回來。
    private var activeApps: [String] {
        let audible = appState.tapEngine.registry.controllableProcesses
            .filter(\.isAudible)
            .compactMap(\.bundleID)
        let adjusted = appState.settings.appAudio.adjustedBundleIDs
        return orderedUnique(audible + adjusted)
    }

    /// 有音訊行程但沒在發聲、也沒調整過的。
    private var dormantApps: [String] {
        let active = Set(activeApps)
        return appState.tapEngine.registry.controllableProcesses
            .compactMap(\.bundleID)
            .filter { !active.contains($0) }
    }

    private var listedApps: [String] {
        showAll ? activeApps + dormantApps : activeApps
    }

    private func orderedUnique(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        let registry = appState.tapEngine.registry
        return bundleIDs
            .filter { seen.insert($0).inserted }
            .sorted {
                registry.displayName(bundleID: $0)
                    .localizedStandardCompare(registry.displayName(bundleID: $1)) == .orderedAscending
            }
    }
}

/// 一個 App 的圖示＋滑桿＋靜音。
private struct AppVolumeRow: View {
    @Environment(AppState.self) private var appState
    let bundleID: String

    private var setting: AppAudioSetting {
        appState.tapEngine.setting(for: bundleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let icon = appState.tapEngine.registry.icon(bundleID: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "app.dashed")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                Text(appState.tapEngine.registry.displayName(bundleID: bundleID))
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if isAudible {
                    Image(systemName: "waveform")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help("正在發聲")
                }
                if setting.gain > 1 {
                    Text("boost")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("增益超過 100%，超出部分會過 soft limiter 防削波")
                }
            }
            HStack(spacing: 8) {
                Button {
                    appState.tapEngine.toggleMuted(bundleID: bundleID)
                } label: {
                    Image(systemName: setting.muted ? "speaker.slash" : "speaker.wave.1")
                        .imageScale(.small)
                        .foregroundStyle(setting.muted ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                // 0–4x（PLAN B6-2）。100% 不在正中間是刻意的：
                // 衰減比 boost 常用得多，把常用區段拉寬比刻度好看重要
                Slider(
                    value: Binding(
                        get: { Double(setting.gain) },
                        set: { appState.tapEngine.setGain(Float($0), bundleID: bundleID) }
                    ),
                    in: 0...Double(GainRamp.maxGain)
                )
                .opacity(setting.muted ? 0.5 : 1)

                Text(setting.gain, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .contextMenu {
            Button("回到 100%") { appState.tapEngine.setGain(1, bundleID: bundleID) }
            Button("完全不處理這個 App") { appState.tapEngine.reset(bundleID: bundleID) }
                .help("清掉所有調整——這個 App 會回到完全原生的音訊路徑，不再建立 tap")
        }
    }

    private var isAudible: Bool {
        appState.tapEngine.registry.entry(bundleID: bundleID)?.isAudible ?? false
    }
}
