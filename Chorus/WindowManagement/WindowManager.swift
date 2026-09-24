import AppKit
import ApplicationServices
import ChorusCore
import Observation

struct ArrangementPreview: Equatable {
    struct Slot: Equatable {
        var frame: LayoutRect
        var appName: String?
        var isPrimary: Bool
    }

    var arrangement: WindowArrangement
    var displayUUID: String
    var topologyGeneration: UInt64
    var slots: [Slot]
}

/// 視窗排列協調器：選單／快捷鍵（M1）與拖曳吸附（M2）。
@MainActor
@Observable
final class WindowManager {
    enum Outcome: Equatable {
        case applied
        case constrained
        case partial
        case restored
        case permissionRequired
        case noTarget
        case unsupported
        case disabled
        case targetGone
        case failed(String)
    }

    /// 指令從哪裡來：選單用開面板前捕捉的視窗；快捷鍵一律抓當下前景視窗。
    enum Source {
        case menu
        case shortcut
    }

    /// 開選單當下的外部前景 App（含已被忽略的，供「忽略／恢復管理」入口使用）。
    struct MenuApp: Equatable {
        var name: String
        var bundleID: String
        var isIgnored: Bool
    }

    enum ShortcutApplyResult: Equatable {
        case applied
        /// 新按鍵有註冊失敗，已撤回並恢復舊方案；設定未變。
        case rolledBack(failed: Set<WindowCommand>)
        /// 新舊都無法完整註冊；`unavailable` 是目前不可用的項目。
        case degraded(unavailable: Set<WindowCommand>)
    }

    private(set) var lastTrusted = false
    private(set) var targetAppName: String?
    private(set) var lastOutcome: Outcome?
    private(set) var statusMessage: String?
    private(set) var menuApp: MenuApp?
    /// 選單目標視窗所在的螢幕（選單用它決定列出哪些「移到…」）。
    private(set) var targetDisplayUUID: String?
    /// 選單目標視窗是否有可還原的記錄。
    private(set) var canRestoreTarget = false
    private(set) var lastReport: ArrangementReport?
    private(set) var canRestoreGroup = false
    private(set) var arrangementPreview: ArrangementPreview?
    /// 註冊失敗、目前按了沒反應的快捷鍵。
    private(set) var unavailableShortcuts: Set<WindowCommand> = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let worker: any WindowBackend
    @ObservationIgnored private let captureTopology: @Sendable (UInt64) -> ScreenTopology
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let engine = LayoutEngine()
    @ObservationIgnored private var restore = RestoreStore()
    @ObservationIgnored private var sizeHints = WindowSizeHints()
    @ObservationIgnored private var captured: AXWindowWorker.WindowRef?
    @ObservationIgnored private var capturedFrame: LayoutRect?
    @ObservationIgnored private var topologyGeneration: UInt64 = 0
    @ObservationIgnored private var shortcuts: WindowShortcutController?
    @ObservationIgnored private var dragMonitor: DragMonitor?
    @ObservationIgnored private let previewOverlay = PreviewOverlay()
    @ObservationIgnored private let arrangementPreviewOverlay = ArrangementPreviewOverlay()
    @ObservationIgnored private let zoneSelection = ZoneSelectionController()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var screenParametersObserver: NSObjectProtocol?
    @ObservationIgnored private var lastExternalPID: pid_t?
    @ObservationIgnored private var shortcutsSuspended = false

    static let batchTimeBudget: TimeInterval = 0.8
    private static let targetGoneReason = "目標視窗已關閉"
    private static let permissionReason = "permissionRequired"

    init(
        settings: SettingsStore,
        worker: any WindowBackend = AXWindowWorker(),
        captureTopology: @escaping @Sendable (UInt64) -> ScreenTopology = ScreenTopology.capture,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.settings = settings
        self.worker = worker
        self.captureTopology = captureTopology
        self.now = now
        startFrontmostTracking()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteScreenParametersChanged()
            }
        }
        zoneSelection.onApply = { [weak self] zoneID in
            self?.applyUltrawide(zoneID: zoneID)
        }
    }

    private func startFrontmostTracking() {
        guard activationObserver == nil else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalPID = front.processIdentifier
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.lastExternalPID = app.processIdentifier
                }
            }
        }
    }

    func updateActivation(promptIfNeeded: Bool = false) {
        guard settings.windowArrangementEnabled else {
            shortcuts?.stop()
            shortcuts = nil
            stopDrag()
            zoneSelection.end(cancelled: true)
            retryTask?.cancel()
            retryTask = nil
            captured = nil
            capturedFrame = nil
            hideArrangementPreview()
            targetAppName = nil
            return
        }
        if promptIfNeeded, !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        lastTrusted = AXIsProcessTrusted()
        if lastTrusted {
            ensureShortcuts()
            updateDragActivation()
            retryTask?.cancel()
            retryTask = nil
        } else {
            shortcuts?.stop()
            shortcuts = nil
            stopDrag()
            startRetryLoop()
        }
    }

    /// 選單面板出現前呼叫：保存目前外部前景視窗。
    func captureMenuTarget() {
        guard settings.windowArrangementEnabled else { return }
        captured = nil
        capturedFrame = nil
        hideArrangementPreview()
        canRestoreTarget = false
        canRestoreGroup = false
        targetDisplayUUID = nil
        menuApp = currentMenuApp()
        if let menuApp, menuApp.isIgnored {
            targetAppName = nil
            statusMessage = String(localized: "已忽略「\(menuApp.name)」，不會排列它的視窗")
            return
        }
        do {
            let ref: AXWindowWorker.WindowRef
            if let pid = lastExternalPID {
                ref = try worker.windowForApplication(
                    pid: pid,
                    excludingBundleIDs: excludedBundleIDs()
                )
            } else {
                ref = try worker.focusedExternalWindow(excludingBundleIDs: excludedBundleIDs())
            }
            captured = ref
            targetAppName = ref.appName
            canRestoreTarget = restore.entry(for: ref.token) != nil
            canRestoreGroup = (restore.group(containing: ref.token)?.tokens.count ?? 0) >= 2
            let topology = bumpTopology()
            capturedFrame = try? worker.getFrame(token: ref.token, topology: topology)
            targetDisplayUUID = capturedFrame
                .flatMap { topology.screen(containing: $0)?.displayUUID }
            statusMessage = nil
        } catch AXWindowWorker.WorkerError.permissionRequired {
            lastTrusted = false
            lastOutcome = .permissionRequired
            statusMessage = "需要輔助使用權限"
            targetAppName = nil
        } catch {
            captured = nil
            capturedFrame = nil
            targetAppName = nil
            statusMessage = "沒有可排列的視窗"
        }
    }

    /// 只用 CG 快照建立排列預覽；不列舉或讀取其他 AX 視窗。
    func previewArrangement(for command: WindowCommand) -> ArrangementPreview? {
        guard settings.windowArrangementEnabled,
              let captured,
              let capturedFrame
        else { return nil }

        let topology = bumpTopology()
        guard let screen = topology.screen(containing: capturedFrame) else { return nil }
        let requestedLimit = command.arrangement?.slotCount ?? 4
        let snapshot = worker.onScreenWindowSnapshot(
            on: screen,
            topology: topology,
            excludingBundleIDs: excludedBundleIDs(),
            limit: requestedLimit
        )
        let others = snapshot.filter {
            !($0.pid == captured.pid && framesMatch($0.frame, capturedFrame))
        }

        let arrangement: WindowArrangement
        if let fixed = command.arrangement {
            arrangement = fixed
        } else if command == .arrangeAuto {
            let count = min(4, 1 + others.count)
            guard let chosen = ArrangementPlanner.choose(
                minSizes: Array(repeating: nil, count: count),
                visible: screen.visibleFrame,
                gap: settings.windowArrangementGap
            ) else { return nil }
            arrangement = chosen
        } else {
            return nil
        }

        let frames = arrangement.frames(
            visible: screen.visibleFrame,
            gap: settings.windowArrangementGap
        )
        let names = [captured.appName] + others.prefix(max(0, frames.count - 1)).map(\.appName)
        let slots = frames.enumerated().map { index, frame in
            ArrangementPreview.Slot(
                frame: frame,
                appName: names.indices.contains(index) ? names[index] : nil,
                isPrimary: index == 0
            )
        }
        return ArrangementPreview(
            arrangement: arrangement,
            displayUUID: screen.displayUUID,
            topologyGeneration: topology.generation,
            slots: slots
        )
    }

    func showArrangementPreview(for command: WindowCommand) {
        arrangementPreview = previewArrangement(for: command)
        if let arrangementPreview {
            arrangementPreviewOverlay.show(arrangementPreview)
        } else {
            arrangementPreviewOverlay.hide()
        }
    }

    func hideArrangementPreview() {
        arrangementPreview = nil
        arrangementPreviewOverlay.hide()
    }

    /// 選單與快捷鍵的共同入口。
    func perform(_ command: WindowCommand, source: Source = .menu) {
        if source == .shortcut {
            ChorusLog.window.info("快捷鍵 → \(command.rawValue)")
        }
        switch command {
        case .nextDisplay:
            moveToAdjacentDisplay(delta: 1, source: source)
        case .previousDisplay:
            moveToAdjacentDisplay(delta: -1, source: source)
        case .restore:
            restoreLast(source: source)
        case .restoreGroup:
            restoreGroup(source: source)
        case .arrangeAuto:
            arrangeAuto(source: source)
        case .selectZone:
            beginKeyboardZoneSelection(source: source)
        default:
            if let index = command.zoneIndex {
                applyUltrawide(zoneIndex: index, source: source)
            } else if let action = command.layoutAction {
                apply(action, source: source)
            } else if let arrangement = command.arrangement {
                arrange(arrangement, source: source)
            }
        }
    }

    /// 依同螢幕視窗數與已知最小尺寸挑選版型；單一視窗直接填滿。
    func arrangeAuto(source: Source = .menu) {
        runArrangement(source: source) { topology, screen, current, ref in
            do {
                let others = try worker.frontToBackWindows(
                    on: screen,
                    topology: topology,
                    excludingBundleIDs: excludedBundleIDs(),
                    excludingTokens: [ref.token],
                    limit: 3
                )
                var seen = Set<String>()
                let windows = ([ref] + others).filter { seen.insert($0.token).inserted }

                guard windows.count > 1 else {
                    let target = engine.frame(
                        for: .maximize,
                        visible: screen.visibleFrame,
                        gap: settings.windowArrangementGap,
                        current: current
                    )
                    restore.rememberOriginalIfNeeded(
                        token: ref.token,
                        original: current,
                        displayUUID: screen.displayUUID,
                        topologyGeneration: topology.generation
                    )
                    let result = writeFrame(target, ref: ref, topology: topology, before: current)
                    if let after = result.after {
                        sizeHints.recordReadBack(token: ref.token, requested: target, actual: after)
                    }
                    if case .applied = result.status, let after = result.after {
                        restore.noteApplied(token: ref.token, after: after)
                    } else if case .constrained = result.status, let after = result.after {
                        restore.noteApplied(token: ref.token, after: after)
                    } else if case .failed(let reason) = result.status, reason == Self.targetGoneReason {
                        restore.invalidate(token: ref.token)
                        sizeHints.forget(token: ref.token)
                        worker.forget(token: ref.token)
                    }
                    let report = ArrangementReport(
                        arrangement: nil,
                        slotCount: 1,
                        items: [
                            ArrangementReport.Item(
                                token: ref.token,
                                appName: ref.appName,
                                target: target,
                                before: current,
                                after: result.after,
                                status: result.status
                            )
                        ],
                        groupID: nil
                    )
                    publish(report)
                    statusMessage = String(localized: "自動排列：填滿。") + report.summaryText
                    return
                }

                guard let arrangement = chooseArrangement(target: ref, others: Array(windows.dropFirst()), screen: screen)
                else { return }
                arrange(arrangement, source: source)
                if let report = lastReport {
                    let title = WindowCommand.allCases.first { $0.arrangement == arrangement }?.title
                        ?? arrangement.rawValue
                    statusMessage = String(localized: "自動排列：\(title)。") + report.summaryText
                }
            } catch let error as WorkerError {
                mapError(error)
            } catch {
                lastOutcome = .failed(error.localizedDescription)
            }
        }
    }

    /// 預覽與自動排列共用的尺寸感知選擇。
    private func chooseArrangement(
        target: WindowRef,
        others: [WindowRef],
        screen: ScreenTopology.ScreenInfo
    ) -> WindowArrangement? {
        let windows = [target] + others
        let minimumSizes = windows.map { window -> LayoutSize? in
            if let known = sizeHints.minimumSize(for: window.token) {
                return known
            }
            if let reported = worker.reportedMinimumSize(token: window.token) {
                sizeHints.recordReported(token: window.token, minimum: reported)
                return reported
            }
            return nil
        }
        return ArrangementPlanner.choose(
            minSizes: minimumSizes,
            visible: screen.visibleFrame,
            gap: settings.windowArrangementGap
        )
    }

    /// 一次排多個視窗：目標視窗放第一格，同螢幕其餘視窗依由前到後的順序填入。
    /// 視窗不夠就只排現有的；逐窗結果會彙整成一份批次報告。
    func arrange(_ arrangement: WindowArrangement, source: Source = .menu) {
        runArrangement(source: source) { topology, screen, current, ref in
            do {
                let others = try worker.frontToBackWindows(
                    on: screen,
                    topology: topology,
                    excludingBundleIDs: excludedBundleIDs(),
                    excludingTokens: [ref.token],
                    limit: arrangement.slotCount - 1
                )
                var seen = Set<String>()
                let windows = ([ref] + others).filter { seen.insert($0.token).inserted }
                let plan = arrangement.plan(
                    windows: windows,
                    visible: screen.visibleFrame,
                    gap: settings.windowArrangementGap
                )
                let groupID = UUID()
                restore.beginGroup(
                    id: groupID,
                    tokens: plan.map(\.window.token),
                    displayUUID: screen.displayUUID,
                    topologyGeneration: topology.generation
                )
                let start = now()
                var items: [ArrangementReport.Item] = []

                for (index, placement) in plan.enumerated() {
                    guard topology.generation == topologyGeneration else {
                        items.append(reportItem(for: placement, before: nil, after: nil, status: .skipped(.topologyChanged)))
                        continue
                    }
                    if index > 0, now() - start >= Self.batchTimeBudget {
                        items.append(reportItem(for: placement, before: nil, after: nil, status: .skipped(.timeBudget)))
                        continue
                    }

                    let before: LayoutRect
                    do {
                        before = placement.window.token == ref.token
                            ? current
                            : try worker.getFrame(token: placement.window.token, topology: topology)
                    } catch WorkerError.permissionRequired {
                        lastTrusted = false
                        for remaining in plan[index...] {
                            items.append(reportItem(
                                for: remaining, before: nil, after: nil,
                                status: .skipped(.permissionRevoked)
                            ))
                        }
                        break
                    } catch WorkerError.targetGone {
                        items.append(reportItem(
                            for: placement, before: nil, after: nil,
                            status: .failed(reason: Self.targetGoneReason)
                        ))
                        restore.invalidate(token: placement.window.token)
                        sizeHints.forget(token: placement.window.token)
                        worker.forget(token: placement.window.token)
                        continue
                    }

                    restore.rememberOriginalIfNeeded(
                        token: placement.window.token,
                        original: before,
                        displayUUID: screen.displayUUID,
                        topologyGeneration: topology.generation,
                        groupID: groupID
                    )
                    let result = writeFrame(
                        placement.frame,
                        ref: placement.window,
                        topology: topology,
                        before: before
                    )
                    if let after = result.after {
                        sizeHints.recordReadBack(
                            token: placement.window.token,
                            requested: placement.frame,
                            actual: after
                        )
                    }

                    if result.status == .failed(reason: Self.permissionReason) {
                        restore.invalidate(token: placement.window.token)
                        lastTrusted = false
                        items.append(reportItem(
                            for: placement, before: before, after: result.after,
                            status: .skipped(.permissionRevoked)
                        ))
                        for remaining in plan.dropFirst(index + 1) {
                            items.append(reportItem(
                                for: remaining, before: nil, after: nil,
                                status: .skipped(.permissionRevoked)
                            ))
                        }
                        break
                    }

                    switch result.status {
                    case .applied, .constrained:
                        if let after = result.after {
                            restore.noteApplied(token: placement.window.token, after: after)
                        }
                    case .reverted:
                        restore.invalidate(token: placement.window.token)
                    case .failed(let reason):
                        restore.invalidate(token: placement.window.token)
                        if reason == Self.targetGoneReason {
                            sizeHints.forget(token: placement.window.token)
                            worker.forget(token: placement.window.token)
                        }
                    case .revertFailed, .skipped:
                        break
                    }
                    items.append(reportItem(
                        for: placement,
                        before: before,
                        after: result.after,
                        status: result.status
                    ))
                }

                let retainedTokens = items.compactMap { item -> String? in
                    switch item.status {
                    case .applied, .constrained, .revertFailed: return item.token
                    default: return nil
                    }
                }
                restore.dropGroup(id: groupID)
                if retainedTokens.count >= 2 {
                    restore.beginGroup(
                        id: groupID,
                        tokens: retainedTokens,
                        displayUUID: screen.displayUUID,
                        topologyGeneration: topology.generation
                    )
                }
                let report = ArrangementReport(
                    arrangement: arrangement,
                    slotCount: arrangement.slotCount,
                    items: items,
                    groupID: retainedTokens.count >= 2 ? groupID : nil
                )
                publish(report)
                ChorusLog.window.info(
                    "多視窗排列 \(arrangement.rawValue)：\(report.appliedCount)/\(arrangement.slotCount) 個視窗"
                )
            } catch let error as AXWindowWorker.WorkerError {
                mapError(error)
            } catch {
                lastOutcome = .failed(error.localizedDescription)
            }
        }
    }

    func apply(_ action: LayoutAction, source: Source = .menu) {
        runArrangement(source: source) { topology, screen, current, ref in
            let target = engine.frame(
                for: action,
                visible: screen.visibleFrame,
                gap: settings.windowArrangementGap,
                current: current
            )
            _ = applyFrame(target, ref: ref, topology: topology, screen: screen, before: current)
        }
    }

    func applyUltrawide(zoneID: String) {
        runArrangement(source: .menu) { topology, screen, current, ref in
            guard screen.supportsZoneTemplates else {
                reportNoZoneTemplates()
                return
            }
            let templateID = templateID(for: screen)
            let template = LayoutTemplateCatalog.template(id: templateID)
            guard let match = template.resolvedZones(
                visible: screen.visibleFrame,
                gap: settings.windowArrangementGap
            ).first(where: { $0.0.id == zoneID })
            else {
                lastOutcome = .failed("找不到分區")
                statusMessage = "找不到分區"
                return
            }
            _ = applyFrame(match.1, ref: ref, topology: topology, screen: screen, before: current)
        }
    }

    /// ⌃⌥1–4：放進視窗所在螢幕目前版型的第 N 區。
    func applyUltrawide(zoneIndex: Int, source: Source = .menu) {
        runArrangement(source: source) { topology, screen, current, ref in
            guard screen.supportsZoneTemplates else {
                reportNoZoneTemplates()
                return
            }
            let zones = LayoutTemplateCatalog.template(id: templateID(for: screen))
                .resolvedZones(visible: screen.visibleFrame, gap: settings.windowArrangementGap)
            guard zones.indices.contains(zoneIndex) else {
                lastOutcome = .failed("找不到分區")
                statusMessage = String(localized: "目前版型只有 \(zones.count) 個分區")
                return
            }
            _ = applyFrame(zones[zoneIndex].1, ref: ref, topology: topology, screen: screen, before: current)
        }
    }

    func restoreLast(source: Source = .menu) {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            return
        }
        guard let ref = resolveTarget(source: source) else { return }
        let topology = bumpTopology()
        guard let entry = restore.entry(for: ref.token) else {
            lastOutcome = .failed("沒有可還原的位置")
            statusMessage = "沒有可還原的位置"
            return
        }
        var frame = entry.original
        let originalScreenMissing = topology.screen(uuid: entry.displayUUID) == nil
        if let screen = topology.screen(uuid: entry.displayUUID) ?? topology.screen(containing: frame) {
            frame = clamp(frame, to: screen.visibleFrame)
        }
        switch worker.setFrame(token: ref.token, frame: frame, topology: topology) {
        case .applied(_, let after), .constrained(_, let after):
            guard framesMatch(after, frame) else {
                lastOutcome = .failed("還原後位置不符")
                statusMessage = "還原後位置不符"
                return
            }
            restore.consume(token: ref.token)
            lastOutcome = .restored
            statusMessage = originalScreenMissing
                ? String(localized: "原螢幕已移除，已放到目前螢幕")
                : "已還原"
            canRestoreTarget = false
            canRestoreGroup = (entry.groupID
                .flatMap { restore.group(id: $0) }?
                .tokens.count ?? 0) >= 2
        case .failed(let error):
            mapError(error)
        }
    }

    /// 還原目標視窗所屬排列群組；每個成員確認讀回成功後才清除記錄。
    func restoreGroup(source: Source = .menu) {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            return
        }
        guard let ref = resolveTarget(source: source) else { return }
        guard let group = restore.group(containing: ref.token) else {
            lastOutcome = .failed("沒有可還原的群組")
            statusMessage = "沒有可還原的群組"
            canRestoreGroup = false
            return
        }

        let topology = bumpTopology()
        let appNames = Dictionary(
            uniqueKeysWithValues: (lastReport?.items ?? []).map { ($0.token, $0.appName) }
        )
        var seen = Set<String>()
        let tokens = group.tokens.filter { seen.insert($0).inserted }
        var items: [ArrangementReport.Item] = []

        for token in tokens {
            guard let entry = restore.entry(for: token) else { continue }
            let current: LayoutRect
            do {
                current = try worker.getFrame(token: token, topology: topology)
            } catch WorkerError.targetGone {
                restore.invalidate(token: token)
                worker.forget(token: token)
                continue
            } catch let error as WorkerError {
                items.append(ArrangementReport.Item(
                    token: token,
                    appName: appNames[token] ?? (token == ref.token ? ref.appName : "App"),
                    target: entry.original,
                    before: nil,
                    after: nil,
                    status: .failed(reason: reportReason(for: error))
                ))
                continue
            } catch {
                items.append(ArrangementReport.Item(
                    token: token,
                    appName: appNames[token] ?? (token == ref.token ? ref.appName : "App"),
                    target: entry.original,
                    before: nil,
                    after: nil,
                    status: .failed(reason: error.localizedDescription)
                ))
                continue
            }

            let appName = appNames[token] ?? (token == ref.token ? ref.appName : "App")
            if restore.isUserMoved(token: token, current: current) {
                restore.invalidate(token: token)
                items.append(ArrangementReport.Item(
                    token: token,
                    appName: appName,
                    target: entry.original,
                    before: current,
                    after: current,
                    status: .failed(reason: "已被移動，略過")
                ))
                continue
            }

            var target = entry.original
            if let screen = topology.screen(uuid: entry.displayUUID) ?? topology.screen(containing: current) {
                target = clamp(target, to: screen.visibleFrame)
            }

            switch worker.setFrame(token: token, frame: target, topology: topology) {
            case .applied, .constrained:
                do {
                    let after = try worker.getFrame(token: token, topology: topology)
                    if framesMatch(after, target) {
                        restore.consume(token: token)
                        items.append(ArrangementReport.Item(
                            token: token,
                            appName: appName,
                            target: target,
                            before: current,
                            after: after,
                            status: .applied
                        ))
                    } else {
                        items.append(ArrangementReport.Item(
                            token: token,
                            appName: appName,
                            target: target,
                            before: current,
                            after: after,
                            status: .failed(reason: "還原後位置不符")
                        ))
                    }
                } catch WorkerError.targetGone {
                    restore.invalidate(token: token)
                    worker.forget(token: token)
                } catch let error as WorkerError {
                    items.append(ArrangementReport.Item(
                        token: token,
                        appName: appName,
                        target: target,
                        before: current,
                        after: nil,
                        status: .failed(reason: reportReason(for: error))
                    ))
                } catch {
                    items.append(ArrangementReport.Item(
                        token: token,
                        appName: appName,
                        target: target,
                        before: current,
                        after: nil,
                        status: .failed(reason: error.localizedDescription)
                    ))
                }
            case .failed(let error):
                items.append(ArrangementReport.Item(
                    token: token,
                    appName: appName,
                    target: target,
                    before: current,
                    after: nil,
                    status: .failed(reason: reportReason(for: error))
                ))
            }
        }

        let report = ArrangementReport(
            arrangement: nil,
            slotCount: group.tokens.count,
            items: items,
            groupID: group.id
        )
        publish(report)
    }

    func retryLastArrangement() {
        guard let report = lastReport, !report.retryable.isEmpty else { return }
        guard let arrangement = report.arrangement else {
            arrangeAuto(source: .menu)
            return
        }
        arrange(arrangement, source: .menu)
    }

    func moveToAdjacentDisplay(delta: Int, source: Source = .menu) {
        runArrangement(source: source) { topology, screen, current, ref in
            guard topology.screens.count > 1 else {
                lastOutcome = .failed("只有一台螢幕")
                statusMessage = "只有一台螢幕"
                return
            }
            let ordered = topology.screens.sorted { a, b in
                if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
                return a.displayUUID < b.displayUUID
            }
            guard let index = ordered.firstIndex(where: { $0.displayUUID == screen.displayUUID }) else { return }
            let next = ordered[(index + delta + ordered.count) % ordered.count]
            move(ref, from: screen, to: next, current: current, topology: topology)
        }
    }

    /// 選單的「移到〈螢幕名稱〉」。
    func moveToDisplay(uuid: String) {
        runArrangement(source: .menu) { topology, screen, current, ref in
            guard let destination = topology.screen(uuid: uuid) else {
                lastOutcome = .failed("找不到螢幕")
                statusMessage = "找不到螢幕"
                return
            }
            move(ref, from: screen, to: destination, current: current, topology: topology)
            targetDisplayUUID = destination.displayUUID
        }
    }

    /// 保持相對位置與大小搬到另一台螢幕，並限制在可用區域內。
    private func move(
        _ ref: AXWindowWorker.WindowRef,
        from screen: ScreenTopology.ScreenInfo,
        to next: ScreenTopology.ScreenInfo,
        current: LayoutRect,
        topology: ScreenTopology
    ) {
        let relX = (current.x - screen.visibleFrame.x) / max(screen.visibleFrame.width, 1)
        let relY = (current.y - screen.visibleFrame.y) / max(screen.visibleFrame.height, 1)
        let relW = current.width / max(screen.visibleFrame.width, 1)
        let relH = current.height / max(screen.visibleFrame.height, 1)
        var target = LayoutRect(
            x: next.visibleFrame.x + relX * next.visibleFrame.width,
            y: next.visibleFrame.y + relY * next.visibleFrame.height,
            width: relW * next.visibleFrame.width,
            height: relH * next.visibleFrame.height
        )
        target = clamp(target, to: next.visibleFrame)
        _ = applyFrame(target, ref: ref, topology: topology, screen: next, before: current)
    }

    func templateID(for screen: ScreenTopology.ScreenInfo) -> LayoutTemplateID {
        if let raw = settings.windowArrangementTemplatesByDisplay[screen.displayUUID],
           let id = LayoutTemplateID(rawValue: raw) {
            return id
        }
        let ratio = screen.frame.width / max(screen.frame.height, 1)
        return LayoutTemplateCatalog.recommended(aspectRatio: ratio)
    }

    func setTemplate(_ id: LayoutTemplateID, forDisplayUUID uuid: String) {
        settings.windowArrangementTemplatesByDisplay[uuid] = id.rawValue
    }

    /// 鍵盤選區：方向鍵移動、Enter 套用、Esc 取消。
    func beginKeyboardZoneSelection(source: Source = .menu) {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            return
        }
        if source == .shortcut {
            // 選區面板稍後以 `.menu` 套用，所以先把當下前景視窗定下來
            captured = resolveTarget(source: .shortcut)
            guard captured != nil else { return }
        } else {
            captureMenuTarget()
        }
        let topology = bumpTopology()
        let point = NSEvent.mouseLocation
        guard let screen = topology.screen(containingPointX: Double(point.x), y: Double(point.y))
                ?? topology.screens.first
        else {
            statusMessage = "找不到螢幕"
            return
        }
        guard screen.supportsZoneTemplates else {
            reportNoZoneTemplates()
            return
        }
        let template = LayoutTemplateCatalog.template(id: templateID(for: screen))
        zoneSelection.begin(
            template: template,
            visible: screen.visibleFrame,
            gap: settings.windowArrangementGap
        )
        statusMessage = "鍵盤選區：方向鍵移動，Enter 套用，Esc 取消"
    }

    func cancelKeyboardZoneSelection() {
        zoneSelection.end(cancelled: true)
    }

    /// 螢幕參數改變時讓進行中的批次偵測到世代已失效。
    func noteScreenParametersChanged() {
        topologyGeneration &+= 1
        hideArrangementPreview()
    }

    // MARK: - Private

    private func ensureShortcuts() {
        guard shortcuts == nil else { return }
        let controller = WindowShortcutController { [weak self] command in
            self?.perform(command, source: .shortcut)
        }
        shortcuts = controller
        guard !shortcutsSuspended else { return }
        unavailableShortcuts = controller.register(settings.windowArrangementShortcuts)
    }

    // MARK: - 快捷鍵設定

    /// 套用新的快捷鍵對照。註冊失敗時撤回並嘗試恢復舊的；舊的也失敗才逐項標示不可用。
    @discardableResult
    func updateShortcuts(_ bindings: ShortcutBindings) -> ShortcutApplyResult {
        guard let shortcuts, !shortcutsSuspended else {
            settings.windowArrangementShortcuts = bindings
            unavailableShortcuts = []
            return .applied
        }
        let previous = settings.windowArrangementShortcuts
        let failed = shortcuts.register(bindings)
        if failed.isEmpty {
            settings.windowArrangementShortcuts = bindings
            unavailableShortcuts = []
            return .applied
        }
        let stillFailed = shortcuts.register(previous)
        unavailableShortcuts = stillFailed
        return stillFailed.isEmpty ? .rolledBack(failed: failed) : .degraded(unavailable: stillFailed)
    }

    /// 錄製快捷鍵期間暫停全域註冊，否則已綁定的組合會被自己攔走、錄不到。
    func setShortcutRecording(_ recording: Bool) {
        guard shortcutsSuspended != recording else { return }
        shortcutsSuspended = recording
        guard let shortcuts else { return }
        if recording {
            shortcuts.register(.empty)
        } else {
            unavailableShortcuts = shortcuts.register(settings.windowArrangementShortcuts)
        }
    }

    // MARK: - 忽略 App

    /// 把開選單當下的外部 App 加入排除清單，並撤掉它尚未提交的操作。
    func ignoreMenuApp() {
        guard var app = menuApp, app.bundleID != Bundle.main.bundleIdentifier else { return }
        settings.windowArrangementExcludedBundleIDs.insert(app.bundleID)
        app.isIgnored = true
        menuApp = app
        captured = nil
        capturedFrame = nil
        hideArrangementPreview()
        targetAppName = nil
        canRestoreTarget = false
        canRestoreGroup = false
        zoneSelection.end(cancelled: true)
        previewOverlay.hide()
        statusMessage = String(localized: "已忽略「\(app.name)」，不會排列它的視窗")
        ChorusLog.window.info("忽略 App：\(app.bundleID)")
    }

    func unignoreMenuApp() {
        guard let app = menuApp else { return }
        settings.windowArrangementExcludedBundleIDs.remove(app.bundleID)
        ChorusLog.window.info("恢復管理 App：\(app.bundleID)")
        captureMenuTarget()
    }

    private func currentMenuApp() -> MenuApp? {
        guard let pid = lastExternalPID,
              let running = NSRunningApplication(processIdentifier: pid),
              let bundleID = running.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier
        else { return nil }
        return MenuApp(
            name: running.localizedName ?? bundleID,
            bundleID: bundleID,
            isIgnored: settings.windowArrangementExcludedBundleIDs.contains(bundleID)
        )
    }

    func updateDragActivation() {
        guard settings.windowArrangementEnabled,
              settings.windowArrangementDragEnabled,
              lastTrusted
        else {
            stopDrag()
            return
        }
        if dragMonitor == nil {
            let monitor = DragMonitor(worker: worker)
            monitor.excludedBundleIDs = { [weak self] in self?.excludedBundleIDs() ?? [] }
            monitor.gapProvider = { [weak self] in self?.settings.windowArrangementGap ?? 8 }
            monitor.templateProvider = { [weak self] screen in
                self?.templateID(for: screen) ?? .centerStage
            }
            monitor.onPreview = { [weak self] rect, title in
                guard let self else { return }
                if let rect {
                    self.previewOverlay.show(rect: rect, title: title)
                } else {
                    self.previewOverlay.hide()
                }
            }
            monitor.onCommit = { [weak self] commit in
                self?.applyDragCommit(commit)
            }
            dragMonitor = monitor
        }
        dragMonitor?.start()
    }

    private func stopDrag() {
        dragMonitor?.stop()
        dragMonitor = nil
        previewOverlay.tearDown()
    }

    private func applyDragCommit(_ commit: DragMonitor.Commit) {
        let topology = bumpTopology()
        do {
            let before = try worker.getFrame(token: commit.token, topology: topology)
            guard let screen = topology.screen(containing: before) ?? topology.screens.first else {
                lastOutcome = .failed("找不到螢幕")
                return
            }
            let gap = settings.windowArrangementGap
            let target: LayoutRect
            if let zoneID = commit.candidate.zoneID, let templateID = commit.candidate.templateID {
                let template = LayoutTemplateCatalog.template(id: templateID)
                guard let match = template.resolvedZones(visible: screen.visibleFrame, gap: gap)
                    .first(where: { $0.0.id == zoneID })
                else {
                    lastOutcome = .failed("找不到分區")
                    return
                }
                target = match.1
            } else if let action = commit.candidate.action {
                target = engine.frame(for: action, visible: screen.visibleFrame, gap: gap, current: before)
            } else {
                return
            }
            let ref = AXWindowWorker.WindowRef(
                token: commit.token,
                pid: 0,
                bundleID: nil,
                appName: targetAppName ?? "App"
            )
            _ = applyFrame(target, ref: ref, topology: topology, screen: screen, before: before)
        } catch let error as AXWindowWorker.WorkerError {
            mapError(error)
        } catch {
            lastOutcome = .failed(error.localizedDescription)
        }
    }

    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    guard let self, self.settings.windowArrangementEnabled else { return }
                    self.lastTrusted = AXIsProcessTrusted()
                    if self.lastTrusted {
                        self.ensureShortcuts()
                        self.updateDragActivation()
                        self.retryTask?.cancel()
                        self.retryTask = nil
                    }
                }
            }
        }
    }

    private func runArrangement(
        source: Source,
        _ body: (ScreenTopology, ScreenTopology.ScreenInfo, LayoutRect, AXWindowWorker.WindowRef) -> Void
    ) {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            statusMessage = "視窗排列未啟用"
            return
        }
        guard let ref = resolveTarget(source: source) else { return }
        let topology = bumpTopology()
        do {
            let current = try worker.getFrame(token: ref.token, topology: topology)
            guard let screen = topology.screen(containing: current) ?? topology.screens.first else {
                lastOutcome = .failed("找不到螢幕")
                return
            }
            body(topology, screen, current, ref)
        } catch let error as AXWindowWorker.WorkerError {
            mapError(error)
        } catch {
            lastOutcome = .failed(error.localizedDescription)
        }
    }

    private func reportItem(
        for placement: WindowArrangement.Placement<WindowRef>,
        before: LayoutRect?,
        after: LayoutRect?,
        status: ArrangementReport.Status
    ) -> ArrangementReport.Item {
        ArrangementReport.Item(
            token: placement.window.token,
            appName: placement.window.appName,
            target: placement.frame,
            before: before,
            after: after,
            status: status
        )
    }

    /// 寫入一個視窗；逾時時只嘗試一次回復，不改動任何 manager 呈現狀態。
    private func writeFrame(
        _ target: LayoutRect,
        ref: WindowRef,
        topology: ScreenTopology,
        before: LayoutRect
    ) -> (status: ArrangementReport.Status, after: LayoutRect?) {
        switch worker.setFrame(token: ref.token, frame: target, topology: topology) {
        case .applied(_, let after):
            return (.applied, after)
        case .constrained(_, let after):
            return (.constrained, after)
        case .failed(.timeout):
            let revertResult = worker.setFrame(token: ref.token, frame: before, topology: topology)
            let after = try? worker.getFrame(token: ref.token, topology: topology)
            switch revertResult {
            case .applied, .constrained:
                if let after, framesMatch(after, before) {
                    return (.reverted(reason: ArrangementReport.timeoutReason), after)
                }
                return (.revertFailed(reason: ArrangementReport.timeoutReason), after)
            case .failed:
                return (.revertFailed(reason: ArrangementReport.timeoutReason), after)
            }
        case .failed(let error):
            return (.failed(reason: reportReason(for: error)), nil)
        }
    }

    private func reportReason(for error: WorkerError) -> String {
        switch error {
        case .permissionRequired: Self.permissionReason
        case .targetGone: Self.targetGoneReason
        case .timeout: ArrangementReport.timeoutReason
        case .unsupported: "unsupported"
        case .noTarget: "noTarget"
        }
    }

    private func publish(_ report: ArrangementReport) {
        lastReport = report
        let primaryToken = report.items.first?.token
        canRestoreTarget = primaryToken.flatMap { restore.entry(for: $0) } != nil
        canRestoreGroup = (primaryToken
            .flatMap { restore.group(containing: $0) }?
            .tokens.count ?? 0) >= 2
        lastOutcome = report.outcome
        statusMessage = report.summaryText
    }

    private func applyFrame(
        _ target: LayoutRect,
        ref: AXWindowWorker.WindowRef,
        topology: ScreenTopology,
        screen: ScreenTopology.ScreenInfo,
        before: LayoutRect
    ) -> Outcome {
        restore.rememberOriginalIfNeeded(
            token: ref.token,
            original: before,
            displayUUID: screen.displayUUID,
            topologyGeneration: topology.generation
        )
        switch worker.setFrame(token: ref.token, frame: target, topology: topology) {
        case .applied:
            lastOutcome = .applied
            statusMessage = nil
            if ref.token == captured?.token { canRestoreTarget = true }
            return .applied
        case .constrained:
            if ref.token == captured?.token { canRestoreTarget = true }
            lastOutcome = .constrained
            statusMessage = String(localized: "此 App 的最小尺寸超過所選區域")
            return .constrained
        case .failed(let error):
            mapError(error)
            return lastOutcome ?? .unsupported
        }
    }

    private func resolveTarget(source: Source) -> AXWindowWorker.WindowRef? {
        // 選單捕捉的視窗只給選單用；快捷鍵若沿用它，會排到上次開選單時的那個視窗
        if source == .menu, let captured {
            targetAppName = captured.appName
            return captured
        }
        do {
            let ref: AXWindowWorker.WindowRef
            do {
                ref = try worker.focusedExternalWindow(excludingBundleIDs: excludedBundleIDs())
            } catch AXWindowWorker.WorkerError.noTarget {
                // 前景是 Chorus 自己（面板或設定開著）時，退回最後一個外部 App
                guard let pid = lastExternalPID else { throw AXWindowWorker.WorkerError.noTarget }
                ref = try worker.windowForApplication(pid: pid, excludingBundleIDs: excludedBundleIDs())
            }
            if source == .menu { targetAppName = ref.appName }
            return ref
        } catch let error as AXWindowWorker.WorkerError {
            mapError(error)
            return nil
        } catch {
            lastOutcome = .noTarget
            statusMessage = "沒有可排列的視窗"
            return nil
        }
    }

    private func reportNoZoneTemplates() {
        lastOutcome = .unsupported
        statusMessage = String(localized: "直立螢幕沒有分區版型")
    }

    private func excludedBundleIDs() -> Set<String> {
        var ids = settings.windowArrangementExcludedBundleIDs
        if let own = Bundle.main.bundleIdentifier {
            ids.insert(own)
        }
        return ids
    }

    private func bumpTopology() -> ScreenTopology {
        topologyGeneration &+= 1
        return captureTopology(topologyGeneration)
    }

    private func clamp(_ rect: LayoutRect, to visible: LayoutRect) -> LayoutRect {
        var r = rect
        r.width = min(r.width, visible.width)
        r.height = min(r.height, visible.height)
        r.x = min(max(r.x, visible.x), visible.maxX - r.width)
        r.y = min(max(r.y, visible.y), visible.maxY - r.height)
        return r
    }

    private func framesMatch(_ lhs: LayoutRect, _ rhs: LayoutRect, tolerance: Double = 2) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func mapError(_ error: AXWindowWorker.WorkerError) {
        ChorusLog.window.info("排列未完成：\(error)")
        switch error {
        case .permissionRequired:
            lastTrusted = false
            lastOutcome = .permissionRequired
            statusMessage = String(localized: "需要輔助使用權限")
        case .noTarget:
            lastOutcome = .noTarget
            statusMessage = String(localized: "沒有可排列的視窗")
        case .unsupported:
            lastOutcome = .unsupported
            statusMessage = String(localized: "此視窗不支援排列")
        case .timeout:
            lastOutcome = .failed(String(localized: "逾時"))
            statusMessage = String(localized: "操作逾時")
        case .targetGone:
            lastOutcome = .targetGone
            statusMessage = String(localized: "目標視窗已關閉")
            captured = nil
            capturedFrame = nil
        }
    }
}
