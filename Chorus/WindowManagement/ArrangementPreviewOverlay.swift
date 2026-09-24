import AppKit

/// 不搶焦點、穿透滑鼠的批次排列預覽；面板依位置索引重用。
@MainActor
final class ArrangementPreviewOverlay {
    private struct SlotPanel {
        let panel: NSPanel
        let label: NSTextField
        let dashedBorder: CAShapeLayer
    }

    private var slots: [SlotPanel] = []

    func show(_ preview: ArrangementPreview) {
        while slots.count < preview.slots.count {
            slots.append(makeSlotPanel())
        }

        for (index, slot) in preview.slots.enumerated() {
            let item = slots[index]
            let frame = NSRect(
                x: slot.frame.x,
                y: slot.frame.y,
                width: slot.frame.width,
                height: slot.frame.height
            )
            item.panel.setFrame(frame, display: true)
            update(item, for: slot)
            item.panel.orderFrontRegardless()
        }

        for index in preview.slots.count..<slots.count {
            slots[index].panel.orderOut(nil)
        }
    }

    func hide() {
        for slot in slots {
            slot.panel.orderOut(nil)
        }
    }

    func tearDown() {
        hide()
        slots.removeAll()
    }

    private func update(_ item: SlotPanel, for slot: ArrangementPreview.Slot) {
        guard let box = item.panel.contentView else { return }
        let isEmpty = slot.appName == nil

        box.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(
            isEmpty ? 0.06 : (slot.isPrimary ? 0.28 : 0.12)
        ).cgColor
        box.layer?.borderWidth = isEmpty ? 0 : (slot.isPrimary ? 3 : 1)

        item.dashedBorder.isHidden = !isEmpty
        item.dashedBorder.frame = box.bounds
        item.dashedBorder.path = CGPath(
            roundedRect: box.bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )

        item.label.stringValue = slot.appName ?? ""
        item.label.isHidden = isEmpty
        item.label.frame = NSRect(
            x: 8,
            y: box.bounds.height - 28,
            width: max(40, box.bounds.width - 16),
            height: 20
        )
    }

    private func makeSlotPanel() -> SlotPanel {
        let panel = NSPanel(
            contentRect: .zero,
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

        let box = NSView(frame: .zero)
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        box.layer?.cornerRadius = 6
        box.autoresizingMask = [.width, .height]
        panel.contentView = box

        let dashedBorder = CAShapeLayer()
        dashedBorder.fillColor = NSColor.clear.cgColor
        dashedBorder.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        dashedBorder.lineWidth = 1
        dashedBorder.lineDashPattern = [6, 4]
        box.layer?.addSublayer(dashedBorder)

        let label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        label.isBezeled = false
        label.drawsBackground = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.autoresizingMask = [.width, .minYMargin]
        box.addSubview(label)

        return SlotPanel(panel: panel, label: label, dashedBorder: dashedBorder)
    }
}
