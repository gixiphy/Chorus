import ChorusCore
import SwiftUI

struct DisplaySliderRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: DisplayModel
    let manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: model.isBuiltin ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(model.name)
                    .font(.callout)
                Spacer()
                if model.isPoweredOff {
                    Text("已關閉")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                }
                if appState.autoBrightness.isAutoActive(for: model.uuid) {
                    Text("自動")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .help("自動亮度管理中；手動調整會學為此螢幕的差異值")
                }
                if !model.hasHardwareControl {
                    Text("軟體調光")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Button {
                    manager.setDisplayPower(model.isPoweredOff, for: model)
                } label: {
                    Image(systemName: model.isPoweredOff ? "power.circle.fill" : "power")
                        .imageScale(.medium)
                        .foregroundStyle(model.isPoweredOff ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(powerHelp)
            }
            HStack(spacing: SliderRow.spacing) {
                SliderRow.leadingIcon("sun.min")
                Slider(
                    value: Binding(
                        get: { model.brightness },
                        set: { manager.setBrightness($0, for: model) }
                    ),
                    in: 0...1
                )
                SliderRow.trailingIcon("sun.max")
                SliderRow.value(model.brightness)
            }
            // 關閉中不給調亮度：DDC 關機的螢幕收不到 I2C，
            // gamma 全黑的則會被 blackout 擋掉——滑桿動了沒反應比停用更難懂
            .disabled(model.isPoweredOff)
            .opacity(model.isPoweredOff ? 0.4 : 1)
        }
    }

    /// 電源鈕的說明要講清楚「這一下會發生什麼」與「怎麼救回來」——
    /// 三層的行為差很多，使用者不該需要知道 VCP 0xD6 是什麼才敢按。
    private var powerHelp: String {
        if model.isPoweredOff {
            return "開啟這台螢幕"
        }
        let escape = appState.emergencyRestore.isTrusted
            ? "按不回來時連按 8 次 ⌘ 可全部復原。"
            : "連按 8 次 ⌘ 的緊急復原需要輔助使用權限（目前未授權，只在 Chorus 為前景時有效）；結束 Chorus 一定會還原。"
        switch model.powerLayer {
        case .ddc:
            return "關閉螢幕（DDC 電源，背光真的斷電）。\(escape)"
        case .softDisconnect:
            return "關閉螢幕（移出顯示器配置，等同拔線；視窗會被搬到其他螢幕）。\(escape)"
        case .gammaBlackout:
            return "畫面轉黑（螢幕仍通電——這台不支援 DDC 電源，也不能移出配置）。\(escape)"
        }
    }
}
