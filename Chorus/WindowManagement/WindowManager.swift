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

    private(set) var lastTrusted = false
    private(set) var targetAppName: String?
    private(set) var lastOutcome: Outcome?
    private(set) var statusMessage: String?

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

    func apply(_ action: LayoutAction) {
        runArrangement { topology, screen, current, ref in
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
        runArrangement { topology, screen, current, ref in
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

    func restoreLast() {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            return
        }
        guard let ref = resolveTarget() else { return }
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
        case .failed(let error):
            mapError(error)
        }
    }

    func moveToAdjacentDisplay(delta: Int) {
        runArrangement { topology, screen, current, ref in
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
    func beginKeyboardZoneSelection() {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            return
        }
        captureMenuTarget()
        let topology = bumpTopology()
        let point = NSEvent.mouseLocation
        guard let screen = topology.screen(containingPointX: Double(point.x), y: Double(point.y))
                ?? topology.screens.first
        else {
            statusMessage = "找不到螢幕"
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
        if shortcuts == nil {
            let controller = WindowShortcutController { [weak self] action in
                self?.apply(action)
            } onRestore: { [weak self] in
                self?.restoreLast()
            }
            shortcuts = controller
        }
        shortcuts?.start()
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
        _ body: (ScreenTopology, ScreenTopology.ScreenInfo, LayoutRect, AXWindowWorker.WindowRef) -> Void
    ) {
        guard settings.windowArrangementEnabled else {
            lastOutcome = .disabled
            statusMessage = "視窗排列未啟用"
            return
        }
        guard let ref = resolveTarget() else { return }
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
            return .applied
        case .constrained:
            lastOutcome = .constrained
            statusMessage = "此 App 的最小尺寸超過所選區域"
            return .constrained
        case .failed(let error):
            mapError(error)
            return lastOutcome ?? .unsupported
        }
    }

    private func resolveTarget() -> AXWindowWorker.WindowRef? {
        if let captured {
            targetAppName = captured.appName
            return captured
        }
        do {
            let ref = try worker.focusedExternalWindow(excludingBundleIDs: excludedBundleIDs())
            targetAppName = ref.appName
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
