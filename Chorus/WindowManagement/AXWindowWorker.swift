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

    /// 游標下的視窗（拖曳吸附用）。按下滑鼠的當下焦點還沒換過去，拖的若是背景視窗，
    /// 問「聚焦視窗」會拿到別人；所以直接問該座標上的元素，再往上找它所屬的視窗。
    func window(atX x: Double, y: Double, topology: ScreenTopology, excludingBundleIDs: Set<String>) throws -> WindowRef {
        try sync {
            guard AXIsProcessTrusted() else { throw WorkerError.permissionRequired }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, Float(self.timeout))

            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(
                system, Float(x), Float(topology.primaryHeight - y), &hit
            )
            guard status == .success, let hit else { throw WorkerError.noTarget }

            var pid: pid_t = 0
            AXUIElementGetPid(hit, &pid)
            try self.checkManageable(pid: pid, excludingBundleIDs: excludingBundleIDs)
            return try self.makeRef(window: self.owningWindow(of: hit), pid: pid)
        }
    }

    private func owningWindow(of element: AXUIElement) throws -> AXUIElement {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           (roleRef as? String) == (kAXWindowRole as String) {
            return element
        }
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { throw WorkerError.noTarget }
        return unsafeBitCast(windowRef, to: AXUIElement.self)
    }

    private func checkManageable(pid: pid_t, excludingBundleIDs: Set<String>) throws {
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           excludingBundleIDs.contains(bundleID) {
            throw WorkerError.noTarget
        }
        if pid == ProcessInfo.processInfo.processIdentifier {
            throw WorkerError.noTarget
        }
    }

    private func makeRef(app: AXUIElement, pid: pid_t, excludingBundleIDs: Set<String>) throws -> WindowRef {
        try checkManageable(pid: pid, excludingBundleIDs: excludingBundleIDs)

        var windowRef: CFTypeRef?
        let winStatus = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        guard winStatus == .success, let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { throw WorkerError.noTarget }
        return try makeRef(window: unsafeBitCast(windowRef, to: AXUIElement.self), pid: pid)
    }

    private func makeRef(window: AXUIElement, pid: pid_t) throws -> WindowRef {
        let running = NSRunningApplication(processIdentifier: pid)

        if isMinimized(window) || isFullScreen(window) {
            throw WorkerError.unsupported
        }

        let token = "\(pid):\(CFHash(window))"
        elements[token] = window
        return WindowRef(
            token: token,
            pid: pid,
            bundleID: running?.bundleIdentifier,
            appName: running?.localizedName ?? "App"
        )
    }

    /// 某台螢幕上由前到後的一般視窗（多視窗排列用），最多 `limit` 個。
    ///
    /// z-order 只有 CGWindowList 給得出來，AX 的視窗清單沒有跨 App 的順序；所以先用
    /// CGWindowList 排序、再以 frame 對回 AX 視窗。只讀 pid／layer／bounds，
    /// 不碰視窗標題，不需要螢幕錄製權限。
    func frontToBackWindows(
        on screen: ScreenTopology.ScreenInfo,
        topology: ScreenTopology,
        excludingBundleIDs: Set<String>,
        excludingTokens: Set<String>,
        limit: Int
    ) throws -> [WindowRef] {
        guard limit > 0 else { return [] }
        return try sync {
            guard AXIsProcessTrusted() else { throw WorkerError.permissionRequired }
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            let list = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
            let ownPID = ProcessInfo.processInfo.processIdentifier
            var axWindowsByPID: [pid_t: [(AXUIElement, LayoutRect)]] = [:]
            var skipped: Set<pid_t> = []
            var result: [WindowRef] = []

            for info in list {
                guard result.count < limit else { break }
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      pid != ownPID, !skipped.contains(pid),
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.width >= 120, bounds.height >= 80
                else { continue }
                let frame = topology.fromAX(origin: bounds.origin, size: bounds.size)
                guard topology.screen(containing: frame)?.displayUUID == screen.displayUUID else { continue }

                let running = NSRunningApplication(processIdentifier: pid)
                if let bundleID = running?.bundleIdentifier, excludingBundleIDs.contains(bundleID) {
                    skipped.insert(pid)
                    continue
                }
                if axWindowsByPID[pid] == nil {
                    axWindowsByPID[pid] = self.standardWindows(pid: pid, topology: topology)
                }
                guard let match = axWindowsByPID[pid]?.first(where: { Self.sameFrame($0.1, frame) }) else { continue }
                let token = "\(pid):\(CFHash(match.0))"
                guard !excludingTokens.contains(token), !result.contains(where: { $0.token == token }) else { continue }
                self.elements[token] = match.0
                result.append(WindowRef(
                    token: token,
                    pid: pid,
                    bundleID: running?.bundleIdentifier,
                    appName: running?.localizedName ?? "App"
                ))
            }
            return result
        }
    }

    /// 一個 App 可排列的視窗：標準視窗、未最小化、非全螢幕、位置與大小可設。
    private func standardWindows(pid: pid_t, topology: ScreenTopology) -> [(AXUIElement, LayoutRect)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement]
        else { return [] }
        return windows.compactMap { window in
            var subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
                  (subrole as? String) == (kAXStandardWindowSubrole as String),
                  !isMinimized(window), !isFullScreen(window), isSettable(window),
                  let frame = try? readFrame(window, topology: topology)
            else { return nil }
            return (window, frame)
        }
    }

    private static func sameFrame(_ a: LayoutRect, _ b: LayoutRect) -> Bool {
        abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
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
