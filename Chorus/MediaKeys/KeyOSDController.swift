import AppKit
import SwiftUI

/// 媒體鍵接管後的自繪 OSD：接管的按鍵 macOS 不會再畫原生 OSD，
/// 這裡補一個同樣位置（滑鼠所在螢幕下方置中）、同刻度（16 格）的版本，
/// 並多顯示目標裝置名稱——螢幕喇叭 vs 內建喇叭要分得清。
@MainActor
final class KeyOSDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private static let size = CGSize(width: 190, height: 190)
    private static let bottomMargin: CGFloat = 120

    func show(icon: String, level: Double?, title: String) {
        let screen = Self.screenUnderMouse()
        let origin = CGPoint(
            x: screen.frame.midX - Self.size.width / 2,
            y: screen.frame.minY + Self.bottomMargin
        )
        let panel = ensurePanel()
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        panel.contentView = NSHostingView(rootView: KeyOSDView(icon: icon, level: level, title: title))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.level = .screenSaver
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.ignoresMouseEvents = true
        panel = created
        return created
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            panel.animator().alphaValue = 0
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private struct KeyOSDView: View {
    let icon: String
    let level: Double?
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.primary.opacity(0.85))
            Spacer()
            VStack(spacing: 8) {
                if let level {
                    SegmentBar(level: level)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(18)
        .frame(width: 190, height: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// 16 格量條，與 macOS 原生 OSD 同刻度。
private struct SegmentBar: View {
    let level: Double

    var body: some View {
        let filled = Int((level * 16).rounded())
        HStack(spacing: 2) {
            ForEach(0..<16, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.primary.opacity(0.18)))
                    .frame(height: 6)
            }
        }
        .clipShape(Capsule())
    }
}
