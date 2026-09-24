import ChorusCore
import Foundation
@testable import Chorus

final class FakeWindowBackend: WindowBackend, @unchecked Sendable {
    struct Window {
        var ref: WindowRef
        var frame: LayoutRect
        var minSize: LayoutSize?
        var settable = true

        init(ref: WindowRef, frame: LayoutRect, minSize: LayoutSize? = nil, settable: Bool = true) {
            self.ref = ref
            self.frame = frame
            self.minSize = minSize
            self.settable = settable
        }
    }

    var windows: [String: Window]
    var focusedToken: String?
    var zOrder: [String]
    var snapshot: [WindowSnapshot] = []
    var permissionRevoked = false
    var reportedMinimumSizes: [String: LayoutSize] = [:]
    var setFrameFailures: [String: [WorkerError]] = [:]
    var getFrameFailures: [String: WorkerError] = [:]
    var onBeforeSetFrame: ((String) -> Void)?

    private(set) var setFrameLog: [(token: String, frame: LayoutRect)] = []
    private(set) var frontToBackCalls = 0
    private(set) var getFrameCalls = 0
    private(set) var forgottenTokens: [String] = []

    init(windows: [String: Window], focusedToken: String? = nil, zOrder: [String] = []) {
        self.windows = windows
        self.focusedToken = focusedToken
        self.zOrder = zOrder
    }

    func focusedExternalWindow(excludingBundleIDs: Set<String>) throws -> WindowRef {
        try checkPermission()
        guard let focusedToken, let window = windows[focusedToken],
              !isExcluded(window.ref, by: excludingBundleIDs)
        else { throw WorkerError.noTarget }
        return window.ref
    }

    func windowForApplication(pid: pid_t, excludingBundleIDs: Set<String>) throws -> WindowRef {
        try checkPermission()
        guard let window = windows.values.first(where: {
            $0.ref.pid == pid && !isExcluded($0.ref, by: excludingBundleIDs)
        }) else { throw WorkerError.noTarget }
        return window.ref
    }

    func window(
        atX x: Double,
        y: Double,
        topology: ScreenTopology,
        excludingBundleIDs: Set<String>
    ) throws -> WindowRef {
        try checkPermission()
        guard let window = windows.values.first(where: {
            $0.frame.contains(x, y) && !isExcluded($0.ref, by: excludingBundleIDs)
        }) else { throw WorkerError.noTarget }
        return window.ref
    }

    func frontToBackWindows(
        on screen: ScreenTopology.ScreenInfo,
        topology: ScreenTopology,
        excludingBundleIDs: Set<String>,
        excludingTokens: Set<String>,
        limit: Int
    ) throws -> [WindowRef] {
        try checkPermission()
        frontToBackCalls += 1
        return zOrder.compactMap { token in
            guard !excludingTokens.contains(token), let window = windows[token],
                  !isExcluded(window.ref, by: excludingBundleIDs),
                  topology.screen(containing: window.frame)?.displayUUID == screen.displayUUID
            else { return nil }
            return window.ref
        }
        .prefix(limit)
        .map(\.self)
    }

    func onScreenWindowSnapshot(
        on screen: ScreenTopology.ScreenInfo,
        topology: ScreenTopology,
        excludingBundleIDs: Set<String>,
        limit: Int
    ) -> [WindowSnapshot] {
        Array(snapshot.prefix(limit))
    }

    func getFrame(token: String, topology: ScreenTopology) throws -> LayoutRect {
        try checkPermission()
        getFrameCalls += 1
        if let error = getFrameFailures[token] { throw error }
        guard let window = windows[token] else { throw WorkerError.targetGone }
        return window.frame
    }

    func setFrame(token: String, frame: LayoutRect, topology: ScreenTopology) -> SetResult {
        if permissionRevoked { return .failed(.permissionRequired) }
        onBeforeSetFrame?(token)
        setFrameLog.append((token, frame))
        if permissionRevoked { return .failed(.permissionRequired) }
        if var failures = setFrameFailures[token], !failures.isEmpty {
            let error = failures.removeFirst()
            setFrameFailures[token] = failures
            return .failed(error)
        }
        guard var window = windows[token] else { return .failed(.targetGone) }
        guard window.settable else { return .failed(.unsupported) }
        let before = window.frame
        var actual = frame
        if let minSize = window.minSize {
            actual.width = max(actual.width, minSize.width)
            actual.height = max(actual.height, minSize.height)
        }
        window.frame = actual
        windows[token] = window
        return Self.framesMatch(frame, window.frame)
            ? .applied(before: before, after: window.frame)
            : .constrained(before: before, after: window.frame)
    }

    func reportedMinimumSize(token: String) -> LayoutSize? {
        reportedMinimumSizes[token]
    }

    func forget(token: String) {
        windows.removeValue(forKey: token)
        forgottenTokens.append(token)
    }

    private func checkPermission() throws {
        if permissionRevoked { throw WorkerError.permissionRequired }
    }

    private func isExcluded(_ ref: WindowRef, by bundleIDs: Set<String>) -> Bool {
        ref.bundleID.map { bundleIDs.contains($0) } ?? false
    }

    private static func framesMatch(_ lhs: LayoutRect, _ rhs: LayoutRect) -> Bool {
        abs(lhs.x - rhs.x) <= 2
            && abs(lhs.y - rhs.y) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }
}
