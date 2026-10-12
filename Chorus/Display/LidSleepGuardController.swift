import ChorusCore
import Foundation
import Observation
import OSLog

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
    /// Fi A8 / C8-4: recoveryBlocked／pendingRestore／persistRetryNeeded — manual restore; not foreign.
    case recoveryBlocked
}

/// Lid Guard controller (spec §5.5 / §6.6 / §7 / §14.2).
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
    /// U01: confirmed no-lid capability from monitor reading (Fi A3 hide+forbid).
    private(set) var lidReading: LidClosedReading = .unknown
    /// True only when reading is confirmed `.noLid` (not transient `.unknown`).
    var isConfirmedNoLid: Bool { lidReading == .noLid }

    /// §5.5: menu “闔蓋也不睡” only when all three hold.
    var isActuallyHoldingSleepDisabled: Bool {
        wantsSleepDisabled
            && !externalInterferenceLatched
            && helperStatus?.callerIsHolder == true
            && helperStatus?.sleepDisabled == true
    }

    var settings: LidSleepSettings {
        didSet {
            let approved = SettingsStore.approvedLidGuardSettings(settings)
            if approved != settings {
                settings = approved
                return
            }
            persistSettings()
            scheduleReevaluate()
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
    @ObservationIgnored private let pauseDurationSeconds: () -> Double
    @ObservationIgnored private let heartbeatInterval: TimeInterval

    @ObservationIgnored private var lastAgentModeActive = false
    @ObservationIgnored private var lastBusy = KeepAwakeBusyState(isBusy: false, contributing: [], releaseAt: nil)
    @ObservationIgnored private var lastPower = PowerSnapshot(
        hasInternalBattery: false, onBattery: false, percent: nil, thermal: .nominal
    )
    @ObservationIgnored private var lastFloor: KeepAwakeBatteryFloor = .default
    @ObservationIgnored private var started = false
    @ObservationIgnored private var shutDown = false
    @ObservationIgnored private var reevaluating = false
    @ObservationIgnored private var pendingReevaluate = false
    /// §14.2：update／policy 路徑內不回呼 onChange，避免與 KeepAwakeController.reevaluate 互撞。
    @ObservationIgnored private var suppressOnChange = false

    @ObservationIgnored private var setGeneration: UInt64 = 0
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var nextRetryDelay: TimeInterval = 1
    @ObservationIgnored private let maxRetryDelay: TimeInterval = 5 * 60

    /// Notification throttle state lives on the controller (notifier is stateless).
    /// C8-5: one armed notice per aggregate-busy period; 30min gate is independent.
    @ObservationIgnored private var wasAggregateBusy = false
    @ObservationIgnored private var armedNoticeSentInBusyPeriod = false
    @ObservationIgnored private var lastArmedNotifyAt: Double?
    @ObservationIgnored private var didNotifyHelperApproval = false
    @ObservationIgnored private var didNotifyLeftoverForeign = false
    @ObservationIgnored private var didNotifyLeftoverRecovery = false
    @ObservationIgnored private var lastForcedOffReason: String?
    @ObservationIgnored private var awaitingArmedConfirm = false
    /// Fi A2 / C8-2: external write of 0 — release and do not re-compete until safe reset.
    @ObservationIgnored private var externalInterferenceLatched = false
    /// Local override so a failed set(true) surfaces as unavailable(.error) until retry.
    @ObservationIgnored private var transientHelperError: String?
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?

    #if DEBUG
    /// M-5 / M-12 / M-13 test overrides (Release: absent).
    @ObservationIgnored var debugMaxLidClosedSeconds: Double?
    @ObservationIgnored var debugBatteryFloorPercent: Int?
    @ObservationIgnored var debugPowerOverride: PowerSnapshot?
    @ObservationIgnored var debugPauseDurationSeconds: Double?
    #endif

    private static let log = ChorusLog.display
    private static let armedThrottleSeconds: Double = 30 * 60

    init(
        settings settingsStore: SettingsStore,
        helper: any PowerHelperClienting = PowerHelperClient(
            // Never auto-register; protocol repair stays default-denied (C06 W1-14).
            authorizeProtocolRepair: { false }
        ),
        lid: any LidStateObserving = LidStateMonitor(),
        notifier: any KeepAwakeNotifying = KeepAwakeNotifier(),
        now: @escaping () -> Double = { LidMonotonicTime.seconds() ?? ProcessInfo.processInfo.systemUptime },
        e2eNamedInstance: Bool = InstanceConfig.current.name != nil,
        sessionStore: LidClosedSessionStore = LidClosedSessionStore(),
        sleepDisabledProbe: @escaping () -> Bool? = { SleepDisabledProbe.readSleepDisabled() },
        pauseDurationSeconds: @escaping () -> Double = { 3600 },
        heartbeatInterval: TimeInterval = PowerHelperConstants.heartbeatInterval
    ) {
        self.settingsStore = settingsStore
        self.helper = helper
        self.lid = lid
        self.notifier = notifier
        self.now = now
        self.e2eNamedInstance = e2eNamedInstance
        self.sessionStore = sessionStore
        self.sleepDisabledProbe = sleepDisabledProbe
        self.pauseDurationSeconds = pauseDurationSeconds
        self.heartbeatInterval = heartbeatInterval
        self.settings = SettingsStore.approvedLidGuardSettings(settingsStore.keepAwakeLidGuard)
        self.lidReading = lid.reading
        applyRestoredSession()
        helper.onAvailabilityChange = { [weak self] in
            self?.scheduleReevaluate()
        }
        lid.onChange = { [weak self] in
            guard let self else { return }
            self.lidReading = self.lid.reading
            self.scheduleReevaluate()
        }
    }

    func update(
        agentModeActive: Bool,
        busy: KeepAwakeBusyState,
        power: PowerSnapshot,
        existingFloor: KeepAwakeBatteryFloor
    ) {
        lastAgentModeActive = agentModeActive
        lastBusy = busy
        lastPower = power
        lastFloor = existingFloor
        contributingSources = busy.contributing
        suppressOnChange = true
        defer { suppressOnChange = false }
        ensureStarted()
        reevaluate()
    }

    func pauseForOneHour() {
        #if DEBUG
        let duration = debugPauseDurationSeconds ?? pauseDurationSeconds()
        #else
        let duration = pauseDurationSeconds()
        #endif
        state.userPausedUntil = now() + duration
        scheduleReevaluate()
    }

    func restoreLeftover() {
        switch leftover {
        case .ownResidual:
            Task { await restoreOwnResidual() }
        case .foreign, .unknownOwner, .otherUserHolding, .recoveryBlocked, .none:
            // Foreign / recovery / unknown: UI copies manual pmset — no auto override (Fi A2／A8).
            break
        }
    }

    /// Clear Fi A2 external-interference latch after a safe reset (settings／Agent／busy off).
    func clearExternalInterferenceLatchIfSafe() {
        guard externalInterferenceLatched else { return }
        guard !settings.enabled || !lastAgentModeActive || !lastBusy.isBusy else { return }
        externalInterferenceLatched = false
    }

    /// Sync set(false); returns within 1s even if helper is silent (§14.2).
    func shutdown() {
        shutDown = true
        stopHeartbeat()
        retryTask?.cancel()
        retryTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        setGeneration &+= 1
        let shouldRelease =
            wantsSleepDisabled
            || helperStatus?.callerIsHolder == true
            || helperStatus?.setByHelper == true
        wantsSleepDisabled = false
        // Never open a fresh XPC session just to no-op release (test host crash / C06 isolation).
        if !e2eNamedInstance, shouldRelease {
            _ = helper.setSleepDisabledSynchronously(false, timeout: 1)
        }
        lid.setPollingEnabled(false)
        lid.stop()
        started = false
        state.phase = .off
        persistSession()
    }

    /// Read-only leftover probe allowed even when the option is off (§6.6 / §14.2).
    /// Named E2E instances never connect or repair.
    func detectLeftover() async {
        guard !e2eNamedInstance else { return }
        helper.refreshAvailability()
        let probe = sleepDisabledProbe()
        let registered: Bool = {
            switch helper.availability {
            case .notRegistered: return false
            default: return true
            }
        }()
        guard probe == true || registered else { return }
        guard probe == true else {
            leftover = nil
            publish()
            return
        }

        // SleepDisabled == 1. Handshake via status() when connecting (C8-1);
        // notRegistered／requiresApproval／notFound stay unknownOwner without XPC.
        switch helper.availability {
        case .ready, .connecting:
            break
        default:
            leftover = .unknownOwner
            publish()
            return
        }

        do {
            let status = try await helper.status()
            applyHelperStatus(status)
            classifyLeftover(from: status)
            if leftover == .ownResidual {
                let restored = await restoreOwnResidual()
                if restored {
                    leftover = nil
                }
            }
        } catch {
            leftover = .unknownOwner
        }
        publish()
    }

    func refreshFromHelper() async {
        guard !e2eNamedInstance, !shutDown else { return }
        helper.refreshAvailability()
        switch helper.availability {
        case .ready, .connecting:
            break
        default:
            return
        }
        do {
            let status = try await helper.status()
            applyHelperStatus(status)
            handleForcedOffIfNeeded(status)
            considerExternalInterference(from: status)
            scheduleReevaluate()
        } catch {
            helperStatus = nil
            publish()
        }
    }

    /// U01: install / remove / open Login Items. Never auto-register from tests.
    func registerHelper() async throws {
        guard !e2eNamedInstance else { return }
        try await helper.register()
        scheduleReevaluate()
    }

    func unregisterHelper() async throws {
        guard !e2eNamedInstance else { return }
        try await helper.unregister()
        scheduleReevaluate()
    }

    func openHelperApprovalSettings() {
        helper.openApprovalSettings()
    }

    func refreshHelperAvailability() {
        guard !e2eNamedInstance else { return }
        helper.refreshAvailability()
        scheduleReevaluate()
    }

    // MARK: - Private

    private func ensureStarted() {
        guard !started, !shutDown else { return }
        started = true
        if !e2eNamedInstance {
            lid.start()
            lidReading = lid.reading
            helper.refreshAvailability()
            // C8-1: enabled helper starts `.connecting` until status() handshakes.
            ensureHelperHandshake()
        }
    }

    /// Bounded status() handshake so production can leave `.connecting` (C8-1).
    private func ensureHelperHandshake() {
        guard !e2eNamedInstance, !shutDown else { return }
        helper.refreshAvailability()
        guard case .connecting = helper.availability else { return }
        guard handshakeTask == nil else { return }
        handshakeTask = Task { @MainActor [weak self] in
            defer { self?.handshakeTask = nil }
            guard let self, !self.shutDown else { return }
            do {
                let status = try await self.helper.status()
                guard !self.shutDown else { return }
                self.applyHelperStatus(status)
                self.handleForcedOffIfNeeded(status)
                self.considerExternalInterference(from: status)
                self.scheduleReevaluate()
            } catch {
                // Stay connecting／unavailable; retry path may refresh later.
                Self.log.notice("Lid Guard helper handshake failed: \(String(describing: error))")
            }
        }
    }

    private func scheduleReevaluate() {
        if reevaluating {
            pendingReevaluate = true
            return
        }
        reevaluate()
    }

    private func reevaluate() {
        guard !shutDown else { return }
        if reevaluating {
            pendingReevaluate = true
            return
        }
        reevaluating = true
        defer {
            reevaluating = false
            if pendingReevaluate {
                pendingReevaluate = false
                // Async — never sync-recurse through lid/helper callbacks (§14.2).
                Task { @MainActor [weak self] in
                    self?.reevaluate()
                }
            }
        }

        if e2eNamedInstance {
            applyPolicyResult(
                state: LidSleepGuardState(phase: .off),
                wants: false,
                events: []
            )
            return
        }

        // Fi A3／C8-3: clamp ≤3h and force AC limit (core still allows 4h／AC-exempt).
        var effectiveSettings = SettingsStore.approvedLidGuardSettings(settings)
        #if DEBUG
        if let seconds = debugMaxLidClosedSeconds, seconds.isFinite, seconds > 0 {
            effectiveSettings.maxLidClosedSeconds = seconds
        }
        if let floor = debugBatteryFloorPercent {
            effectiveSettings.batteryFloorPercent = max(floor, 30)
        }
        #endif

        #if DEBUG
        let power = debugPowerOverride ?? lastPower
        #else
        let power = lastPower
        #endif

        lidReading = lid.reading
        clearExternalInterferenceLatchIfSafe()
        // Keep trying handshake while enabled/connecting (C8-1).
        if settings.enabled || lastAgentModeActive {
            ensureHelperHandshake()
        }

        let helperAvailability: LidHelperAvailability = {
            if externalInterferenceLatched {
                return .error("externalInterference")
            }
            if let transientHelperError { return .error(transientHelperError) }
            return helper.availability
        }()

        if case .requiresApproval = helperAvailability, settings.enabled, lastAgentModeActive {
            if !didNotifyHelperApproval {
                didNotifyHelperApproval = true
                notifier.notifyLidGuardHelperNeedsApproval()
            }
        }

        updateBusyPeriodTracking()

        let input = LidSleepGuardInput(
            settings: effectiveSettings,
            agentModeActive: lastAgentModeActive,
            busy: lastBusy.isBusy,
            helper: helperAvailability,
            lid: lidReading,
            power: power,
            now: now(),
            existingBatteryFloor: lastFloor
        )
        let result = LidSleepGuardPolicy.step(state, input: input)
        var wants = result.wantsSleepDisabled
        if externalInterferenceLatched {
            wants = false
        }
        applyPolicyResult(state: result.state, wants: wants, events: result.events)
    }

    private func updateBusyPeriodTracking() {
        if lastBusy.isBusy {
            if !wasAggregateBusy {
                wasAggregateBusy = true
                armedNoticeSentInBusyPeriod = false
            }
        } else {
            wasAggregateBusy = false
            armedNoticeSentInBusyPeriod = false
        }
    }

    private func applyPolicyResult(
        state next: LidSleepGuardState,
        wants: Bool,
        events: [LidSleepGuardEvent]
    ) {
        let previousWants = wantsSleepDisabled
        state = next
        wantsSleepDisabled = wants
        persistSession()

        let polling: Bool = {
            switch state.phase {
            case .armed, .holdingLidClosed: return true
            default: return false
            }
        }()
        lid.setPollingEnabled(polling)

        if wants != previousWants {
            if wants {
                if externalInterferenceLatched {
                    wantsSleepDisabled = false
                } else {
                    awaitingArmedConfirm = true
                    requestSet(true)
                    startHeartbeat()
                }
            } else {
                awaitingArmedConfirm = false
                requestSet(false)
                stopHeartbeat()
            }
        } else if wants, externalInterferenceLatched {
            wantsSleepDisabled = false
            stopHeartbeat()
        }

        handleEvents(events)
        publish()
    }

    private func requestSet(_ on: Bool) {
        guard !e2eNamedInstance, !shutDown else { return }
        if on, externalInterferenceLatched { return }
        switch helper.availability {
        case .ready:
            break
        case .connecting:
            // C8-1: kick handshake; do not treat connecting as permanent error.
            ensureHelperHandshake()
            if on {
                scheduleRetry()
            }
            return
        default:
            if on {
                transientHelperError = "helper not ready"
                scheduleRetry()
                scheduleReevaluate()
            }
            return
        }
        setGeneration &+= 1
        let generation = setGeneration
        Task { @MainActor [weak self] in
            guard let self, !self.shutDown, self.setGeneration == generation else { return }
            if on, self.externalInterferenceLatched { return }
            do {
                let status = try await self.helper.setSleepDisabled(on)
                guard self.setGeneration == generation, !self.shutDown else { return }
                if on {
                    self.transientHelperError = nil
                    self.nextRetryDelay = 1
                }
                self.applyHelperStatus(status)
                self.handleForcedOffIfNeeded(status)
                self.considerExternalInterference(from: status)
                if on, !self.externalInterferenceLatched {
                    self.maybeNotifyArmedConfirmed()
                }
                self.scheduleReevaluate()
            } catch {
                guard self.setGeneration == generation, !self.shutDown else { return }
                if on {
                    self.transientHelperError = String(describing: error)
                    self.stopHeartbeat()
                    self.scheduleRetry()
                    self.scheduleReevaluate()
                }
            }
        }
    }

    private func scheduleRetry() {
        guard !externalInterferenceLatched else { return }
        retryTask?.cancel()
        let delay = nextRetryDelay
        nextRetryDelay = min(nextRetryDelay * 2, maxRetryDelay)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.shutDown else { return }
            guard !self.externalInterferenceLatched else { return }
            // Clear transient error so policy can re-arm and requestSet again.
            self.transientHelperError = nil
            self.helper.refreshAvailability()
            self.ensureHelperHandshake()
            self.scheduleReevaluate()
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        guard !externalInterferenceLatched else { return }
        let interval = heartbeatInterval
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, !Task.isCancelled, !self.shutDown else { return }
                guard self.wantsSleepDisabled, !self.externalInterferenceLatched else { return }
                // Heartbeat on main actor Task — freeze stops heartbeats → helper watchdog.
                self.requestSet(true)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func applyHelperStatus(_ status: PowerHelperStatus) {
        helperStatus = status
        // Stale/disconnected: drop hold badge immediately (§14.2).
        if status.sleepDisabled != true || !status.callerIsHolder {
            // Keep status for UI; isActuallyHoldingSleepDisabled becomes false.
        }
    }

    private func handleForcedOffIfNeeded(_ status: PowerHelperStatus) {
        guard let reason = status.lastForcedOffReason, !reason.isEmpty else { return }
        if lastForcedOffReason == reason { return }
        lastForcedOffReason = reason
        Self.log.notice("Lid Guard helper forcedOff: \(reason)")
        notifier.notifyHelperForcedOff(reason: reason)
        if reason == "externalInterference" {
            latchExternalInterference(requestRelease: status.callerIsHolder)
        }
    }

    /// C8-2: Fi A2 — release and prompt; do not re-write 1 after external 0.
    /// Only the helper's `externalInterference` reason latches (not a pre-hold false readback).
    private func considerExternalInterference(from status: PowerHelperStatus) {
        guard status.lastForcedOffReason == "externalInterference" else { return }
        latchExternalInterference(requestRelease: status.callerIsHolder)
    }

    private func latchExternalInterference(requestRelease: Bool) {
        guard !externalInterferenceLatched else {
            stopHeartbeat()
            retryTask?.cancel()
            retryTask = nil
            return
        }
        externalInterferenceLatched = true
        awaitingArmedConfirm = false
        wantsSleepDisabled = false
        stopHeartbeat()
        retryTask?.cancel()
        retryTask = nil
        if requestRelease {
            requestSet(false)
        }
        Self.log.notice("Lid Guard latched externalInterference — no further set(true)")
    }

    private func maybeNotifyArmedConfirmed() {
        guard awaitingArmedConfirm, isActuallyHoldingSleepDisabled else { return }
        awaitingArmedConfirm = false
        // 同一段忙碌期只發一次（C8-5；來源集合變更不算新忙碌期）。
        if armedNoticeSentInBusyPeriod { return }
        let nowTs = now()
        // 新忙碌期仍受 30 分鐘節流（Fi A3）。
        if let last = lastArmedNotifyAt, nowTs - last < Self.armedThrottleSeconds {
            return
        }
        armedNoticeSentInBusyPeriod = true
        lastArmedNotifyAt = nowTs
        if settings.notificationsEnabled {
            notifier.notifyLidGuardArmed(sources: contributingSources)
        }
    }

    private func classifyLeftover(from status: PowerHelperStatus) {
        if status.holderCount > 0 {
            if status.otherUsersHolding || !status.callerIsHolder {
                leftover = .otherUserHolding
            } else {
                leftover = nil
            }
            return
        }
        // C8-4 / Fi A8: recovery health beats foreign classification.
        if status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded {
            leftover = .recoveryBlocked
            if !didNotifyLeftoverRecovery {
                didNotifyLeftoverRecovery = true
                notifier.notifyLeftoverRecoveryNeeded()
            }
            return
        }
        if status.setByHelper, !status.callerIsHolder {
            leftover = .ownResidual
            return
        }
        if !status.setByHelper {
            leftover = .foreign
            if !didNotifyLeftoverForeign {
                didNotifyLeftoverForeign = true
                notifier.notifyLeftoverForeign()
            }
            return
        }
        leftover = nil
    }

    private func handleEvents(_ events: [LidSleepGuardEvent]) {
        let lidClosed = lid.reading == .closed
        for event in events {
            switch event {
            case .armed:
                // Armed toast only after helper confirms hold (§14.2).
                break
            case let .released(reason):
                awaitingArmedConfirm = false
                guard settings.notificationsEnabled || isSafetyRelease(reason) else { continue }
                // Open lid + idle (work finished): no notification (§7.3).
                if reason == nil, !lidClosed { continue }
                notifier.notifyLidGuardReleased(reason: reason, lidClosed: lidClosed)
            case .lidClosedWhileHolding, .lidClosedWhileNotHolding:
                break
            }
        }
    }

    private func isSafetyRelease(_ reason: LidBlockReason?) -> Bool {
        switch reason {
        case .thermal, .lowBattery, .maxDuration, .unknownPower, .lidUnknown:
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func restoreOwnResidual() async -> Bool {
        guard !e2eNamedInstance else { return false }
        // Never acquire-as-repair while recovery is blocked (Fi A8 / C8-4).
        if let status = helperStatus,
           status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded {
            return false
        }
        do {
            // Normal restore path: acquire then release (§6.6 / ledger exception).
            _ = try await helper.setSleepDisabled(true)
            let after = try await helper.setSleepDisabled(false)
            applyHelperStatus(after)
            // Only notify when restore evidence shows SleepDisabled cleared (V-C08-7).
            guard after.sleepDisabled == false else { return false }
            notifier.notifyLeftoverRestored()
            return true
        } catch {
            return false
        }
    }

    private func persistSettings() {
        settingsStore.keepAwakeLidGuard = SettingsStore.approvedLidGuardSettings(settings)
    }

    private func applyRestoredSession() {
        switch sessionStore.restoreResult(nowContinuous: now()) {
        case let .valid(since, latched):
            state.lidClosedSince = since
            state.maxDurationLatched = latched
        case .invalid:
            // W1-10 / C06: corrupt or reboot mismatch → conservative latch.
            state.lidClosedSince = now()
            state.maxDurationLatched = true
        case .absent:
            break
        }
    }

    private func persistSession() {
        if let since = state.lidClosedSince, let boot = LidMonotonicTime.bootSessionUUID() {
            sessionStore.save(
                continuousClosedAt: since,
                bootSessionUUID: boot,
                maxDurationLatched: state.maxDurationLatched
            )
        } else if lid.reading == .open {
            sessionStore.clear()
        }
    }

    private func publish() {
        guard !suppressOnChange else { return }
        onChange?()
    }
}
