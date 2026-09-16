import ChorusCore
import SwiftUI

/// 獨立顯示設定視窗：模式清單、試用確認倒數、記住偏好。
struct DisplaySettingsView: View {
    @Environment(AppState.self) private var appState
    let displayUUID: String

    @State private var showAdvanced = false

    private var model: DisplayModel? {
        appState.displayManager.displays.first { $0.uuid == displayUUID }
    }

    private var controller: DisplayConfigurationController {
        appState.displayConfiguration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model {
                header(model)
                if controller.activeDisplayUUID == displayUUID,
                   controller.phase == .awaitingConfirmation
                {
                    confirmationBanner
                }
                if let message = controller.lastErrorMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                modeLists(model)
            } else {
                Text("找不到顯示器")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 320)
    }

    private func header(_ model: DisplayModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.name)
                .font(.title3.weight(.semibold))
            if let summary = model.modeSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let hdr = model.hdrStatus {
                Text("HDR：\(hdr)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isMirrored {
                Text("鏡像組：第一版僅供檢視，不能切換模式")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var confirmationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("試用中")
                    .font(.headline)
                Spacer()
                if let remaining = controller.remainingSeconds {
                    Text("\(Int(remaining.rounded(.up))) 秒後還原")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let candidate = controller.candidateMode {
                Text(candidate.summary)
                    .font(.callout)
            }
            HStack {
                Button("保留") { controller.confirm() }
                    .keyboardShortcut(.defaultAction)
                Button("還原", role: .cancel) { controller.cancel() }
                Spacer()
                Toggle(
                    "記住此模式",
                    isOn: Binding(
                        get: {
                            appState.settings.displayModePreference(for: displayUUID) != nil
                        },
                        set: { on in
                            if on, let mode = controller.candidateMode {
                                appState.settings.setDisplayModePreference(
                                    DisplayModePreference(
                                        displayUUID: displayUUID,
                                        mode: mode,
                                        applyOnReconnect: false
                                    )
                                )
                            } else {
                                appState.settings.clearDisplayModePreference(for: displayUUID)
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .help("只記住偏好，重新連接時不會自動套用")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func modeLists(_ model: DisplayModel) -> some View {
        let catalog = controller.catalog(for: model)
        let common = catalog.entries.filter(\.isCommon)
        let advanced = catalog.entries.filter { !$0.isCommon }

        return VStack(alignment: .leading, spacing: 8) {
            Text("常用／HiDPI")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            modeList(common, writable: catalog.writable)

            if !advanced.isEmpty {
                DisclosureGroup("進階模式", isExpanded: $showAdvanced) {
                    modeList(advanced, writable: catalog.writable)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private func modeList(_ entries: [DisplayModeCatalog.Entry], writable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries, id: \.mode) { entry in
                Button {
                    _ = controller.beginTrial(displayUUID: displayUUID, candidate: entry.mode)
                } label: {
                    HStack {
                        Text(entry.mode.summary)
                            .foregroundStyle(.primary)
                        Spacer()
                        if entry.isCurrent {
                            Text("目前")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!writable || entry.isCurrent || controller.isActive)
                .padding(.vertical, 4)
            }
        }
    }
}
