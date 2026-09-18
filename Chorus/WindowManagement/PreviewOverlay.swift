import AppKit
import ChorusCore

/// 不搶焦點、穿透滑鼠的吸附預覽框。
@MainActor
final class PreviewOverlay {
    private var panel: NSPanel?
    private var label: NSTextField?

    func show(rect: LayoutRect, title: String?) {
        let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        if panel == nil {
            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false

            let box = NSView(frame: panel.contentView?.bounds ?? frame)
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
            box.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
            box.layer?.borderWidth = 2
            box.layer?.cornerRadius = 6
            box.autoresizingMask = [.width, .height]
            panel.contentView = box

            let label = NSTextField(labelWithString: "")
            label.textColor = .white
            label.backgroundColor = NSColor.black.withAlphaComponent(0.45)
            label.isBezeled = false
            label.drawsBackground = true
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.alignment = .center
            label.frame = NSRect(x: 8, y: frame.height - 28, width: max(40, frame.width - 16), height: 20)
            label.autoresizingMask = [.width, .minYMargin]
            box.addSubview(label)
            self.label = label
            self.panel = panel
        }

        panel?.setFrame(frame, display: true)
        label?.stringValue = title ?? ""
        label?.isHidden = title == nil || title?.isEmpty == true
        if let label, let bounds = panel?.contentView?.bounds {
            label.frame = NSRect(x: 8, y: bounds.height - 28, width: max(40, bounds.width - 16), height: 20)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func tearDown() {
        hide()
        panel = nil
        label = nil
    }
}
