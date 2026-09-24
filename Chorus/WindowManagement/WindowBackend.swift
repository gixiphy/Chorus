import ChorusCore
import Foundation

typealias WindowRef = AXWindowWorker.WindowRef
typealias WorkerError = AXWindowWorker.WorkerError
typealias SetResult = AXWindowWorker.SetResult

/// 純 CG 快照的一個視窗（預覽用，沒有 AX token）。
struct WindowSnapshot: Sendable, Equatable {
    var pid: pid_t
    var bundleID: String?
    var appName: String
    var frame: LayoutRect
}

protocol WindowBackend: AnyObject, Sendable {
    func focusedExternalWindow(excludingBundleIDs: Set<String>) throws -> WindowRef
    func windowForApplication(pid: pid_t, excludingBundleIDs: Set<String>) throws -> WindowRef
    func window(
        atX x: Double,
        y: Double,
        topology: ScreenTopology,
        excludingBundleIDs: Set<String>
    ) throws -> WindowRef
    func frontToBackWindows(
        on screen: ScreenTopology.ScreenInfo,
        topology: ScreenTopology,
        excludingBundleIDs: Set<String>,
        excludingTokens: Set<String>,
        limit: Int
    ) throws -> [WindowRef]
    func onScreenWindowSnapshot(
        on screen: ScreenTopology.ScreenInfo,
        topology: ScreenTopology,
        excludingBundleIDs: Set<String>,
        limit: Int
    ) -> [WindowSnapshot]
    func getFrame(token: String, topology: ScreenTopology) throws -> LayoutRect
    func setFrame(token: String, frame: LayoutRect, topology: ScreenTopology) -> SetResult
    func reportedMinimumSize(token: String) -> LayoutSize?
    func forget(token: String)
}

extension WindowBackend {
    func reportedMinimumSize(token: String) -> LayoutSize? { nil }
}

extension AXWindowWorker: WindowBackend {}
