import AppKit
import ApplicationServices
import ChorusCore

/// 監聽視窗拖曳，驅動 SnapDragSession 與預覽；放開時回呼提交候選。
@MainActor
final class DragMonitor {
    struct Commit {
        var candidate: SnapResolver.Candidate
        var token: String
    }

    var onCommit: ((Commit) -> Void)?
    var onPreview: ((LayoutRect?, String?) -> Void)?
    var templateProvider: ((ScreenTopology.ScreenInfo) -> LayoutTemplateID)?
    var gapProvider: (() -> Double)?
    var excludedBundleIDs: (() -> Set<String>)?

    private let worker: AXWindowWorker
    private var session = SnapDragSession()
    private var monitors: [Any] = []
    private var dragToken: String?
    private var dragStartFrame: LayoutRect?
    private var mouseDownPoint: CGPoint?
    private var recognizedDrag = false
    private var topologyGeneration: UInt64 = 0
    private var startedAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let moveThreshold: CGFloat = 4

    init(worker: AXWindowWorker) {
        self.worker = worker
    }

    func start() {
        guard monitors.isEmpty else { return }
        guard AXIsProcessTrusted() else { return }

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        resetDrag()
        onPreview?(nil, nil)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDown()
        case .leftMouseDragged:
            mouseDragged()
        case .leftMouseUp:
            mouseUp(modifiers: event.modifierFlags)
        case .flagsChanged:
            if recognizedDrag {
                pointerMoved(screenPoint: NSEvent.mouseLocation, modifiers: event.modifierFlags)
            }
        case .keyDown:
            if event.keyCode == 53, recognizedDrag {
                session.cancel()
                onPreview?(nil, nil)
            }
        default:
            break
        }
    }

    private func mouseDown() {
        resetDrag()
        mouseDownPoint = NSEvent.mouseLocation
        do {
            let excluded = excludedBundleIDs?() ?? []
            let ref = try worker.focusedExternalWindow(excludingBundleIDs: excluded)
            let topology = bumpTopology()
            let frame = try worker.getFrame(token: ref.token, topology: topology)
            dragToken = ref.token
            dragStartFrame = frame
        } catch {
            dragToken = nil
            dragStartFrame = nil
        }
    }

    private func mouseDragged() {
        let point = NSEvent.mouseLocation
        guard let down = mouseDownPoint, let token = dragToken, let start = dragStartFrame else { return }

        if !recognizedDrag {
            let dx = abs(point.x - down.x)
            let dy = abs(point.y - down.y)
            guard dx >= moveThreshold || dy >= moveThreshold else { return }
            let topology = bumpTopology()
            guard let current = try? worker.getFrame(token: token, topology: topology) else { return }
            let sizeDelta = abs(current.width - start.width) + abs(current.height - start.height)
            let posDelta = abs(current.x - start.x) + abs(current.y - start.y)
            guard posDelta >= 3, sizeDelta < 6 else { return }
            recognizedDrag = true
            startedAt = clock.now
            session.beginDrag(at: .zero)
        }

        pointerMoved(screenPoint: point, modifiers: NSEvent.modifierFlags)
    }

    private func mouseUp(modifiers: NSEvent.ModifierFlags) {
        defer {
            onPreview?(nil, nil)
            resetDrag()
        }
        guard recognizedDrag, let token = dragToken else { return }
        pointerMoved(screenPoint: NSEvent.mouseLocation, modifiers: modifiers)
        let shift = modifiers.contains(.shift)
        if let candidate = session.mouseUp(now: elapsed(), shiftDown: shift) {
            onCommit?(Commit(candidate: candidate, token: token))
        }
    }

    private func pointerMoved(screenPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard recognizedDrag else { return }
        let topology = bumpTopology()
        let shift = modifiers.contains(.shift)
        let x = Double(screenPoint.x)
        let y = Double(screenPoint.y)
        guard let screenInfo = topology.screen(containingPointX: x, y: y) else {
            onPreview?(nil, nil)
            return
        }

        let edge = SnapResolver.ScreenMetrics(frame: screenInfo.frame, isLandscape: screenInfo.isLandscape)
        var zoneContext: SnapDragSession.ZoneContext?
        if shift, screenInfo.isUltrawide {
            let templateID = templateProvider?(screenInfo) ?? .centerStage
            zoneContext = SnapDragSession.ZoneContext(
                template: LayoutTemplateCatalog.template(id: templateID),
                visible: screenInfo.visibleFrame,
                gap: gapProvider?() ?? 8
            )
        }

        let update = session.updatePointer(
            x: x,
            y: y,
            shiftDown: shift,
            now: elapsed(),
            edgeScreen: edge,
            zoneContext: zoneContext
        )

        guard let candidate = update.preview else {
            onPreview?(nil, nil)
            return
        }

        let gap = gapProvider?() ?? 8
        let engine = LayoutEngine()
        if let zoneID = candidate.zoneID, let templateID = candidate.templateID {
            let template = LayoutTemplateCatalog.template(id: templateID)
            if let match = template.resolvedZones(visible: screenInfo.visibleFrame, gap: gap)
                .first(where: { $0.0.id == zoneID }) {
                onPreview?(match.1, previewTitle(for: match.0))
            } else {
                onPreview?(nil, nil)
            }
        } else if let action = candidate.action {
            let rect = engine.frame(for: action, visible: screenInfo.visibleFrame, gap: gap)
            onPreview?(rect, previewTitle(for: action))
        } else {
            onPreview?(nil, nil)
        }
    }

    private func previewTitle(for zone: LayoutZone) -> String {
        switch zone.id {
        case "left": return "左"
        case "center": return "中央主區"
        case "right": return "右"
        case "primary": return "主區"
        case "side": return "側欄"
        case "sideTop": return "上側窗"
        case "sideBottom": return "下側窗"
        case "reading": return "中央閱讀"
        case "col1": return "第 1 欄"
        case "col2": return "第 2 欄"
        case "col3": return "第 3 欄"
        case "col4": return "第 4 欄"
        default: return zone.id
        }
    }

    private func previewTitle(for action: LayoutAction) -> String {
        switch action {
        case .leftHalf: return "左半"
        case .rightHalf: return "右半"
        case .topHalf: return "上半"
        case .bottomHalf: return "下半"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .leftThird: return "左 1/3"
        case .centerThird: return "中 1/3"
        case .rightThird: return "右 1/3"
        case .leftTwoThirds: return "左 2/3"
        case .centerTwoThirds: return "中 2/3"
        case .rightTwoThirds: return "右 2/3"
        case .maximize: return "填滿"
        default: return action.rawValue
        }
    }

    private func elapsed() -> Duration {
        guard let startedAt else { return .zero }
        return clock.now - startedAt
    }

    private func bumpTopology() -> ScreenTopology {
        topologyGeneration &+= 1
        return ScreenTopology.capture(generation: topologyGeneration)
    }

    private func resetDrag() {
        session.endDrag()
        dragToken = nil
        dragStartFrame = nil
        mouseDownPoint = nil
        recognizedDrag = false
        startedAt = nil
    }
}
