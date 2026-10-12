import AppKit
import ChorusCore
import Foundation

/// Grok Bot App 是否開著（spec §4.6；R01 Q8）。預設關閉，使用者 opt-in。
enum GrokBotPresence {
    /// R01 Q8：`com.anysphere.sand`（Team `DCNK4UB866`）。無 working-state API。
    static let bundleIDs: Set<String> = ["com.anysphere.sand"]
    static let teamID = "DCNK4UB866"
    static let knownAppPaths: Set<String> = ["/Applications/Grok Bot.app"]
    static let displayName = "Grok Bot（開著）"
}

protocol AppPresenceChecking: Sendable {
    func isPresent(bundleIDs: Set<String>, appPaths: Set<String>) -> Bool
}

struct WorkspaceAppPresenceChecker: AppPresenceChecking {
    func isPresent(bundleIDs: Set<String>, appPaths: Set<String>) -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, bundleIDs.contains(id) {
                return true
            }
            if let path = app.bundleURL?.path {
                if appPaths.contains(path) { return true }
                // ~/Applications/Grok Bot.app
                if path.hasSuffix("/Grok Bot.app"),
                   DesktopAgentMatcher.isUnderApplicationsTree(path) {
                    return true
                }
            }
        }
        return false
    }
}

@MainActor
final class AppPresenceSource: KeepAwakeSource {
    private(set) var report: [KeepAwakeSourceReport] = []
    var onChange: (() -> Void)?

    private var enabled = false
    private var running = false
    /// 第一次 present→absent 的觀察時刻；重複 absent 不得延長（C7-5）。
    private var exitedAt: Date?
    private var wasPresent = false
    private let checker: any AppPresenceChecking
    private let now: () -> Date
    private var observers: [NSObjectProtocol] = []

    init(
        checker: any AppPresenceChecking = WorkspaceAppPresenceChecker(),
        now: @escaping () -> Date = Date.init
    ) {
        self.checker = checker
        self.now = now
    }

    func configure(enabled: Bool) {
        self.enabled = enabled
    }

    func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(notify: true) }
        }
        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(notify: true) }
        }
        observers = [launch, terminate]
        refresh(notify: false)
    }

    func stop() {
        running = false
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        // V1-10: clear presence evidence on stop — grace only for exits observed while running.
        clearEvidence()
    }

    /// Opt-out：立即移除跡證（V-C07-5）。
    func clearEvidence() {
        wasPresent = false
        exitedAt = nil
        report = []
    }

    func refresh(notify: Bool) {
        guard enabled, running else {
            report = []
            return
        }
        let present = checker.isPresent(
            bundleIDs: GrokBotPresence.bundleIDs,
            appPaths: GrokBotPresence.knownAppPaths
        )
        let instant = now()
        if present {
            wasPresent = true
            exitedAt = nil
            report = [
                KeepAwakeSourceReport(
                    id: "app:grok-bot",
                    kind: .appPresence,
                    displayName: GrokBotPresence.displayName,
                    detail: nil,
                    isWorkingNow: true,
                    lastWorkingAt: instant,
                    health: .ok
                ),
            ]
        } else if wasPresent {
            // C7-5：結束時刻記一次，不是上次 presence refresh。
            if exitedAt == nil {
                exitedAt = instant
            }
            let exit = exitedAt ?? instant
            report = [
                KeepAwakeSourceReport(
                    id: "app:grok-bot",
                    kind: .appPresence,
                    displayName: GrokBotPresence.displayName,
                    detail: nil,
                    isWorkingNow: false,
                    lastWorkingAt: exit,
                    health: .ok
                ),
            ]
        } else {
            report = []
        }
        if notify { onChange?() }
    }
}
