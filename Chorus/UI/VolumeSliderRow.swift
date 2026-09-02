import SwiftUI

struct VolumeSliderRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var device: AudioDeviceModel
    let manager: AudioDeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    manager.setAsDefault(device)
                } label: {
                    Image(systemName: device.isDefault ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(device.isDefault ? Color.accentColor : Color.secondary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("設為預設輸出裝置")

                Text(displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .help(nameHelp)
                Spacer()
                if manager.isExcluded(device) {
                    Text("已排除")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(AudioDeviceManager.excludedReason)
                }
                // 徽章擇一：已橋接時 DDC 已含連接資訊（tooltip 補充），不再疊 transport
                if let target = forwardTarget {
                    // 合併列：徽章講的是「音量怎麼送到目標裝置」——
                    // DDC 硬體鏡射／原生音量鏡射（都不損音質）或 driver 端數位衰減
                    Text(badgeText(for: target))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(nameHelp)
                } else if device.bridgedDisplayID != nil {
                    Text("DDC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("螢幕音訊（\(device.transportLabel ?? "外接")）：音量經 DDC/CI 控制螢幕喇叭")
                } else if let label = device.transportLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: SliderRow.spacing) {
                Button {
                    manager.setMuted(!device.muted, for: device)
                } label: {
                    Image(systemName: device.muted ? "speaker.slash" : "speaker.wave.1")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: SliderRow.iconWidth)
                }
                .buttonStyle(.plain)
                .disabled(!device.hasMute && device.bridgedDisplayID == nil && !device.softwareVolumeActive)

                Slider(
                    value: Binding(
                        get: { device.volume },
                        set: { manager.setVolume($0, for: device) }
                    ),
                    in: 0...1
                )
                .disabled(!device.isVolumeControllable)
                .help(
                    device.isVolumeControllable
                        ? (device.softwareVolumeActive ? "以軟體衰減調整音量（Chorus 處理）" : "調整音量")
                        : "此裝置沒有軟體音量，且未橋接到可用的 DDC 螢幕（螢幕需支援 DDC/CI 音量）"
                )

                SliderRow.trailingIcon("speaker.wave.3")
                SliderRow.value(device.volume)
            }
            // 合併列的例外狀態：實體裝置被直接選成預設輸出時，音量鍵不會
            // 經過我們——這時要講，否則使用者只看到一列沒被勾選的裝置。
            if let target = forwardTarget, target.isDefault, !device.isDefault {
                Text("系統目前直接輸出到螢幕——點左側圓圈改由 Chorus 轉送，音量鍵才會生效")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            } else if let target = forwardTarget, target.bridgeUnresponsive {
                Text("螢幕未回應 DDC 音量指令——已改用數位衰減")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
            // 螢幕音訊沒有 CoreAudio 音量：三種狀態各自說明——
            // 無法橋接／螢幕不理指令（寫後驗證戳破）／可用但音量鍵未接管。
            if !device.canSetVolume {
                Group {
                    if device.softwareVolumeActive {
                        Text("軟體音量生效中——此裝置的所有音訊經過 Chorus（多約 10 ms 延遲）")
                            .foregroundStyle(.secondary)
                    } else if let reason = manager.softwareVolumeUnavailableReason(device) {
                        Text(reason)
                            .foregroundStyle(.orange)
                    } else if manager.isBridgeDisabled(device) {
                        Text("已標記為不支援 DDC 音量（右鍵可重新啟用）")
                            .foregroundStyle(.secondary)
                    } else if device.bridgedDisplayID == nil {
                        Text("螢幕的 DDC 不可用，音量無法控制")
                            .foregroundStyle(.secondary)
                    } else if device.bridgeUnresponsive {
                        Text("螢幕未回應音量指令——可能不支援 DDC 音量（VCP 0x62）")
                            .foregroundStyle(.orange)
                    } else if device.isDefault, !appState.settings.mediaKeyCaptureEnabled {
                        Text("音量鍵對螢幕喇叭無效——設定 → 鍵盤媒體鍵可接管")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
            }
        }
        .contextMenu {
            if manager.isHidden(device) {
                Button("取消隱藏此裝置") { manager.setHidden(false, for: device) }
            } else {
                Button("隱藏此裝置") { manager.setHidden(true, for: device) }
            }
            // 排除＝不插入任何裝置級處理（軟體音量／EQ／平衡／效果鏈）。
            // 音量滑桿照常運作——那是寫裝置自己的音量，不是處理。
            if manager.isExcluded(device) {
                Button("取消排除此裝置") { manager.setExcluded(false, for: device) }
            } else {
                Button("排除此裝置（不做音訊處理）") { manager.setExcluded(true, for: device) }
                    .help("此裝置的音訊完全走原生路徑：不套用 EQ、平衡、效果鏈與軟體音量。既有設定會保留，取消排除即恢復。")
            }
            if !device.canSetVolume {
                if manager.isBridgeDisabled(device) {
                    Button("重新啟用 DDC 音量橋接") { manager.setBridgeDisabled(false, for: device) }
                } else {
                    Button("標記此螢幕不支援 DDC 音量") { manager.setBridgeDisabled(true, for: device) }
                }
                // 三後端矩陣的第三條（B6-4）。只在前兩條都走不通時才提供——
                // 有硬體音量卻繞道軟體衰減是純粹的損失（延遲＋位深）
                if manager.canUseSoftwareVolume(device) {
                    if manager.isSoftwareVolumeEnabled(device) {
                        Button("關閉軟體音量") { manager.setSoftwareVolumeEnabled(false, for: device) }
                    } else {
                        Button("以軟體音量控制此裝置…") {
                            manager.setSoftwareVolumeEnabled(true, for: device)
                        }
                        .help("此裝置的所有音訊會經過 Chorus 做衰減，多約 10 ms 延遲；需要「App 音訊接管」權限")
                    }
                }
            }
        }
    }

    /// 這一列是虛擬輸出裝置、而且 driver 正在轉送到某個實體裝置時，
    /// 兩者併成一列顯示（名稱用實體裝置的——使用者心裡的輸出目的地是
    /// 那台螢幕，不是驅動程式）。轉送目標本身不再單獨列出。
    private var forwardTarget: AudioDeviceModel? {
        guard device.uid == VirtualAudioDriverController.deviceUID else { return nil }
        return manager.virtualForwardTarget
    }

    private var displayName: String {
        manager.displayName(for: device)
    }

    private var nameHelp: String {
        guard let target = forwardTarget else { return device.name }
        switch target.forwardVolumeMode {
        case .ddc:
            return String(localized: "由 Chorus 轉送到「\(target.name)」：音量直接寫進螢幕硬體（DDC，不損音質）")
        case .native:
            return String(localized: "由 Chorus 轉送到「\(target.name)」：音量鏡射到該裝置自己的音量（不損音質）")
        case .digital:
            return String(localized: "由 Chorus 轉送到「\(target.name)」：音量以數位衰減調整")
        }
    }

    private func badgeText(for target: AudioDeviceModel) -> String {
        switch target.forwardVolumeMode {
        case .ddc: "DDC"
        case .native: String(localized: "鏡射")
        case .digital: String(localized: "數位音量")
        }
    }
}
