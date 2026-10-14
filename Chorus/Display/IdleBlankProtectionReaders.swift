import AppKit
import ChorusCore
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// 熄屏保護訊號：前景全螢幕、遠端／螢幕共享會話、其他程序的 display-sleep assertion。
/// 只用公開 API；讀取失敗 → `.unknown`（保守不熄）。
enum IdleBlankProtectionReaders {
    /// 已知會注入／轉發輸入、且本地 CG idle 可能漏算的遠端相關 bundle。
    /// 偵測到任一在跑 → 連線期間不熄屏（Fi D-2026-10-14 #4）。
    private static let remoteSessionBundleIDs: Set<String> = [
        "com.apple.ScreenSharing",
        "com.apple.screensharing.agent",
        "com.apple.screensharing.menuextra",
        "com.apple.RemoteDesktopAgent",
        "com.apple.RemoteDesktop",
        "com.apple.AppleVNCAgent",
        "com.apple.universalcontrol",
        "com.apple.controlcenter.ContinuityCapture",
    ]

    /// Fi #2：媒體偵測不可靠時，前景全螢幕即不熄屏。
    static func foregroundFullscreen() -> IdleBlankSignal {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }
        let pid = front.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier {
            return .inactive
        }
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .unknown
        }
        // CGWindow bounds 是 Quartz 全域座標（主螢幕左上原點、y 向下），
        // 要跟 CGDisplayBounds 比，不能跟 NSScreen.frame（左下原點）比。
        let displayBounds = NSScreen.screens.compactMap { screen -> CGRect? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        return fullscreenSignal(windowInfos: infoList, frontPID: pid, displayBounds: displayBounds)
    }

    /// 純函式：前景 App 是否有視窗蓋滿任一螢幕（Quartz 座標）。
    /// 視窗清單讀得到但前景 App 沒有可見視窗（例如 Finder 只剩桌面）→ inactive。
    static func fullscreenSignal(
        windowInfos: [[String: Any]],
        frontPID: pid_t,
        displayBounds: [CGRect]
    ) -> IdleBlankSignal {
        guard !displayBounds.isEmpty else { return .unknown }
        for info in windowInfos {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let windowRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  windowRect.width > 0, windowRect.height > 0
            else { continue }
            if displayBounds.contains(where: { windowCoversScreen(windowRect, $0) }) {
                return .active
            }
        }
        return .inactive
    }

    /// 遠端／Universal Control／螢幕共享：偵測到會話 → active；
    /// 讀取工作區失敗 → unknown；否則 inactive。
    static func remoteSession() -> IdleBlankSignal {
        let running = NSWorkspace.shared.runningApplications
        // runningApplications 本身是公開 API；空陣列在正常登入桌面極少見，
        // 但若呼叫端被隔離／失敗而得到無法判斷的狀態，保守回 unknown。
        if running.isEmpty {
            return .unknown
        }
        for app in running {
            if let bid = app.bundleIdentifier, remoteSessionBundleIDs.contains(bid) {
                return .active
            }
            // 部分 agent 沒有 bundle id，退看 localizedName（仍非全域輸入監控）。
            if let name = app.localizedName?.lowercased() {
                if name.contains("screen sharing")
                    || name.contains("螢幕共享")
                    || name.contains("universal control")
                {
                    return .active
                }
            }
        }

        // 主控台 session 不在本機時（例如遠端登入），保守視為遠端活動中。
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            let key = kCGSessionOnConsoleKey as String
            if let onConsole = session[key] as? Bool, !onConsole {
                return .active
            }
            if let onConsoleNum = session[key] as? NSNumber, !onConsoleNum.boolValue {
                return .active
            }
        }

        return .inactive
    }

    /// 其他程序的 `PreventUserIdleDisplaySleep`；排除 Chorus 自己。
    /// 列舉失敗 → `.unknown`。
    static func foreignDisplaySleepAssertion() -> IdleBlankSignal {
        var assertionsRef: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsRef)
        guard status == kIOReturnSuccess, let unmanaged = assertionsRef else {
            return .unknown
        }
        let byPID = unmanaged.takeRetainedValue() as NSDictionary
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        return displaySleepSignal(assertionsByPID: byPID, selfPID: selfPID)
    }

    /// 擋 display idle sleep 的 assertion 類型。舊名 `NoDisplaySleepAssertion`
    /// （`kIOPMAssertionTypeNoDisplaySleep`）在 `IOPMCopyAssertionsByProcess` 以原名回報，
    /// 不會被正規化成 `PreventUserIdleDisplaySleep`，兩個都要認。
    private static let displaySleepAssertionTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        kIOPMAssertionTypeNoDisplaySleep as String,
    ]

    /// 純函式：解析 `IOPMCopyAssertionsByProcess` 結果；排除 `selfPID`。
    static func displaySleepSignal(assertionsByPID byPID: NSDictionary, selfPID: Int) -> IdleBlankSignal {
        for (key, value) in byPID {
            let pid: Int
            if let number = key as? NSNumber {
                pid = number.intValue
            } else if let intKey = key as? Int {
                pid = intKey
            } else {
                continue
            }
            if pid == selfPID { continue }
            guard let assertions = value as? [[String: Any]] else {
                // 結構不符 → 不猜，保守。
                return .unknown
            }
            for assertion in assertions {
                let type =
                    (assertion[kIOPMAssertionTypeKey] as? String)
                    ?? (assertion["AssertType"] as? String)
                    ?? (assertion["AssertionType"] as? String)
                guard let type, displaySleepAssertionTypes.contains(type) else { continue }
                let level =
                    (assertion[kIOPMAssertionLevelKey] as? NSNumber)?.uint32Value
                    ?? (assertion["AssertLevel"] as? NSNumber)?.uint32Value
                if level == nil || level == UInt32(kIOPMAssertionLevelOn) {
                    return .active
                }
            }
        }
        return .inactive
    }

    private static func windowCoversScreen(_ window: CGRect, _ screen: CGRect) -> Bool {
        // 允許選單列／劉海幾個點的誤差，避免誤判一般最大化視窗。
        let inset = screen.insetBy(dx: 2, dy: 2)
        return window.contains(inset) || window.equalTo(screen)
            || (abs(window.width - screen.width) < 4
                && abs(window.height - screen.height) < 4
                && abs(window.minX - screen.minX) < 4
                && abs(window.minY - screen.minY) < 4)
    }
}
