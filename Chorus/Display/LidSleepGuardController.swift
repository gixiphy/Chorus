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

    /// Actual helper SMAppService/XPC availability (V1-8); not invented from policy phase.
    var helperAvailability: LidHelperAvailability { helper.availability }

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
    @ObservationIgnored private let sleepDisabledProbe: () async -> Bool?
    @ObservationIgnored private let pauseDurationSeconds: () -> Double
    @ObservationIgnored private let heartbeatInterval: TimeInterval
    /// PERF1-R3/R7: injectable evidence-retry delay (tests use zero/fake clock).
    @ObservationIgnored private let evidenceSleep: (TimeInterval) async -> Void

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
    /// Distinguishes recovery reads/retries even when no policy set was issued.
    @ObservationIgnored private var recoveryGeneration: UInt64 = 0
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var nextRetryDelay: TimeInterval = 5
    @ObservationIgnored private let maxRetryDelay: TimeInterval = 300
    /// PERF-1 evidence backoff index into 5,10,20,40,80,160,300…
    @ObservationIgnored private var evidenceRetryIndex = 0
    /// PERF1-NEW-4: bumped to invalidate an armed sleeping retry on fresh healthy evidence.
    @ObservationIgnored private var evidenceRetryGeneration: UInt64 = 0

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
    /// C8-2: after a failed holding set, block reacquire until status evidence is obtained.
    @ObservationIgnored private var awaitingForcedOffEvidence = false
    /// Failed reads revoke confirmation, but cannot erase an already observed recovery block.
    @ObservationIgnored private var recoveryHealthBlocked = false
    /// Local override so a failed set(true) surfaces as unavailable(.error) until retry.
    @ObservationIgnored private var transientHelperError: String?
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    /// PERF1-R3: at most one shared refresh/evidence coordinator chain.
    @ObservationIgnored private var evidenceCoordinatorTask: Task<Void, Never>?
    @ObservationIgnored private var evidenceCoordinatorGeneration: UInt64 = 0
    /// When a permitted reason arrives while a chain is in flight, run it once after.
    @ObservationIgnored private var pendingCoordinatorReason: PowerHelperRefreshReason?
    /// Last helper availability observed for connection-drop → coordinator (PERF1-R3).
    @ObservationIgnored private var lastObservedAvailability: LidHelperAvailability?
    /// PERF1-R5: new closed-session start awaits persistence before acquire.
    @ObservationIgnored private var pendingSessionDurability = false
    /// C8-1／C8-4: block acquire until handshake applies recovery／forced-off evidence.
    @ObservationIgnored private var suppressAcquireForHandshake = false
    @ObservationIgnored private var sessionRestored = false
    @ObservationIgnored private var sessionRestorationTask: Task<Void, Never>?
    @ObservationIgnored private var sessionDurabilityTask: Task<Void, Never>?
    /// Mutations supersede reads immediately; new evidence waits for their completion.
    @ObservationIgnored private var mutationGeneration: UInt64?
    @ObservationIgnored private var removingHelper = false
    @ObservationIgnored private var evidenceReadEpoch: UInt64 = 0
    @ObservationIgnored private var evidenceReadTask: Task<PowerHelperStatus, Error>?

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
        sleepDisabledProbe: @escaping () async -> Bool? = {
            await SleepDisabledProbe.readSleepDisabledOffMainActor()
        },
        pauseDurationSeconds: @escaping () -> Double = { 3600 },
        heartbeatInterval: TimeInterval = PowerHelperConstants.heartbeatInterval,
        evidenceSleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
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
        self.evidenceSleep = evidenceSleep
        self.settings = SettingsStore.approvedLidGuardSettings(settingsStore.keepAwakeLidGuard)
        self.lidReading = lid.reading
        applyRestoredSession()
        lastObservedAvailability = helper.availability
        helper.onAvailabilityChange = { [weak self] in
            guard let self else { return }
            let previous = self.lastObservedAvailability
            let next = self.helper.availability
            self.lastObservedAvailability = next
            if next != .ready, var status = self.helperStatus {
                status.callerIsHolder = false
                self.helperStatus = status
            }
            // PERF1-R3: policy on every publish; handshake/backoff only on drop→connecting
            // (or via explicit refreshHelper entry points — not every callback).
            self.scheduleReevaluate()
            if case .connecting = next, previous == .ready {
                Task { @MainActor [weak self] in
                    await self?.refreshHelper(reason: .connectionInvalidated)
                }
            }
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

    /// Clears a user pause early (U02 "resume" button). Still subject to all policy gates.
    func resumeAfterPause() {
        guard state.userPausedUntil != nil else { return }
        state.userPausedUntil = nil
        scheduleReevaluate()
    }

    func restoreLeftover() {
        switch leftover {
        case .ownResidual:
            recoveryTask?.cancel()
            recoveryGeneration &+= 1
            let recovery = recoveryGeneration
            let generation = setGeneration
            recoveryTask = Task { [weak self] in
                guard let self else { return }
                let restored = await self.restoreOwnResidual(expectedGeneration: generation, expectedRecoveryGeneration: recovery)
                // NEW-2: clear residual presentation only on current-generation success.
                guard !self.shutDown, self.setGeneration == generation,
                      self.recoveryGeneration == recovery, !Task.isCancelled else { return }
                if restored {
                    self.leftover = nil
                    self.publish()
                }
            }
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

    /// C8-2: drop evidence wait after the same safe reset as Fi A2.
    private func clearAwaitingEvidenceIfSafe() {
        guard awaitingForcedOffEvidence else { return }
        guard !settings.enabled || !lastAgentModeActive || !lastBusy.isBusy else { return }
        awaitingForcedOffEvidence = false
        transientHelperError = nil
    }

    /// Sync set(false); returns within 1s even if helper is silent (§14.2).
    func shutdown() {
        guard !shutDown else { return }
        let deadline = ContinuousClock.now + .seconds(1)
        shutDown = true
        stopHeartbeat()
        cancelArmedEvidenceRetry(resetBackoff: false)
        handshakeTask?.cancel()
        handshakeTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        evidenceCoordinatorTask?.cancel()
        evidenceCoordinatorTask = nil
        invalidateEvidenceForMutation()
        mutationGeneration = nil
        removingHelper = false
        sessionRestorationTask?.cancel()
        sessionRestorationTask = nil
        sessionDurabilityTask?.cancel()
        sessionDurabilityTask = nil
        setGeneration &+= 1
        let shouldRelease =
            wantsSleepDisabled
            || helperStatus?.callerIsHolder == true
            || helperStatus?.setByHelper == true
        wantsSleepDisabled = false
        state.phase = .off
        persistSession()
        let drain = sessionStore.beginPendingDrain()
        // Never open a fresh XPC session just to no-op release (test host crash / C06 isolation).
        if !e2eNamedInstance, shouldRelease {
            _ = helper.setSleepDisabledSynchronously(false, timeout: max(0, remainingSeconds(until: deadline) - 0.005))
        }
        lid.setPollingEnabled(false)
        lid.stop()
        started = false
        _ = drain.wait(timeout: .now() + max(0, remainingSeconds(until: deadline) - 0.002))
    }

    private func remainingSeconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let parts = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    /// Read-only leftover probe allowed even when the option is off (§6.6 / §14.2).
    /// Named E2E instances never connect or repair.
    func detectLeftover() async {
        guard !e2eNamedInstance, !shutDown else { return }
        // A newer explicit detection supersedes an older detection's read.
        evidenceReadEpoch &+= 1
        evidenceReadTask?.cancel()
        evidenceReadTask = nil
        recoveryGeneration &+= 1
        let recovery = recoveryGeneration
        // PERF1-R3 round3: leftover SM refresh goes through the shared coordinator
        // (approval backoff / gates), then probe/status stay generation-gated.
        await refreshHelper(reason: .launch)
        guard !shutDown, !Task.isCancelled, recoveryGeneration == recovery else { return }
        // V1-4: capture lifecycle/generation before the first await so stale
        // probe/status completions cannot overwrite newer recovery evidence.
        let generation = setGeneration
        // V1-3: await off-MainActor probe (default hops via Task.detached).
        let probe = await sleepDisabledProbe()
        guard !shutDown, !Task.isCancelled, setGeneration == generation, recoveryGeneration == recovery else { return }
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
        case .requiresApproval:
            leftover = .unknownOwner
            publish()
            return
        default:
            leftover = .unknownOwner
            publish()
            return
        }

        do {
            let status = try await readHelperEvidence()
            guard !shutDown, !Task.isCancelled, setGeneration == generation, recoveryGeneration == recovery else { return }
            applyHelperStatus(status)
            classifyLeftover(from: status)
            if leftover == .ownResidual {
                let restored = await restoreOwnResidual(expectedGeneration: generation, expectedRecoveryGeneration: recovery)
                guard !shutDown, !Task.isCancelled, setGeneration == generation, recoveryGeneration == recovery else { return }
                if restored {
                    leftover = nil
                }
            }
        } catch {
            guard !shutDown, !Task.isCancelled, setGeneration == generation, recoveryGeneration == recovery else { return }
            leftover = .unknownOwner
        }
        publish()
    }

    func refreshFromHelper() async {
        guard !e2eNamedInstance, !shutDown else { return }
        recoveryGeneration &+= 1
        let recovery = recoveryGeneration
        // PERF1-R3: wake goes through the shared refresh/evidence coordinator.
        // PERF1-NEW-3: latch clear happens only inside performRefreshHelper after a
        // fresh successful healthy status — never from cached readiness alone.
        await refreshHelper(reason: .wake)
        guard !shutDown, !Task.isCancelled, recoveryGeneration == recovery else { return }
        // Reevaluate after the coordinator finishes so a latch cleared by fresh
        // evidence is applied; do not clear the latch here from cached readiness.
        scheduleReevaluate()
    }

    /// U01: install / remove / open Login Items. Never auto-register from tests.
    func registerHelper() async throws {
        guard !e2eNamedInstance, !shutDown, !removingHelper else { return }
        try await helper.register()
        // PERF1-R3 round3: user registration goes through the evidence coordinator so
        // requiresApproval starts SM-only backoff (not a bare reevaluate).
        await refreshHelper(reason: .userAction)
        guard !shutDown, !Task.isCancelled else { return }
        scheduleReevaluate()
    }

    func unregisterHelper() async throws {
        guard !e2eNamedInstance, !shutDown, !removingHelper else { return }
        // Bump generations so in-flight status/evidence cannot race removal.
        setGeneration &+= 1
        invalidateEvidenceForMutation()
        removingHelper = true
        stopHeartbeat()
        wantsSleepDisabled = false
        defer {
            removingHelper = false
            if !shutDown { resumePendingEvidence() }
        }
        try await helper.unregister()
        guard !shutDown, !Task.isCancelled else { return }
        removingHelper = false
        pendingCoordinatorReason = nil
        await refreshHelper(reason: .userAction)
        guard !shutDown, !Task.isCancelled else { return }
        scheduleReevaluate()
    }

    func openHelperApprovalSettings() {
        helper.openApprovalSettings()
    }

    func refreshHelperAvailability() {
        guard !e2eNamedInstance else { return }
        Task { @MainActor [weak self] in
            await self?.refreshHelperAvailabilityAsync(reason: .settingsOpened)
        }
    }

    /// Settings / UI: await cached/coalesced SM refresh (PERF-1).
    func refreshHelperAvailabilityAsync(reason: PowerHelperRefreshReason = .settingsOpened) async {
        await refreshHelper(reason: reason)
    }

    // MARK: - Private

    private func ensureStarted() {
        guard !started, !shutDown else { return }
        started = true
        if !e2eNamedInstance {
            lid.start()
            lidReading = lid.reading
            // PERF1-R3: one launch refresh/evidence coordinator (not a bare handshake).
            Task { @MainActor [weak self] in
                await self?.refreshHelper(reason: .launch)
            }
        }
    }

    /// PERF1-R3: single controller refresh/evidence entry for launch/wake/settings/user/drop/retry.
    /// Concurrent permitted events share one coordinator that drains the latest pending reason.
    private func refreshHelper(reason: PowerHelperRefreshReason) async {
        guard !e2eNamedInstance, !shutDown, !Task.isCancelled else { return }
        if mutationGeneration != nil || removingHelper {
            pendingCoordinatorReason = reason
            return
        }
        if let existing = evidenceCoordinatorTask, reason == .launch {
            await existing.value
            return
        }
        // Keep the newest reason (wake/settings must not be dropped behind a bare launch).
        if pendingCoordinatorReason == nil || reason != .launch {
            pendingCoordinatorReason = reason
        }
        if let existing = evidenceCoordinatorTask {
            let coord = evidenceCoordinatorGeneration
            await existing.value
            guard !shutDown, !Task.isCancelled, evidenceCoordinatorGeneration == coord else { return }
            // Owner may have exited its while-loop before observing our reason. Clear a
            // stale completed-task pointer so we can become owner and drain (PERF1-NEW-3).
            if evidenceCoordinatorTask == existing {
                evidenceCoordinatorTask = nil
            }
            if evidenceCoordinatorTask == nil, pendingCoordinatorReason != nil {
                await refreshHelper(reason: pendingCoordinatorReason ?? reason)
            }
            return
        }
        evidenceCoordinatorGeneration &+= 1
        let coord = evidenceCoordinatorGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while let next = self.pendingCoordinatorReason {
                self.pendingCoordinatorReason = nil
                guard !self.shutDown, !Task.isCancelled, self.evidenceCoordinatorGeneration == coord else { return }
                await self.performRefreshHelper(reason: next, coordinatorGeneration: coord)
            }
        }
        evidenceCoordinatorTask = task
        await task.value
        if evidenceCoordinatorTask == task {
            evidenceCoordinatorTask = nil
        }
    }

    private func performRefreshHelper(
        reason: PowerHelperRefreshReason,
        coordinatorGeneration coord: UInt64
    ) async {
        guard !shutDown, !Task.isCancelled, mutationGeneration == nil, !removingHelper else { return }
        let set = setGeneration
        await helper.refreshAvailability(reason: reason)
        guard evidenceIsCurrent(coord: coord, set: set) else { return }

        switch helper.availability {
        case .requiresApproval:
            // Approval: SM-only retries; never XPC/acquire until enabled.
            scheduleEvidenceRetry()
            scheduleReevaluate()
        case .connecting:
            guard helper.hasEnabledServiceEvidence else {
                scheduleEvidenceRetry()
                scheduleReevaluate()
                return
            }
            await runHelperHandshake(coordinatorGeneration: coord)
            guard evidenceIsCurrent(coord: coord, set: set) else { return }
            if hasRecoveryHealthBlock || awaitingForcedOffEvidence {
                scheduleEvidenceRetry()
            } else if case .connecting = helper.availability {
                scheduleEvidenceRetry()
            } else if case .ready = helper.availability {
                cancelArmedEvidenceRetry(resetBackoff: true)
            } else if case .requiresApproval = helper.availability {
                scheduleEvidenceRetry()
            }
            scheduleReevaluate()
        case .ready:
            // Launch leaves a healthy ready connection alone (handshake already done).
            // Wake/settings/user/retry/drop and known recovery/forced-off take one read-only status.
            let shouldReadEvidence: Bool = {
                switch reason {
                case .wake, .settingsOpened, .userAction, .connectionInvalidated, .retry:
                    // Always refresh evidence on these events (incl. forced-off latch).
                    return true
                case .launch:
                    // Leftover recovery flags only — forced-off latch is owned by
                    // gatherEvidence + wake/retry so launch cannot race those status() calls.
                    return hasRecoveryHealthBlock
                }
            }()
            if shouldReadEvidence {
                do {
                    let status = try await readHelperEvidence()
                    guard evidenceIsCurrent(coord: coord, set: set) else { return }
                    applyHelperStatus(status)
                    considerRecoveryHealth(from: status)
                    handleForcedOffIfNeeded(status)
                    considerExternalInterference(from: status)
                    // Fresh healthy evidence clears the post-failure wait before reevaluate.
                    if !hasRecoveryHealthBlock, !externalInterferenceLatched,
                       status.lastForcedOffReason == nil || status.lastForcedOffReason?.isEmpty == true
                    {
                        awaitingForcedOffEvidence = false
                        transientHelperError = nil
                        // PERF1-NEW-4: cancel any armed retry — healthy idle must not refresh again.
                        cancelArmedEvidenceRetry(resetBackoff: true)
                    }
                } catch {
                    guard evidenceIsCurrent(coord: coord, set: set) else { return }
                    Self.log.notice("Lid Guard recovery evidence status failed: \(String(describing: error))")
                    // PERF1-NEW-3: failed reads revoke hold confirmation; keep evidence latch.
                    revokeHoldConfirmationAfterFailedRead()
                    scheduleEvidenceRetry()
                    scheduleReevaluate()
                    return
                }
                if hasRecoveryHealthBlock || awaitingForcedOffEvidence {
                    scheduleEvidenceRetry()
                } else {
                    cancelArmedEvidenceRetry(resetBackoff: true)
                }
            }
            scheduleReevaluate()
        case .notRegistered, .notFound:
            // No automatic SM backoff for absent registration — user action / approval path only.
            scheduleReevaluate()
        case .error, .versionMismatch:
            scheduleEvidenceRetry()
            scheduleReevaluate()
        }
    }

    /// Bounded status() handshake so production can leave `.connecting` (C8-1).
    private func ensureHelperHandshake() {
        guard !e2eNamedInstance, !shutDown else { return }
        guard case .connecting = helper.availability else { return }
        guard handshakeTask == nil else { return }
        let coord = evidenceCoordinatorGeneration
        handshakeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.handshakeTask = nil }
            await self.runHelperHandshake(coordinatorGeneration: coord)
            if !self.shutDown { self.scheduleReevaluate() }
        }
    }

    private func runHelperHandshake(coordinatorGeneration coord: UInt64) async {
        guard !e2eNamedInstance, !shutDown else { return }
        guard case .connecting = helper.availability else { return }
        // Single-flight: suppressAcquire marks an in-progress handshake from refreshHelper.
        if suppressAcquireForHandshake { return }
        suppressAcquireForHandshake = true
        let set = setGeneration
        defer { if evidenceCoordinatorGeneration == coord { suppressAcquireForHandshake = false } }
        do {
            let status = try await readHelperEvidence()
            guard evidenceIsCurrent(coord: coord, set: set) else { return }
            applyHelperStatus(status)
            handleForcedOffIfNeeded(status)
            considerExternalInterference(from: status)
            considerRecoveryHealth(from: status)
        } catch {
            guard evidenceIsCurrent(coord: coord, set: set) else { return }
            Self.log.notice("Lid Guard helper handshake failed: \(String(describing: error))")
            scheduleEvidenceRetry()
        }
    }

    private func evidenceIsCurrent(coord: UInt64, set: UInt64) -> Bool {
        !shutDown && !Task.isCancelled && evidenceCoordinatorGeneration == coord
            && setGeneration == set && mutationGeneration == nil && !removingHelper
    }

    /// All controller status paths share this read. A release supersedes it without
    /// waiting for a delayed reply; both outcomes are rejected after supersession.
    private func readHelperEvidence() async throws -> PowerHelperStatus {
        guard !shutDown, !Task.isCancelled, mutationGeneration == nil, !removingHelper,
              helper.hasEnabledServiceEvidence else {
            throw CancellationError()
        }
        let epoch = evidenceReadEpoch
        let task: Task<PowerHelperStatus, Error>
        if let existing = evidenceReadTask { task = existing }
        else {
            task = Task { @MainActor [helper] in try await helper.status() }
            evidenceReadTask = task
        }
        defer { if evidenceReadEpoch == epoch, evidenceReadTask == task { evidenceReadTask = nil } }
        do {
            let status = try await task.value
            guard !shutDown, !Task.isCancelled, epoch == evidenceReadEpoch else { throw CancellationError() }
            return status
        } catch {
            guard !shutDown, !Task.isCancelled, epoch == evidenceReadEpoch else { throw CancellationError() }
            throw error
        }
    }

    private func invalidateEvidenceForMutation(invalidateRecovery: Bool = true) {
        evidenceReadEpoch &+= 1
        evidenceCoordinatorGeneration &+= 1
        if invalidateRecovery { recoveryGeneration &+= 1 }
        evidenceReadTask?.cancel()
        evidenceReadTask = nil
        evidenceCoordinatorTask?.cancel()
        evidenceCoordinatorTask = nil
        pendingCoordinatorReason = nil
        suppressAcquireForHandshake = false
        cancelArmedEvidenceRetry(resetBackoff: false)
    }

    private func resumePendingEvidence() {
        guard !shutDown, mutationGeneration == nil, !removingHelper,
              let reason = pendingCoordinatorReason else { return }
        pendingCoordinatorReason = nil
        Task { @MainActor [weak self] in await self?.refreshHelper(reason: reason) }
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
        if !sessionRestored { applyRestoredSession() }
        clearExternalInterferenceLatchIfSafe()
        clearAwaitingEvidenceIfSafe()
        // PERF-1: reevaluate never kicks SM refresh or handshake — only cached evidence.

        let recoveryBlockedAcquire = hasRecoveryHealthBlock
        let helperAvailability: LidHelperAvailability = {
            if externalInterferenceLatched {
                return .error("externalInterference")
            }
            if awaitingForcedOffEvidence {
                return .error("awaitingForcedOffEvidence")
            }
            if recoveryBlockedAcquire {
                return .error("recoveryBlocked")
            }
            // Keep policy in connecting while handshake applies evidence (C8-1／C8-4).
            if suppressAcquireForHandshake { return .connecting }
            if !sessionRestored || removingHelper { return .connecting }
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
        if externalInterferenceLatched || awaitingForcedOffEvidence || recoveryBlockedAcquire
            || suppressAcquireForHandshake
            || !sessionRestored || removingHelper
            || (mutationGeneration != nil && !wantsSleepDisabled)
        {
            wants = false
        }
        applyPolicyResult(state: result.state, wants: wants, events: result.events)
    }

    /// C8-4: recovery health from any cached status forbids ordinary acquire.
    private var hasRecoveryHealthBlock: Bool {
        recoveryHealthBlocked
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
                if externalInterferenceLatched || awaitingForcedOffEvidence || hasRecoveryHealthBlock
                    || suppressAcquireForHandshake
                {
                    wantsSleepDisabled = false
                } else if pendingSessionDurability {
                    // PERF1-R5: await first-start durability before acquisition.
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
        } else if wants,
                  (externalInterferenceLatched || awaitingForcedOffEvidence || hasRecoveryHealthBlock
                      || suppressAcquireForHandshake)
        {
            wantsSleepDisabled = false
            stopHeartbeat()
        }

        handleEvents(events)
        publish()
    }

    private func requestSet(_ on: Bool) {
        guard !e2eNamedInstance, !shutDown, !removingHelper else { return }
        if on, pendingSessionDurability || !sessionRestored { return }
        if on, mutationGeneration != nil { return }
        if on, externalInterferenceLatched || awaitingForcedOffEvidence || hasRecoveryHealthBlock
            || suppressAcquireForHandshake
        {
            return
        }
        switch helper.availability {
        case .ready:
            break
        case .connecting:
            // PERF-1: never kick handshake/SM from requestSet — event-driven evidence only.
            if on {
                scheduleEvidenceRetry()
                return
            }
        default:
            if on {
                transientHelperError = "helper not ready"
                scheduleEvidenceRetry()
                scheduleReevaluate()
            }
            return
        }
        invalidateEvidenceForMutation()
        setGeneration &+= 1
        let generation = setGeneration
        mutationGeneration = generation
        Task { @MainActor [weak self] in
            guard let self, !self.shutDown, self.setGeneration == generation else { return }
            defer {
                if self.mutationGeneration == generation {
                    self.mutationGeneration = nil
                    self.resumePendingEvidence()
                    if self.awaitingForcedOffEvidence || self.hasRecoveryHealthBlock { self.scheduleEvidenceRetry() }
                    if !self.shutDown { self.scheduleReevaluate() }
                }
            }
            if on, self.externalInterferenceLatched || self.awaitingForcedOffEvidence
                || self.hasRecoveryHealthBlock || self.suppressAcquireForHandshake
            {
                return
            }
            do {
                let status = try await self.helper.setSleepDisabled(on)
                guard self.setGeneration == generation, !self.shutDown, !Task.isCancelled else { return }
                if on {
                    self.transientHelperError = nil
                    self.awaitingForcedOffEvidence = false
                    self.cancelArmedEvidenceRetry(resetBackoff: true)
                }
                self.applyHelperStatus(status)
                self.handleForcedOffIfNeeded(status)
                self.considerExternalInterference(from: status)
                self.considerRecoveryHealth(from: status)
                if on, !self.externalInterferenceLatched, !self.hasRecoveryHealthBlock {
                    self.maybeNotifyArmedConfirmed()
                }
                self.scheduleReevaluate()
            } catch {
                guard self.setGeneration == generation, !self.shutDown, !Task.isCancelled else { return }
                if on {
                    self.mutationGeneration = nil
                    self.transientHelperError = String(describing: error)
                    self.stopHeartbeat()
                    // C8-2: gather forced-off evidence before any reacquire retry.
                    await self.gatherEvidenceAfterFailedAcquire()
                    guard self.setGeneration == generation, !self.shutDown, !Task.isCancelled else { return }
                    if !self.externalInterferenceLatched, !self.awaitingForcedOffEvidence {
                        self.scheduleRetry()
                    }
                    self.scheduleReevaluate()
                }
            }
        }
    }

    /// C8-2 / Fi A2: after failed holding set, require status evidence before retry.
    private func gatherEvidenceAfterFailedAcquire() async {
        let generation = setGeneration
        invalidateEvidenceForMutation()
        mutationGeneration = generation
        awaitingForcedOffEvidence = true
        wantsSleepDisabled = false
        awaitingArmedConfirm = false
        stopHeartbeat()
        // A failed/lost acquire reply can still leave our holder alive. Release before
        // probing, serially, so the client's generation does not invalidate either call.
        do {
            let released = try await helper.setSleepDisabled(false)
            guard !shutDown, !Task.isCancelled, setGeneration == generation else { return }
            applyHelperStatus(released)
            handleForcedOffIfNeeded(released)
            considerExternalInterference(from: released)
            considerRecoveryHealth(from: released)
        } catch {
            guard !shutDown, !Task.isCancelled, setGeneration == generation else { return }
            Self.log.notice("Lid Guard release after failed acquire failed: \(String(describing: error))")
        }
        guard !shutDown, !Task.isCancelled, setGeneration == generation else { return }
        mutationGeneration = nil
        do {
            let status = try await readHelperEvidence()
            guard !shutDown, !Task.isCancelled, setGeneration == generation else { return }
            applyHelperStatus(status)
            handleForcedOffIfNeeded(status)
            considerExternalInterference(from: status)
            considerRecoveryHealth(from: status)
            awaitingForcedOffEvidence = false
            if externalInterferenceLatched || hasRecoveryHealthBlock {
                return
            }
            // Fresh evidence is clear; a bounded retry may acquire again.
        } catch {
            guard !shutDown, !Task.isCancelled, setGeneration == generation else { return }
            // No evidence → remain nonholding; do not clear error or reacquire.
            // PERF1-NEW-3: revoke cached hold confirmation on failed evidence reads.
            revokeHoldConfirmationAfterFailedRead()
            Self.log.notice(
                "Lid Guard failed to obtain forced-off evidence: \(String(describing: error))"
            )
        }
    }

    private func scheduleRetry() {
        scheduleEvidenceRetry()
    }

    /// PERF1-NEW-3: failed status/evidence reads drop cached hold confirmation so
    /// policy cannot reacquire from stale callerIsHolder while availability stays ready.
    private func revokeHoldConfirmationAfterFailedRead() {
        let shouldRelease = wantsSleepDisabled || helperStatus?.callerIsHolder == true
        awaitingForcedOffEvidence = true
        transientHelperError = "statusUnavailable"
        wantsSleepDisabled = false
        awaitingArmedConfirm = false
        stopHeartbeat()
        if var status = helperStatus {
            status.callerIsHolder = false
            helperStatus = status
        }
        if shouldRelease { requestSet(false) }
        // Keep awaitingForcedOffEvidence / recoveryHealthBlocked — those require fresh evidence.
    }

    /// PERF1-NEW-4: invalidate an armed sleeping retry so healthy idle issues zero further refreshes.
    private func cancelArmedEvidenceRetry(resetBackoff: Bool) {
        evidenceRetryGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil
        if resetBackoff {
            evidenceRetryIndex = 0
            nextRetryDelay = 5
        }
    }

    /// PERF-1: single evidence/recovery retry chain (5→300s). Continuation of a prior
    /// permitted refresh — never started by reevaluate itself.
    /// Settings-open / duplicate schedule while a chain is armed must not reset backoff (PERF1-R3).
    private func scheduleEvidenceRetry() {
        guard !shutDown, !Task.isCancelled, !removingHelper else { return }
        guard !externalInterferenceLatched else { return }
        guard retryTask == nil else { return }
        let delays: [TimeInterval] = [5, 10, 20, 40, 80, 160, 300]
        let delay = evidenceRetryIndex < delays.count
            ? delays[evidenceRetryIndex]
            : maxRetryDelay
        evidenceRetryIndex = min(evidenceRetryIndex + 1, delays.count)
        nextRetryDelay = delay
        let generation = evidenceRetryGeneration
        retryTask = Task { @MainActor [weak self] in
            await self?.evidenceSleep(delay)
            guard let self else { return }
            // PERF1-NEW-4: generation bump invalidates even when the sleep gate is injected.
            guard generation == self.evidenceRetryGeneration else { return }
            self.retryTask = nil
            guard !Task.isCancelled, !self.shutDown else { return }
            guard !self.externalInterferenceLatched else { return }
            // PERF1-R3 round3: retries go through the shared refresh/evidence coordinator
            // (SM-only for approval, read-only status for recovery) with lifecycle gates.
            await self.refreshHelper(reason: .retry)
            guard generation == self.evidenceRetryGeneration, !Task.isCancelled, !self.shutDown else { return }
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        guard !externalInterferenceLatched, !awaitingForcedOffEvidence, !hasRecoveryHealthBlock else {
            return
        }
        let interval = heartbeatInterval
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, !Task.isCancelled, !self.shutDown else { return }
                guard self.wantsSleepDisabled,
                      !self.externalInterferenceLatched,
                      !self.awaitingForcedOffEvidence,
                      !self.hasRecoveryHealthBlock
                else { return }
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
        recoveryHealthBlocked = status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded
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
            cancelArmedEvidenceRetry(resetBackoff: false)
            awaitingForcedOffEvidence = false
            return
        }
        externalInterferenceLatched = true
        awaitingForcedOffEvidence = false
        awaitingArmedConfirm = false
        wantsSleepDisabled = false
        stopHeartbeat()
        cancelArmedEvidenceRetry(resetBackoff: false)
        if requestRelease {
            requestSet(false)
        }
        Self.log.notice("Lid Guard latched externalInterference — no further set(true)")
    }

    /// C8-4: recovery flags on every status path → leftover + manual guidance; never foreign.
    private func considerRecoveryHealth(from status: PowerHelperStatus) {
        if status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded {
            leftover = .recoveryBlocked
            if !didNotifyLeftoverRecovery {
                didNotifyLeftoverRecovery = true
                notifier.notifyLeftoverRecoveryNeeded()
            }
            awaitingArmedConfirm = false
            let shouldRelease = wantsSleepDisabled
            wantsSleepDisabled = false
            stopHeartbeat()
            if shouldRelease { requestSet(false) }
            return
        }
        if leftover == .recoveryBlocked {
            leftover = nil
        }
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

    /// V1-4: direct bounded set(false) for verified own residuals (helper forceOff path).
    /// No new acquire; every await completion gated by lifecycle/generation.
    @discardableResult
    private func restoreOwnResidual(
        expectedGeneration: UInt64, expectedRecoveryGeneration: UInt64
    ) async -> Bool {
        guard !e2eNamedInstance, !shutDown else { return false }
        guard setGeneration == expectedGeneration,
              recoveryGeneration == expectedRecoveryGeneration, !Task.isCancelled else { return false }
        guard mutationGeneration == nil, !removingHelper else { return false }
        // Never acquire-as-repair while recovery is blocked (Fi A8 / C8-4).
        if let status = helperStatus,
           status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded {
            return false
        }
        invalidateEvidenceForMutation(invalidateRecovery: false)
        mutationGeneration = expectedGeneration
        defer {
            if mutationGeneration == expectedGeneration {
                mutationGeneration = nil
                resumePendingEvidence()
            }
        }
        do {
            let after = try await helper.setSleepDisabled(false)
            guard !shutDown, setGeneration == expectedGeneration,
                  recoveryGeneration == expectedRecoveryGeneration, !Task.isCancelled else { return false }
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
        case .loading:
            guard sessionRestorationTask == nil, !shutDown else { return }
            let store = sessionStore
            sessionRestorationTask = Task { @MainActor [weak self] in
                await store.awaitLoaded()
                guard let self, !self.shutDown, !Task.isCancelled else { return }
                self.sessionRestorationTask = nil
                self.applyRestoredSession()
                self.scheduleReevaluate()
            }
            return
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
        sessionRestored = true
    }

    private func persistSession() {
        guard sessionRestored else { return }
        if let since = state.lidClosedSince, let boot = LidMonotonicTime.bootSessionUUID() {
            let isNewStart = sessionStore.save(
                continuousClosedAt: since,
                bootSessionUUID: boot,
                maxDurationLatched: state.maxDurationLatched
            )
            if isNewStart || sessionStore.hasPendingDurability {
                pendingSessionDurability = true
                ensureSessionDurabilityWaiter()
            }
        } else if lid.reading == .open {
            pendingSessionDurability = false
            sessionStore.clear()
        }
    }

    private func ensureSessionDurabilityWaiter() {
        guard pendingSessionDurability, sessionDurabilityTask == nil, !shutDown else { return }
        let store = sessionStore
        sessionDurabilityTask = Task { @MainActor [weak self] in
            await store.flushPending()
            guard let self, !self.shutDown, !Task.isCancelled else { return }
            self.pendingSessionDurability = false
            self.sessionDurabilityTask = nil
            self.scheduleReevaluate()
        }
    }

    private func publish() {
        guard !suppressOnChange else { return }
        onChange?()
    }
}
