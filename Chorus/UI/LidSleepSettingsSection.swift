import AppKit
import ChorusCore
import ServiceManagement
import SwiftUI

/// Pure presentation decisions; no helper, filesystem, or clock side effects (V-U01-1).
enum LidSleepSettingsPresentation {
    enum HelperAction: Equatable { case install, allow, repair }
    enum EnableDecision: Equatable { case explain, disable, forbid }
    struct HelperRow {
        let text: String
        let symbol: String
        let action: HelperAction?
    }

    static var batteryFloors: [Int] { LidSleepSettings.allowedBatteryFloors }
    // Fi §D overrides the older 4h choice; Core remains owned by C02.
    static var maxHours: [Double] { LidSleepSettings.allowedMaxHours.filter { $0 <= 3 } }
    static func showsLidControls(confirmedNoLid: Bool) -> Bool { !confirmedNoLid }
    static func enableDecision(_ enabled: Bool, confirmedNoLid: Bool) -> EnableDecision {
        if !enabled { return .disable }
        return confirmedNoLid ? .forbid : .explain
    }
    static func acceptsCLI(isDirectory: Bool, isExecutable: Bool) -> Bool {
        !isDirectory && isExecutable
    }
    static func canRemove(holderCount: Int, callerIsHolder: Bool, recoveryBlocked: Bool, sleepDisabled: Bool?) -> Bool {
        !recoveryBlocked && sleepDisabled != nil && holderCount <= (callerIsHolder ? 1 : 0)
    }
    @MainActor
    static func performRepair(
        replaceRegisteredHelper: Bool,
        unregister: () async throws -> Void, register: () async throws -> Void
    ) async throws {
        if replaceRegisteredHelper { try await unregister() }
        try await register()
    }
    static func helper(availability: LidHelperAvailability, build: String?) -> HelperRow {
        switch availability {
        case .notRegistered:
            HelperRow(text: String(localized: "輔助程序尚未安裝"), symbol: "circle", action: .install)
        case .requiresApproval:
            HelperRow(text: String(localized: "輔助程序等待允許"), symbol: "exclamationmark.triangle", action: .allow)
        case .ready:
            HelperRow(text: String(localized: "輔助程序已啟用（build \(build ?? "—")）"), symbol: "checkmark.circle.fill", action: nil)
        case .connecting:
            HelperRow(text: String(localized: "正在連線至輔助程序…"), symbol: "arrow.triangle.2.circlepath", action: nil)
        case .notFound:
            HelperRow(text: String(localized: "找不到輔助程序，請修復"), symbol: "exclamationmark.triangle", action: .repair)
        case .versionMismatch:
            HelperRow(text: String(localized: "輔助程序版本不相容，請修復"), symbol: "exclamationmark.triangle", action: .repair)
        case let .error(message):
            HelperRow(text: String(localized: "輔助程序錯誤：\(message)"), symbol: "exclamationmark.triangle", action: .repair)
        }
    }
    static func health(_ value: KeepAwakeSourceHealth) -> String {
        switch value {
        case .ok: String(localized: "正常")
        case let .degraded(reason): String(localized: "降級：\(reason)")
        case let .unavailable(reason): String(localized: "來源無法使用：\(reason)")
        }
    }
}

struct LidSleepSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var explanation: Explanation?
    @State private var confirmingRemoval = false
    @State private var operationInProgress = false
    @State private var operationError: String?
    @State private var serviceAvailability: LidHelperAvailability = .notRegistered
    @State private var cliError: String?
    @State private var showingAutomation = false
    @State private var showingRestoreCommand = false
    @State private var activeLeaseCount = 0

    private enum Explanation: String, Identifiable {
        case enable, repair
        var id: String { rawValue }
    }
    private var guardController: LidSleepGuardController { appState.keepAwake.lidGuard }
    private var visibleLeftover: LeftoverSleepDisabled? {
        LidMenuStatusFormatter.visibleLeftover(guardController.leftover, helperStatus: guardController.helperStatus)
    }
    private var availability: LidHelperAvailability {
        if case let .unavailable(value) = guardController.phase { return value }
        if serviceAvailability == .connecting, let status = guardController.helperStatus {
            return PowerHelperHandshakeResult.evaluate(
                status: status,
                appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            ).availability
        }
        return serviceAvailability
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if LidSleepSettingsPresentation.showsLidControls(confirmedNoLid: guardController.isConfirmedNoLid) {
                lidControls
            }
            sourceControls
            currentStatus
            if let leftover = visibleLeftover {
                leftoverControls(leftover)
            }
            if let operationError {
                Text(operationError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .disabled(operationInProgress)
        .sheet(item: $explanation) { intent in explanationSheet(intent) }
        .sheet(isPresented: $showingAutomation) { automationSheet }
        .task {
            // PERF-1: one settingsOpened refresh; render controller cache (no SM/.status on MainActor).
            await guardController.refreshHelperAvailabilityAsync()
            serviceAvailability = guardController.helperAvailability
            while !Task.isCancelled {
                activeLeaseCount = appState.keepAwake.sourceHub.leases.snapshot().active.count
                serviceAvailability = guardController.helperAvailability
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var lidControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("闔上螢幕時").font(.headline)
            Toggle("Agent 工作時，闔上螢幕也不睡（需安裝輔助程序）", isOn: Binding(
                get: { guardController.settings.enabled },
                set: { value in
                    switch LidSleepSettingsPresentation.enableDecision(value, confirmedNoLid: guardController.isConfirmedNoLid) {
                    case .explain: explanation = .enable
                    case .disable: guardController.settings.enabled = false
                    case .forbid: break
                    }
                }
            ))
            Text("只在 Agent 模式生效。輔助程序會以管理員權限修改系統睡眠設定；Chorus 或輔助程序當掉時可能需要手動還原，請參閱 README。")
                .font(.caption).foregroundStyle(.secondary)
            helperControls
            Picker("用電池時最低電量", selection: settingsBinding(\.batteryFloorPercent)) {
                ForEach(LidSleepSettingsPresentation.batteryFloors, id: \.self) { floor in
                    Text("\(floor)%").tag(floor)
                }
            }
            Picker("闔蓋最長時間", selection: settingsBinding(\.maxLidClosedSeconds)) {
                ForEach(LidSleepSettingsPresentation.maxHours, id: \.self) { hours in
                    Text("\(Int(hours)) 小時").tag(hours * 3600)
                }
            }
            Text("接上電源時也套用時間上限；最長 3 小時。溫度達「嚴重」即解除。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("闔蓋防睡通知", isOn: settingsBinding(\.notificationsEnabled))
        }
    }

    private var helperControls: some View {
        let row = LidSleepSettingsPresentation.helper(availability: availability, build: guardController.helperStatus?.helperBuild)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(row.text, systemImage: row.symbol).font(.caption)
                Spacer()
                switch row.action {
                case .install: Button("安裝輔助程序…") { explanation = .enable }
                case .allow: Button("打開「登入項目與延伸功能」") { guardController.openHelperApprovalSettings() }
                case .repair: Button("修復…") { explanation = .repair }
                case nil: EmptyView()
                }
            }
            if availability != .notRegistered {
                DisclosureGroup("輔助程序進階選項") {
                    Button("移除輔助程序…") { confirmingRemoval = true }
                    if confirmingRemoval {
                        Text("移除前會先解除 Chorus 的持有；其他使用者仍在持有或還原失敗時會停止移除。")
                            .font(.caption)
                        if !removalAvailable {
                            Text("輔助程序狀態尚未確認，或另有持有／還原作業；請稍後再移除。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("取消") { confirmingRemoval = false }
                            Button("確認移除", role: .destructive) { removeHelper() }
                                .disabled(!removalAvailable)
                        }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("額外的工作來源").font(.headline)
            Toggle("Orca：讀取 worktree 狀態（orca worktree ps）", isOn: sourceBinding(\.keepAwakeOrcaEnabled))
            Toggle("等待權限（permission）也算工作中", isOn: sourceBinding(\.keepAwakeOrcaCountsPermission))
                .disabled(!appState.settings.keepAwakeOrcaEnabled)
            HStack {
                Text("CLI：\(appState.settings.keepAwakeOrcaCLIPath ?? String(localized: "自動尋找 orca"))")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("變更…", action: chooseCLI)
                if appState.settings.keepAwakeOrcaCLIPath != nil {
                    Button("自動尋找") {
                        appState.settings.keepAwakeOrcaCLIPath = nil
                        configureSources()
                        cliError = nil
                    }
                }
            }.font(.caption)
            if let report = appState.keepAwake.sourceHub.reports.first(where: { $0.kind == .orca }) {
                Text(LidSleepSettingsPresentation.health(report.health)).font(.caption).foregroundStyle(.secondary)
            }
            if let cliError { Text(cliError).font(.caption).foregroundStyle(.red) }
            Toggle("Codex／Claude 桌面 App", isOn: sourceBinding(\.keepAwakeDesktopAgentsEnabled))
            Text("Claude 桌面 App 的簽章尚未確認，目前只使用既有 log 與行程偵測。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Grok Bot App 開著時保持清醒", isOn: sourceBinding(\.keepAwakeGrokBotEnabled))
            Text("Grok Bot 的運算在雲端，Mac 端看不出它有沒有在工作；勾選後只要 App 開著就不睡，直到時限或電量底線。")
                .font(.caption).foregroundStyle(.secondary)
            Text("心跳租約（chorus keepawake hold）：\(activeLeaseCount) 個有效")
                .font(.caption)
            if !appState.settings.automationServerEnabled {
                HStack {
                    Text("心跳租約需開啟「自動化介面」。").font(.caption)
                    Button("前往自動化介面") { showingAutomation = true }.controlSize(.small)
                }
            }
        }
    }

    private var removalAvailable: Bool {
        guard let status = guardController.helperStatus else { return false }
        return visibleLeftover != .foreign && visibleLeftover != .unknownOwner
            && LidSleepSettingsPresentation.canRemove(
                holderCount: status.holderCount, callerIsHolder: status.callerIsHolder,
                recoveryBlocked: status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded,
                sleepDisabled: status.sleepDisabled
            )
    }

    @ViewBuilder
    private var currentStatus: some View {
        if visibleLeftover == nil, let row = LidMenuStatusFormatter.format(
            phase: guardController.phase, enabled: guardController.settings.enabled,
            agentModeActive: appState.keepAwake.mode == .whileAgentsWorking,
            confirmedHolding: guardController.isActuallyHoldingSleepDisabled && guardController.helperStatus?.setByHelper == true,
            leftover: nil, sources: guardController.contributingSources,
            nowUptime: LidMonotonicTime.seconds() ?? ProcessInfo.processInfo.systemUptime,
            wallNow: Date(), maxDurationSeconds: guardController.settings.maxLidClosedSeconds,
            releaseAt: appState.keepAwake.sourceHub.busy.releaseAt
        ) {
            Label(String(localized: "目前：\(row.text)"), systemImage: row.symbol)
                .font(.caption).help(row.help)
        }
    }

    @ViewBuilder
    private func leftoverControls(_ leftover: LeftoverSleepDisabled) -> some View {
        Divider()
        if leftover == .recoveryBlocked {
            Text("睡眠設定還原尚未確認，請處理").font(.caption)
        } else {
            Text("系統目前不會睡眠（SleepDisabled=1）").font(.caption)
        }
        switch leftover {
        case .ownResidual:
            Button("還原 Chorus 的睡眠設定") { guardController.restoreLeftover() }.controlSize(.small)
        case .otherUserHolding:
            Text("其他 Chorus 連線仍在持有，請先在該連線解除；這裡不會覆寫。")
                .font(.caption).foregroundStyle(.secondary)
        case .foreign, .unknownOwner, .recoveryBlocked:
            Button("顯示還原指令") { showingRestoreCommand.toggle() }.controlSize(.small)
            if showingRestoreCommand {
                Text("請先確認沒有其他工具正在防睡眠，再於終端機手動執行：")
                    .font(.caption)
                Text(verbatim: "sudo pmset -a disablesleep 0").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("輔助程序無法保障外部設定的睡眠；Chorus 不會自動覆寫。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func explanationSheet(_ intent: Explanation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("闔蓋防睡需要系統輔助程序").font(.headline)
            Text("輔助程序會以管理員權限修改系統睡眠設定。闔蓋後請勿把 Mac 放進包包，以免過熱。用電池時至少保留 30% 電量，溫度達「嚴重」即解除；接電也最多保持 3 小時。")
            Text("Chorus 或輔助程序當掉時可能留下防睡眠設定，需依 README 手動還原。")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { explanation = nil }
                Button(intent == .repair ? String(localized: "修復輔助程序") : String(localized: "安裝並開啟")) {
                    explanation = nil
                    installHelper(intent: intent)
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }

    private var automationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自動化介面").font(.headline)
            Toggle("開啟自動化介面", isOn: Binding(
                get: { appState.settings.automationServerEnabled },
                set: {
                    appState.settings.automationServerEnabled = $0
                    appState.automationServer.updateActivation()
                }
            ))
            Text("CLI 安裝與 token 設定在「診斷」分頁的「自動化介面」。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { showingAutomation = false } }
        }.padding(24).frame(width: 440)
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<LidSleepSettings, Value>) -> Binding<Value> {
        Binding(get: { guardController.settings[keyPath: keyPath] }, set: { guardController.settings[keyPath: keyPath] = $0 })
    }
    private func sourceBinding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { appState.settings[keyPath: keyPath] }, set: {
            appState.settings[keyPath: keyPath] = $0
            configureSources()
        })
    }
    private func configureSources() {
        appState.keepAwake.sourceHub.configure(appState.settings.keepAwakeSourceSettings)
        appState.keepAwake.reevaluate()
    }
    private func installHelper(intent: Explanation) {
        guard !guardController.isConfirmedNoLid else { return }
        operationError = nil
        operationInProgress = true
        Task { @MainActor in
            defer { operationInProgress = false }
            do {
                let wasEnabled = guardController.settings.enabled
                // User's sheet confirmation authorizes this action; no installation on appearance.
                if intent == .repair {
                    let replace: Bool
                    if case .versionMismatch = availability { replace = true } else { replace = false }
                    if replace { guardController.settings.enabled = false }
                    try await LidSleepSettingsPresentation.performRepair(
                        replaceRegisteredHelper: replace,
                        unregister: { try await guardController.unregisterHelper() },
                        register: { try await guardController.registerHelper() }
                    )
                } else if availability != .ready {
                    try await guardController.registerHelper()
                }
                if !guardController.isConfirmedNoLid, intent == .enable || wasEnabled {
                    guardController.settings.enabled = true
                }
                await guardController.refreshHelperAvailabilityAsync(reason: .userAction)
                serviceAvailability = guardController.helperAvailability
            } catch { operationError = String(localized: "輔助程序操作失敗：\(String(describing: error))") }
        }
    }
    private func removeHelper() {
        operationError = nil
        operationInProgress = true
        Task { @MainActor in
            defer { operationInProgress = false }
            do {
                // C06 verifies release/readback, other holders, and recovery before unregister.
                // Stop new policy acquisitions before removal; preserve disabled state on failure.
                guardController.settings.enabled = false
                try await guardController.unregisterHelper()
                confirmingRemoval = false
                serviceAvailability = .notRegistered
            } catch { operationError = String(localized: "無法移除輔助程序：\(String(describing: error))") }
        }
    }
    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.path
            Task { @MainActor in
                let valid = await Task.detached(priority: .utility) {
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    return exists && LidSleepSettingsPresentation.acceptsCLI(
                        isDirectory: isDirectory.boolValue,
                        isExecutable: FileManager.default.isExecutableFile(atPath: path)
                    )
                }.value
                if valid {
                    appState.settings.keepAwakeOrcaCLIPath = path
                    cliError = nil
                    configureSources()
                } else {
                    cliError = String(localized: "選取的檔案無法執行，請選擇 orca CLI。")
                }
            }
        }
    }
}
