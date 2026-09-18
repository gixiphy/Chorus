import AppKit
import ChorusCore

/// M1 預設全域快捷鍵：⌃⌥＋方向鍵／Return／C／Z。
@MainActor
final class WindowShortcutController {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onAction: (LayoutAction) -> Void
    private let onRestore: () -> Void

    init(onAction: @escaping (LayoutAction) -> Void, onRestore: @escaping () -> Void) {
        self.onAction = onAction
        self.onRestore = onRestore
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                _ = self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated {
                consumed = self?.handle(event) == true
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chord: NSEvent.ModifierFlags = [.control, .option]
        guard flags == chord else { return false }

        switch event.keyCode {
        case 123:
            onAction(.leftHalf)
            return true
        case 124:
            onAction(.rightHalf)
            return true
        case 126:
            onAction(.topHalf)
            return true
        case 125:
            onAction(.bottomHalf)
            return true
        case 36:
            onAction(.maximize)
            return true
        case 8:
            onAction(.centerPreserveSize)
            return true
        case 6:
            onRestore()
            return true
        default:
            return false
        }
    }
}
