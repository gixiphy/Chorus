import AppKit
import ApplicationServices
import ChorusCore
import Observation

/// 視窗排列協調器：選單／快捷鍵（M1）與拖曳吸附（M2）。
@MainActor
@Observable
final class WindowManager {
    enum Outcome: Equatable {
        case applied
        case constrained
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
    /// 註冊失敗、目前按了沒反應的快捷鍵。
    private(set) var unavailableShortcuts: Set<WindowCommand> = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let worker = AXWindowWorker()
    @ObservationIgnored private let engine = LayoutEngine()
    @ObservationIgnored private var restore = RestoreStore()
    @ObservationIgnored private var captured: AXWindowWorker.WindowRef?
    @ObservationIgnored private var topologyGeneration: UInt64 = 0
    @ObservationIgnored private var shortcuts: WindowShortcutController?
    @ObservationIgnored private var dragMonitor: DragMonitor?
    @ObservationIgnored private let previewOverlay = PreviewOverlay()
    @ObservationIgnored private let zoneSelection = ZoneSelectionController()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastExternalPID: pid_t?
    @ObservationIgnored private var shortcutsSuspended = false

    init(settings: SettingsStore) {
        self.settings = settings
        startFrontmostTracking()
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
        canRestoreTarget = false
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
            let topology = bumpTopology()
            targetDisplayUUID = (try? worker.getFrame(token: ref.token, topology: topology))
                .flatMap { topology.screen(containing: $0)?.displayUUID }
            statusMessage = nil
        } catch AXWindowWorker.WorkerError.permissionRequired {
            lastTrusted = false
            lastOutcome = .permissionRequired
            statusMessage = "需要輔助使用權限"
            targetAppName = nil
        } catch {
            captured = nil
            targetAppName = nil
            statusMessage = "沒有可排列的視窗"
        }
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
        case .selectZone:
            beginKeyboardZoneSelection(source: source)
        default:
            if let action = command.layoutAction {
                apply(action, source: source)
            } else if let arrangement = command.arrangement {
                arrange(arrangement, source: source)
            }
        }
    }

    /// 一次排多個視窗：目標視窗放第一格，同螢幕其餘視窗依由前到後的順序填入。
    /// 視窗不夠就只排現有的；每個視窗各自記住原位，之後可逐一還原。
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
                let plan = arrangement.plan(
                    windows: [ref] + others,
                    visible: screen.visibleFrame,
                    gap: settings.windowArrangementGap
                )
                var constrained = false
                for placement in plan {
                    let before = placement.window.token == ref.token
                        ? current
                        : try worker.getFrame(token: placement.window.token, topology: topology)
                    let outcome = applyFrame(
                        placement.frame, ref: placement.window,
                        topology: topology, screen: screen, before: before
                    )
                    if outcome == .constrained { constrained = true }
                }
                // 主要視窗最後一個被其他視窗蓋過狀態，這裡收一個總結
                if plan.count < arrangement.slotCount {
                    lastOutcome = .applied
                    statusMessage = String(localized: "這台螢幕只有 \(plan.count) 個可排列的視窗，其餘位置留空")
                } else if constrained {
                    lastOutcome = .constrained
                    statusMessage = "此 App 的最小尺寸超過所選區域"
                }
                ChorusLog.window.info("多視窗排列 \(arrangement.rawValue)：\(plan.count)/\(arrangement.slotCount) 個視窗")
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
            guard screen.isUltrawide else {
                reportNotUltrawide()
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

    func restoreLast(source: Source = .menu) {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            return
        }
        guard let ref = resolveTarget(source: source) else { return }
        let topology = bumpTopology()
        guard let entry = restore.consume(token: ref.token) else {
            lastOutcome = .failed("沒有可還原的位置")
            statusMessage = "沒有可還原的位置"
            return
        }
        var frame = entry.original
        if let screen = topology.screen(uuid: entry.displayUUID) ?? topology.screen(containing: frame) {
            frame = clamp(frame, to: screen.visibleFrame)
        }
        switch worker.setFrame(token: ref.token, frame: frame, topology: topology) {
        case .applied, .constrained:
            lastOutcome = .restored
            statusMessage = "已還原"
            if ref.token == captured?.token { canRestoreTarget = false }
        case .failed(let error):
            mapError(error)
        }
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
        guard screen.isUltrawide else {
            reportNotUltrawide()
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
        targetAppName = nil
        canRestoreTarget = false
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
            statusMessage = "此 App 的最小尺寸超過所選區域"
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

    private func reportNotUltrawide() {
        lastOutcome = .unsupported
        statusMessage = String(localized: "這台螢幕不是超寬比例，沒有分區版型")
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
        return ScreenTopology.capture(generation: topologyGeneration)
    }

    private func clamp(_ rect: LayoutRect, to visible: LayoutRect) -> LayoutRect {
        var r = rect
        r.width = min(r.width, visible.width)
        r.height = min(r.height, visible.height)
        r.x = min(max(r.x, visible.x), visible.maxX - r.width)
        r.y = min(max(r.y, visible.y), visible.maxY - r.height)
        return r
    }

    private func mapError(_ error: AXWindowWorker.WorkerError) {
        ChorusLog.window.info("排列未完成：\(error)")
        switch error {
        case .permissionRequired:
            lastTrusted = false
            lastOutcome = .permissionRequired
            statusMessage = "需要輔助使用權限"
        case .noTarget:
            lastOutcome = .noTarget
            statusMessage = "沒有可排列的視窗"
        case .unsupported:
            lastOutcome = .unsupported
            statusMessage = "此視窗不支援排列"
        case .timeout:
            lastOutcome = .failed("逾時")
            statusMessage = "操作逾時"
        case .targetGone:
            lastOutcome = .targetGone
            statusMessage = "目標視窗已關閉"
            captured = nil
        }
    }
}
