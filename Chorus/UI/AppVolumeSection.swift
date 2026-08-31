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
            // 兩份清單每次 body 都要重算（O(行程×App) 的歸組＋排序），
            // 而 body 在滑桿拖動時每個 tick 都重跑——整個 body 只算一次，
            // 不讓 dormantApps／listedApps 各自再算一輪 activeApps
            let active = activeApps
            let dormant = dormantApps(excluding: Set(active))
            let listed = showAll ? active + dormant : active
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 6) {
                    Text("各 App 音量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !dormant.isEmpty {
                        Button(showAll ? "只看使用中" : "全部 \(dormant.count + active.count)") {
                            showAll.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                if listed.isEmpty {
                    Text("目前沒有 App 在播放聲音")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(listed, id: \.self) { bundleID in
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

    /// 現在正在發聲、已調整過、或被排除的 App——這三類永遠列出來。
    /// 「已調整但已退出」要在：不然使用者找不到地方把它調回來；
    /// 「已排除」同理——取消排除的入口就在這一列的右鍵選單。
    private var activeApps: [String] {
        let registry = appState.tapEngine.registry
        let audible = registry.listableApps.filter { registry.isGroupAudible(bundleID: $0) }
        let adjusted = appState.settings.appAudio.adjustedBundleIDs
        let excluded = appState.settings.excludedApps.sorted()
        return orderedUnique(audible + adjusted + excluded)
    }

    /// 有音訊行程但沒在發聲、也沒調整過的。
    private func dormantApps(excluding active: Set<String>) -> [String] {
        appState.tapEngine.registry.listableApps
            .filter { !active.contains($0) }
    }

    private func orderedUnique(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        let registry = appState.tapEngine.registry
        // 名稱先解一次再排序——比較器裡查 displayName 的話，已退出的 App
        // 每次比較都是一趟 LaunchServices（與 registry.listableApps 同一個修法）
        return bundleIDs
            .filter { seen.insert($0).inserted }
            .map { (id: $0, name: registry.displayName(bundleID: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.id)
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
                if isExcluded {
                    Text("已排除")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("Chorus 完全不碰這個 App 的音訊——per-app 調整與裝置等化／軟體音量都略過它")
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
            HStack(spacing: SliderRow.spacing) {
                Button {
                    appState.tapEngine.toggleMuted(bundleID: bundleID)
                } label: {
                    Image(systemName: setting.muted ? "speaker.slash" : "speaker.wave.1")
                        .imageScale(.small)
                        .foregroundStyle(setting.muted ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: SliderRow.iconWidth)
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

                SliderRow.trailingIcon("speaker.wave.3")
                SliderRow.value(Double(setting.gain))
            }
            // 排除中：控制項留在原位但不可動——列還在（取消排除的入口），
            // 消失的是「可以調」這件事，不是 App 本身
            .disabled(isExcluded)
            .opacity(isExcluded ? 0.4 : 1)
            routeCaption
                .padding(.leading, 24)
        }
        .contextMenu {
            if isExcluded {
                Button("重新納入音訊處理") {
                    appState.tapEngine.setExcluded(false, bundleID: bundleID)
                }
                .help("恢復 Chorus 對這個 App 的處理——先前的調整原樣回來")
            } else {
                Menu("輸出到") {
                    Button {
                        appState.tapEngine.setOutputDevice(nil, bundleID: bundleID)
                    } label: {
                        Label("跟隨系統預設", systemImage: setting.outputDeviceUID == nil ? "checkmark" : "")
                    }
                    Divider()
                    // 轉送目標併在虛擬裝置那一列（選單列一致）——同一個目的地
                    // 列兩次只會讓人選到沒有音量控制的那個
                    ForEach(appState.audioManager.listableDevices) { device in
                        Button {
                            appState.tapEngine.setOutputDevice(device.uid, bundleID: bundleID)
                        } label: {
                            Label(
                                appState.audioManager.displayName(for: device),
                                systemImage: setting.outputDeviceUID == device.uid ? "checkmark" : ""
                            )
                        }
                    }
                }
                Button("回到 100%") { appState.tapEngine.setGain(1, bundleID: bundleID) }
                Button("完全不處理這個 App") { appState.tapEngine.reset(bundleID: bundleID) }
                    .help("清掉所有調整——這個 App 會回到完全原生的音訊路徑，不再建立 tap")
                Divider()
                Button("排除於音訊處理之外") {
                    appState.tapEngine.setExcluded(true, bundleID: bundleID)
                }
                .help("Chorus 完全不碰這個 App：不建 per-app tap，裝置等化與軟體音量也略過它（調整保留，適合 DAW、遊戲、視訊會議）")
            }
        }
    }

    private var isAudible: Bool {
        appState.tapEngine.registry.isGroupAudible(bundleID: bundleID)
    }

    private var isExcluded: Bool {
        appState.tapEngine.isExcluded(bundleID: bundleID)
    }

    /// 路由狀態（B6-3）。只在使用者明確指定過裝置時才佔一行——
    /// 「跟隨系統預設」是預設行為，不需要每一列都重複講一次。
    /// 排除中不顯示：session 本來就不在，「裝置不在」的橘字是誤導。
    @ViewBuilder
    private var routeCaption: some View {
        if let routed = setting.outputDeviceUID, !isExcluded {
            let name = appState.audioManager.devices.first { $0.uid == routed }
                .map { appState.audioManager.displayName(for: $0) }
            let active = appState.tapEngine.activeOutputUID(bundleID: bundleID)
            if let name, active == routed {
                Text("輸出到「\(name)」")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                // 裝置不在（耳機拔了）。設定留著、暫時走預設——插回去會自己接回去
                Text("指定的輸出裝置不在，暫時走系統預設")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
