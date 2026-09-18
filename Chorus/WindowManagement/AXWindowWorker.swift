import AppKit
import ApplicationServices
import ChorusCore
import Foundation

/// 專用序列佇列上的 AX 視窗讀寫；對外只回傳 Sendable 值與 opaque token。
final class AXWindowWorker: @unchecked Sendable {
    struct WindowRef: Sendable, Equatable {
        var token: String
        var pid: pid_t
        var bundleID: String?
        var appName: String
    }

    enum WorkerError: Error, Sendable, Equatable {
        case permissionRequired
        case noTarget
        case unsupported
        case timeout
        case targetGone
    }

    enum SetResult: Sendable, Equatable {
        case applied(before: LayoutRect, after: LayoutRect)
        case constrained(before: LayoutRect, after: LayoutRect)
        case failed(WorkerError)
    }

    private let queue = DispatchQueue(label: "com.hermes.Chorus.window.ax", qos: .userInitiated)
    private var elements: [String: AXUIElement] = [:]
    private let timeout: CFTimeInterval

    init(timeout: CFTimeInterval = 1.5) {
        self.timeout = timeout
    }

    func focusedExternalWindow(excludingBundleIDs: Set<String>) throws -> WindowRef {
        try sync {
            guard AXIsProcessTrusted() else { throw WorkerError.permissionRequired }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, Float(self.timeout))

            var focusedAppRef: CFTypeRef?
            let appStatus = AXUIElementCopyAttributeValue(
                system,
                kAXFocusedApplicationAttribute as CFString,
                &focusedAppRef
            )
            guard appStatus == .success, let focusedAppRef,
                  CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID()
            else { throw WorkerError.noTarget }
            let app = unsafeBitCast(focusedAppRef, to: AXUIElement.self)

            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            return try self.makeRef(app: app, pid: pid, excludingBundleIDs: excludingBundleIDs)
        }
    }

    /// 指定行程的聚焦視窗（選單開啟後系統焦點已在 Chorus 時使用）。
    func windowForApplication(pid: pid_t, excludingBundleIDs: Set<String>) throws -> WindowRef {
        try sync {
            guard AXIsProcessTrusted() else { throw WorkerError.permissionRequired }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Float(self.timeout))
            return try self.makeRef(app: app, pid: pid, excludingBundleIDs: excludingBundleIDs)
        }
    }

    private func makeRef(app: AXUIElement, pid: pid_t, excludingBundleIDs: Set<String>) throws -> WindowRef {
        let running = NSRunningApplication(processIdentifier: pid)
        let bundleID = running?.bundleIdentifier
        if let bundleID, excludingBundleIDs.contains(bundleID) {
            throw WorkerError.noTarget
        }
        if pid == ProcessInfo.processInfo.processIdentifier {
            throw WorkerError.noTarget
        }

        var windowRef: CFTypeRef?
        let winStatus = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        guard winStatus == .success, let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { throw WorkerError.noTarget }
        let window = unsafeBitCast(windowRef, to: AXUIElement.self)

        if isMinimized(window) || isFullScreen(window) {
            throw WorkerError.unsupported
        }

        let token = "\(pid):\(CFHash(window))"
        elements[token] = window
        return WindowRef(
            token: token,
            pid: pid,
            bundleID: bundleID,
            appName: running?.localizedName ?? "App"
        )
    }

    func getFrame(token: String, topology: ScreenTopology) throws -> LayoutRect {
        try sync {
            guard let window = self.elements[token] else { throw WorkerError.targetGone }
            return try self.readFrame(window, topology: topology)
        }
    }

    func setFrame(token: String, frame: LayoutRect, topology: ScreenTopology) -> SetResult {
        do {
            return try sync {
                guard let window = self.elements[token] else {
                    return .failed(.targetGone)
                }
                let before = try self.readFrame(window, topology: topology)
                guard self.isSettable(window) else {
                    return .failed(.unsupported)
                }
                let ax = topology.toAX(frame)
                guard let posValue = axValue(.cgPoint, ax.origin),
                      let sizeValue = axValue(.cgSize, ax.size)
                else {
                    return .failed(.unsupported)
                }
                let sizeStatus = AXUIElementSetAttributeValue(
                    window, kAXSizeAttribute as CFString, sizeValue
                )
                let posStatus = AXUIElementSetAttributeValue(
                    window, kAXPositionAttribute as CFString, posValue
                )
                if sizeStatus != .success && posStatus != .success {
                    return .failed(.unsupported)
                }
                // 第一次設大小時視窗還在原螢幕，系統會用那台的尺寸夾住；
                // 搬過去之後再設一次，跨螢幕（小→大）才拿得到完整尺寸
                _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                let after = try self.readFrame(window, topology: topology)
                let tolerance = 2.0
                let matched =
                    abs(after.x - frame.x) <= tolerance
                    && abs(after.y - frame.y) <= tolerance
                    && abs(after.width - frame.width) <= tolerance
                    && abs(after.height - frame.height) <= tolerance
                return matched
                    ? .applied(before: before, after: after)
                    : .constrained(before: before, after: after)
            }
        } catch let error as WorkerError {
            return .failed(error)
        } catch {
            return .failed(.unsupported)
        }
    }

    func forget(token: String) {
        queue.sync { elements.removeValue(forKey: token) }
    }

    // MARK: - Private

    private func sync<T>(_ body: () throws -> T) throws -> T {
        try queue.sync { try body() }
    }

    private func readFrame(_ window: AXUIElement, topology: ScreenTopology) throws -> LayoutRect {
        AXUIElementSetMessagingTimeout(window, Float(timeout))
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef
        else { throw WorkerError.unsupported }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let posValue = unsafeBitCast(posRef, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeRef, to: AXValue.self)
        guard AXValueGetValue(posValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { throw WorkerError.unsupported }
        return topology.fromAX(origin: origin, size: size)
    }

    private func isSettable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let posOK = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success
            && settable.boolValue
        settable = false
        let sizeOK = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
        return posOK && sizeOK
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFBooleanGetTypeID()
        else { return false }
        return CFBooleanGetValue(unsafeBitCast(ref, to: CFBoolean.self))
    }

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        let attr = "AXFullScreen" as CFString
        guard AXUIElementCopyAttributeValue(window, attr, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFBooleanGetTypeID()
        else { return false }
        return CFBooleanGetValue(unsafeBitCast(ref, to: CFBoolean.self))
    }

    private func axValue<T>(_ type: AXValueType, _ value: T) -> AXValue? {
        var copy = value
        return AXValueCreate(type, &copy)
    }
}
