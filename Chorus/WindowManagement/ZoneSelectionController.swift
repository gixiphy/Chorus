import AppKit
import ChorusCore

/// 鍵盤選區：顯示目前螢幕版型分區，方向鍵移動、Enter 套用、Esc 取消。
@MainActor
final class ZoneSelectionController {
    var onApply: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var navigator: ZoneNavigator?
    private var resolved: [(LayoutZone, LayoutRect)] = []
    private var panels: [String: NSPanel] = [:]
    private var keyMonitor: Any?
    private var localMonitor: Any?
    private var active = false

    var isActive: Bool { active }

    func begin(template: LayoutTemplate, visible: LayoutRect, gap: Double) {
        end(cancelled: true)
        resolved = template.resolvedZones(visible: visible, gap: gap)
        guard !resolved.isEmpty else { return }
        navigator = ZoneNavigator(zones: resolved.map(\.0))
        active = true
        rebuildPanels()
        installKeys()
    }

    func end(cancelled: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        keyMonitor = nil
        localMonitor = nil
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        navigator = nil
        resolved = []
        let wasActive = active
        active = false
        if wasActive, cancelled { onCancel?() }
    }

    private func installKeys() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated {
                consumed = self?.handleKey(event) == true
            }
            return consumed ? nil : event
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleKey(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        guard active else { return false }
        switch event.keyCode {
        case 123: // left
            navigator?.move(.left)
            rebuildPanels()
            return true
        case 124: // right
            navigator?.move(.right)
            rebuildPanels()
            return true
        case 126: // up
            navigator?.move(.up)
            rebuildPanels()
            return true
        case 125: // down
            navigator?.move(.down)
            rebuildPanels()
            return true
        case 36: // return
            if let id = navigator?.focusedID {
                let apply = onApply
                end(cancelled: false)
                apply?(id)
            }
            return true
        case 53: // escape
            end(cancelled: true)
            return true
        default:
            return false
        }
    }

    private func rebuildPanels() {
        let focused = navigator?.focusedID
        var seen = Set<String>()
        for (zone, rect) in resolved {
            seen.insert(zone.id)
            let panel = panels[zone.id] ?? makePanel()
            panels[zone.id] = panel
            let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            panel.setFrame(frame, display: true)
            if let box = panel.contentView {
                box.layer?.backgroundColor = (zone.id == focused
                    ? NSColor.systemBlue.withAlphaComponent(0.28)
                    : NSColor.systemBlue.withAlphaComponent(0.10)).cgColor
                box.layer?.borderWidth = zone.id == focused ? 3 : 1
            }
            panel.orderFrontRegardless()
        }
        for id in panels.keys where !seen.contains(id) {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        let box = NSView(frame: .zero)
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        box.layer?.cornerRadius = 6
        box.autoresizingMask = [.width, .height]
        panel.contentView = box
        return panel
    }
}
