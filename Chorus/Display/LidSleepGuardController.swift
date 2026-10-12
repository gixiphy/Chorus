import ChorusCore
import Foundation
import Observation

/// §6.6 leftover classification for menu / settings.
enum LeftoverSleepDisabled: Equatable, Sendable {
    /// Chorus residual (`setByHelper`, no holders) — restore via set(true)/set(false).
    case ownResidual
    /// External SleepDisabled=1 — never auto-clear (Fi A2).
    case foreign
    /// Another user / other live holders — leave alone (§14.2).
    case otherUserHolding
    /// Helper unavailable while SleepDisabled=1.
    case unknownOwner
}

/// Lid Guard controller (spec §5.5 / §6.6 / §7 / §14.2).
///
/// Skeleton: public surface for U01/U02. Full helper / policy wiring lands in the integration commit.
@MainActor
@Observable
final class LidSleepGuardController {
    private(set) var state: LidSleepGuardState = .init()
    var phase: LidSleepGuardPhase { state.phase }
    private(set) var helperStatus: PowerHelperStatus?
    private(set) var leftover: LeftoverSleepDisabled?
    private(set) var contributingSources: [KeepAwakeSourceReport] = []
    /// Last policy `wantsSleepDisabled` request (not confirmation of system hold).
    private(set) var wantsSleepDisabled = false

    /// §5.5: menu “闔蓋也不睡” only when all three hold.
    var isActuallyHoldingSleepDisabled: Bool {
        wantsSleepDisabled
            && helperStatus?.callerIsHolder == true
            && helperStatus?.sleepDisabled == true
    }

    var settings: LidSleepSettings {
        didSet {
            let normalized = settings.normalized()
            if normalized != settings {
                settings = normalized
                return
            }
            persistSettings()
            // Skeleton: no reevaluate yet.
        }
    }

    /// Fired after phase / leftover / helperStatus changes (UI + KeepAwakeController).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let helper: any PowerHelperClienting
    @ObservationIgnored private let lid: any LidStateObserving
    @ObservationIgnored private let notifier: any KeepAwakeNotifying
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let e2eNamedInstance: Bool
    @ObservationIgnored private let sessionStore: LidClosedSessionStore
    @ObservationIgnored private let sleepDisabledProbe: () -> Bool?

    init(
        settings settingsStore: SettingsStore,
        helper: any PowerHelperClienting = PowerHelperClient(),
        lid: any LidStateObserving = LidStateMonitor(),
        notifier: any KeepAwakeNotifying = KeepAwakeNotifier(),
        now: @escaping () -> Double = { LidMonotonicTime.seconds() ?? ProcessInfo.processInfo.systemUptime },
        e2eNamedInstance: Bool = InstanceConfig.current.name != nil,
        sessionStore: LidClosedSessionStore = LidClosedSessionStore(),
        sleepDisabledProbe: @escaping () -> Bool? = { SleepDisabledProbe.readSleepDisabled() }
    ) {
        self.settingsStore = settingsStore
        self.helper = helper
        self.lid = lid
        self.notifier = notifier
        self.now = now
        self.e2eNamedInstance = e2eNamedInstance
        self.sessionStore = sessionStore
        self.sleepDisabledProbe = sleepDisabledProbe
        self.settings = settingsStore.keepAwakeLidGuard.normalized()
        // Skeleton: restore session latch only; full policy in integration.
        applyRestoredSession()
    }

    func update(
        agentModeActive: Bool,
        busy: KeepAwakeBusyState,
        power: PowerSnapshot,
        existingFloor: KeepAwakeBatteryFloor
    ) {
        // Skeleton — integration fills policy + helper set/heartbeat.
        _ = agentModeActive
        contributingSources = busy.contributing
        _ = power
        _ = existingFloor
        if e2eNamedInstance {
            state.phase = .off
            wantsSleepDisabled = false
        }
    }

    func pauseForOneHour() {
        // Skeleton
    }

    func restoreLeftover() {
        // Skeleton
    }

    func shutdown() {
        // Skeleton: sync release with 1s bound lands in integration.
    }

    func detectLeftover() async {
        // Skeleton
    }

    func refreshFromHelper() async {
        // Skeleton
    }

    /// U01: install / remove / open Login Items. Never auto-register from here in tests.
    func registerHelper() async throws {
        try await helper.register()
    }

    func unregisterHelper() async throws {
        try await helper.unregister()
    }

    func openHelperApprovalSettings() {
        helper.openApprovalSettings()
    }

    func refreshHelperAvailability() {
        helper.refreshAvailability()
    }

    // MARK: - Private (skeleton)

    private func persistSettings() {
        settingsStore.keepAwakeLidGuard = settings
    }

    private func applyRestoredSession() {
        switch sessionStore.restoreResult(nowContinuous: now()) {
        case let .valid(since, latched):
            state.lidClosedSince = since
            state.maxDurationLatched = latched
        case .invalid:
            // W1-10 / C06: corrupt or reboot mismatch → conservative latch.
            state.lidClosedSince = 0
            state.maxDurationLatched = true
        case .absent:
            break
        }
    }
}
