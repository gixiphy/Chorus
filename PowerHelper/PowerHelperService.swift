import ChorusCore
import Foundation

/// Core helper orchestration: ledger + pmset + safety + watchdog (spec §6.3 / §14.1).
///
/// Ledger mutations and timers run on `queue`. All pmset I/O runs on `ioQueue` so
/// watchdog / safety / forceOff stay responsive while a runner is wedged (W1-1 / V-C05-2).
/// Reads are coalesced; writes check generation **before** side effects; restore/forceOff
/// outranks acquire. Completions hop back to `queue` and honor `applyGeneration`.
final class PowerHelperService: NSObject, @unchecked Sendable {
    typealias IdleExitHandler = () -> Void
    typealias NowProvider = () -> Double

    private let queue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let runner: PMSetRunning
    private let store: LedgerStoring
    private let safety: HelperPowerSafetyChecking
    private let helperBuild: String
    private let isRelease: Bool
    private let now: NowProvider
    private let idleExitDelay: TimeInterval
    private let onIdleExit: IdleExitHandler

    private var ledger = SleepGuardLedger()
    private var lastForcedOffReason: String?
    private var lastChangeAt: Date?
    private var nextConnectionID: UInt64 = 1
    private var connections: [UInt64: NSXPCConnection] = [:]
    /// Last *external* activity (XPC accept / set / status) — not watchdog ticks (W1-9).
    private var lastExternalActivity = Date()
    private var watchdogTimer: DispatchSourceTimer?
    private var safetyTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private let generationLock = NSLock()
    private var _applyGeneration: UInt64 = 0
    private var applyGeneration: UInt64 {
        get { generationLock.lock(); defer { generationLock.unlock() }; return _applyGeneration }
        set { generationLock.lock(); _applyGeneration = newValue; generationLock.unlock() }
    }
    /// Persist failure after a verified system write — keep retrying; block idle exit (W1-8/9).
    private var persistRetryNeeded = false
    /// Launch reconcile finished (W1-15) — XPC handlers wait without same-queue semaphores.
    private var startupReady = false
    private var startupWaiters: [() -> Void] = []
    /// Coalesced read waiters (W1-1): one physical `pmset -g` serves many callers.
    private var readWaiters: [(generation: UInt64, completion: (Bool?) -> Void)] = []
    private var readInFlight = false
    private var restorationInProgress = false
    private var deferredDisconnects: Set<UInt64> = []
    private var pendingSafetyReason: String?

    /// Exported per-connection XPC object (separate instance each accept — V-C05 / tasks §4).
    final class ExportedObject: NSObject, ChorusPowerHelperXPC, @unchecked Sendable {
        private weak var service: PowerHelperService?
        private let connectionID: UInt64
        private let uid: UInt32
        private let pid: Int32

        init(service: PowerHelperService, connectionID: UInt64, uid: UInt32, pid: Int32) {
            self.service = service
            self.connectionID = connectionID
            self.uid = uid
            self.pid = pid
        }

        func setSleepDisabled(
            _ enabled: Bool,
            withReply reply: @escaping (Data?, String?) -> Void
        ) {
            service?.handleSet(enabled, connectionID: connectionID, uid: uid, pid: pid, reply: reply)
        }

        func status(withReply reply: @escaping (Data) -> Void) {
            service?.handleStatus(connectionID: connectionID, reply: reply)
        }
    }

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.hermes.Chorus.PowerHelper.ledger"),
        ioQueue: DispatchQueue = DispatchQueue(label: "com.hermes.Chorus.PowerHelper.io"),
        runner: PMSetRunning,
        store: LedgerStoring,
        safety: HelperPowerSafetyChecking,
        helperBuild: String,
        isRelease: Bool = false,
        now: @escaping NowProvider = { MonotonicTime.seconds() },
        idleExitDelay: TimeInterval = PowerHelperConstants.idleExitDelay,
        onIdleExit: @escaping IdleExitHandler = { exit(0) }
    ) {
        self.queue = queue
        self.ioQueue = ioQueue
        self.runner = runner
        self.store = store
        self.safety = safety
        self.helperBuild = helperBuild
        self.isRelease = isRelease
        self.now = now
        self.idleExitDelay = idleExitDelay
        self.onIdleExit = onIdleExit
        super.init()
    }

    var clientRequirementString: String {
        PowerHelperConstants.clientRequirement(forRelease: isRelease)
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.beginAsyncReconcile { [weak self] in
                guard let self else { return }
                self.markStartupReady()
            }
            self.installWatchdog()
            self.installSafetyTimer()
            self.touchExternalActivityAndRescheduleIdle()
        }
    }

    func stopTimersForTesting() {
        queue.sync {
            watchdogTimer?.cancel()
            safetyTimer?.cancel()
            idleTimer?.cancel()
            watchdogTimer = nil
            safetyTimer = nil
            idleTimer = nil
        }
    }

    func ledgerSnapshotForTesting() -> SleepGuardLedger {
        queue.sync { ledger }
    }

    func persistRetryNeededForTesting() -> Bool {
        queue.sync { persistRetryNeeded }
    }

    func startupReadyForTesting() -> Bool {
        queue.sync { startupReady }
    }

    func runWatchdogTickForTesting() {
        queue.sync { runWatchdogTick() }
    }

    func runSafetyTickForTesting() {
        queue.sync { runSafetyTick() }
    }

    func checkIdleForTesting() {
        queue.sync { evaluateIdleExit() }
    }

    // MARK: - NSXPCListenerDelegate helpers

    func shouldAccept(connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        let pid = connection.processIdentifier
        let id: UInt64 = queue.sync {
            let assigned = nextConnectionID
            nextConnectionID += 1
            connections[assigned] = connection
            touchExternalActivityAndRescheduleIdle()
            return assigned
        }

        let exported = ExportedObject(service: self, connectionID: id, uid: uid, pid: pid)
        connection.exportedInterface = NSXPCInterface(with: ChorusPowerHelperXPC.self)
        connection.exportedObject = exported
        connection.invalidationHandler = { [weak self] in
            self?.handleDisconnect(connectionID: id)
        }
        connection.interruptionHandler = { [weak self] in
            self?.handleDisconnect(connectionID: id)
        }
        connection.resume()
        return true
    }

    // MARK: - XPC handlers

    private func handleSet(
        _ enabled: Bool,
        connectionID: UInt64,
        uid: UInt32,
        pid: Int32,
        reply: @escaping (Data?, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenStartupReady {
                self.touchExternalActivityAndRescheduleIdle()

                if enabled {
                    if self.restorationInProgress {
                        if let refuse = self.safety.snapshot().refusesAcquire {
                            self.pendingSafetyReason = refuse.forcedOffReason
                            reply(nil, refuse.errorCode)
                        } else {
                            reply(nil, "restorationInProgress")
                        }
                        return
                    }
                    if let refuse = self.safety.snapshot().refusesAcquire {
                        self.lastForcedOffReason = refuse.forcedOffReason
                        // W1-7 / A3: unsafe heartbeat must release an existing own holding.
                        if self.ledger.holders[connectionID] != nil || self.ledger.setByHelper {
                            self.initiateProtectedForceOff(reason: refuse.forcedOffReason) {
                                reply(nil, refuse.errorCode)
                            }
                        } else {
                            // W1-1: do not bump applyGeneration on refuse-only (no side effects).
                            reply(nil, refuse.errorCode)
                        }
                        return
                    }

                    let generation = self.beginApply()
                    self.readSystemValue(generation: generation) { systemValue in
                        self.queue.async {
                            guard generation == self.applyGeneration else {
                                reply(nil, "superseded")
                                return
                            }
                            self.continueAcquire(
                                connectionID: connectionID,
                                uid: uid,
                                pid: pid,
                                systemValue: systemValue,
                                generation: generation,
                                reply: reply
                            )
                        }
                    }
                } else {
                    guard !self.restorationInProgress else {
                        reply(nil, "restorationInProgress")
                        return
                    }
                    self.restorationInProgress = true
                    let generation = self.beginApply()
                    self.readSystemValue(generation: generation) { systemValue in
                        self.queue.async {
                            guard generation == self.applyGeneration else {
                                reply(nil, "superseded")
                                return
                            }
                            // W1-6: zero-holder own residual / pendingRestore must still write(false).
                            // ledger.release returns .none when the caller is absent.
                            let action: SleepGuardLedger.Action
                            if self.ledger.holders[connectionID] != nil {
                                action = self.ledger.release(
                                    connectionID: connectionID,
                                    currentSystemValue: systemValue
                                )
                            } else if self.ledger.holders.isEmpty, self.ledger.setByHelper || self.ledger.pendingRestore {
                                action = self.ledger.forceOff(currentSystemValue: systemValue)
                            } else {
                                action = .none
                            }
                            self.applyAction(action, generation: generation) { outcome in
                                self.finishRestoration()
                                self.finishReply(outcome, connectionID: connectionID, reply: reply)
                            }
                        }
                    }
                }
            }
        }
    }

    private func continueAcquire(
        connectionID: UInt64,
        uid: UInt32,
        pid: Int32,
        systemValue: Bool?,
        generation: UInt64,
        reply: @escaping (Data?, String?) -> Void
    ) {
        // Restore-before-reacquire (C03 handoff).
        if ledger.pendingRestore, ledger.setByHelper, ledger.holders.isEmpty {
            applyAction(.write(false), generation: generation) { [weak self] outcome in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.applyGeneration else {
                        reply(nil, "superseded")
                        return
                    }
                    switch outcome {
                    case .ok:
                        self.readSystemValue(generation: generation) { refreshed in
                            self.queue.async {
                                guard generation == self.applyGeneration else {
                                    reply(nil, "superseded")
                                    return
                                }
                                self.finishAcquireAfterRestore(
                                    connectionID: connectionID,
                                    uid: uid,
                                    pid: pid,
                                    systemValue: refreshed,
                                    generation: generation,
                                    reply: reply
                                )
                            }
                        }
                    case let .error(code):
                        reply(nil, code)
                    }
                }
            }
            return
        }

        finishAcquireAfterRestore(
            connectionID: connectionID,
            uid: uid,
            pid: pid,
            systemValue: systemValue,
            generation: generation,
            reply: reply
        )
    }

    private func finishAcquireAfterRestore(
        connectionID: UInt64,
        uid: UInt32,
        pid: Int32,
        systemValue: Bool?,
        generation: UInt64,
        reply: @escaping (Data?, String?) -> Void
    ) {
        if ledger.recoveryBlocked {
            reply(nil, "recoveryBlocked")
            return
        }
        let action = ledger.acquire(
            connectionID: connectionID,
            uid: uid,
            pid: pid,
            now: now(),
            currentSystemValue: systemValue
        )
        applyAction(action, generation: generation, rollbackConnectionID: connectionID) { [weak self] outcome in
            self?.finishReply(outcome, connectionID: connectionID, reply: reply)
        }
    }

    private func finishReply(
        _ outcome: ApplyOutcome,
        connectionID: UInt64,
        reply: @escaping (Data?, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            switch outcome {
            case .ok:
                self.readSystemValue(generation: self.applyGeneration) { systemValue in
                    self.queue.async {
                        let data = self.encodeStatus(callerID: connectionID, systemValue: systemValue)
                        if self.persistRetryNeeded {
                            reply(data, "storeFailed")
                        } else {
                            reply(data, nil)
                        }
                    }
                }
            case let .error(code):
                reply(nil, code)
            }
        }
    }

    private func handleStatus(connectionID: UInt64, reply: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenStartupReady {
                self.touchExternalActivityAndRescheduleIdle()
                let generation = self.applyGeneration
                self.readSystemValue(generation: generation) { systemValue in
                    self.queue.async {
                        reply(self.encodeStatus(callerID: connectionID, systemValue: systemValue))
                    }
                }
            }
        }
    }

    private func handleDisconnect(connectionID: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.whenStartupReady {
                if self.restorationInProgress {
                    self.deferredDisconnects.insert(connectionID)
                    return
                }
                self.restorationInProgress = true
                self.connections.removeValue(forKey: connectionID)
                let generation = self.beginApply()
                self.readSystemValue(generation: generation) { systemValue in
                    self.queue.async {
                        guard generation == self.applyGeneration else { return }
                        let action = self.ledger.dropConnection(connectionID, currentSystemValue: systemValue)
                        if action != .none {
                            self.lastForcedOffReason = "disconnect"
                            self.lastChangeAt = Date()
                        }
                        self.applyAction(action, generation: generation) { _ in
                            self.queue.async {
                                self.finishRestoration()
                                self.touchExternalActivityAndRescheduleIdle()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Launch reconcile (W1-15)

    private func beginAsyncReconcile(completion: @escaping () -> Void) {
        let generation = beginApply()
        ioQueue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            let systemValue = try? self.runner.readSleepDisabled()
            self.queue.async {
                let persisted: SleepGuardLedger?
                do {
                    persisted = try self.store.load()
                } catch {
                    persisted = nil
                    if systemValue != false {
                        let (blocked, action) = SleepGuardLedger.reconcileOnLaunch(
                            persisted: nil,
                            currentSystemValue: systemValue
                        )
                        self.ledger = blocked
                        self.applyAction(action, generation: generation) { _ in
                            self.queue.async(execute: completion)
                        }
                        return
                    }
                }

                let (restored, action) = SleepGuardLedger.reconcileOnLaunch(
                    persisted: persisted,
                    currentSystemValue: systemValue
                )
                self.ledger = restored
                if case .write(false) = action {
                    self.lastForcedOffReason = "bootReconcile"
                    self.lastChangeAt = Date()
                }
                if action == .none {
                    // Persist reconciled metadata even when no pmset write (launch baseline).
                    _ = self.persistAfterMutation()
                    completion()
                    return
                }
                self.applyAction(action, generation: generation) { _ in
                    self.queue.async(execute: completion)
                }
            }
        }
    }

    private func markStartupReady() {
        startupReady = true
        let waiters = startupWaiters
        startupWaiters.removeAll()
        for waiter in waiters {
            waiter()
        }
    }

    private func whenStartupReady(_ body: @escaping () -> Void) {
        if startupReady {
            body()
        } else {
            startupWaiters.append(body)
        }
    }

    // MARK: - Apply ledger actions (async I/O)

    private enum ApplyOutcome {
        case ok
        case error(String)
    }

    private func beginApply() -> UInt64 {
        generationLock.lock()
        _applyGeneration += 1
        let value = _applyGeneration
        generationLock.unlock()
        return value
    }

    /// Coalesced reads: one physical read drains all waiters (W1-1).
    private func readSystemValue(generation: UInt64, completion: @escaping (Bool?) -> Void) {
        // Bound admission even while a subprocess is delayed. Unknown evidence fails closed.
        guard readWaiters.count < 64 else { completion(nil); return }
        readWaiters.append((generation, completion))
        guard !readInFlight else { return }
        readInFlight = true
        scheduleReadFlush()
    }

    private func scheduleReadFlush() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let value = try? self.runner.readSleepDisabled()
            self.queue.async {
                let waiters = self.readWaiters
                self.readWaiters.removeAll()
                self.readInFlight = false
                for (_, completion) in waiters {
                    completion(value)
                }
                if !self.readWaiters.isEmpty {
                    self.readInFlight = true
                    self.scheduleReadFlush()
                }
            }
        }
    }

    private func applyAction(
        _ action: SleepGuardLedger.Action,
        generation: UInt64,
        rollbackConnectionID: UInt64? = nil,
        completion: @escaping (ApplyOutcome) -> Void
    ) {
        // Must be called from ledger queue.
        if case .write(false) = action, !restorationInProgress {
            restorationInProgress = true
            applyAction(action, generation: generation, rollbackConnectionID: rollbackConnectionID) { outcome in
                self.finishRestoration()
                completion(outcome)
            }
            return
        }
        guard generation == applyGeneration else {
            completion(.ok) // superseded — treat as no-op success for caller discard
            return
        }
        switch action {
        case .none:
            let outcome = persistAfterMutation()
            rearmIdleAfterStateChange()
            completion(outcome)
        case let .write(enabled):
            if enabled {
                ledger.setByHelper = true
                ledger.pendingRestore = false
                do {
                    try store.save(ledger)
                    persistRetryNeeded = false
                } catch {
                    ledger.noteWriteFailure()
                    if let rollbackConnectionID {
                        _ = ledger.holders.removeValue(forKey: rollbackConnectionID)
                        if ledger.holders.isEmpty, !ledger.pendingRestore {
                            ledger.setByHelper = false
                            ledger.priorValueWasDisabled = nil
                        }
                    }
                    completion(.error("storeFailed"))
                    return
                }
            }
            ioQueue.async { [weak self] in
                guard let self else {
                    completion(.error("pmsetFailed"))
                    return
                }
                // W1-1: cancel before side effects — obsolete acquire must not write.
                guard generation == self.applyGeneration else {
                    self.queue.async { completion(.ok) }
                    return
                }
                do {
                    try self.runner.writeSleepDisabled(enabled)
                    self.queue.async {
                        guard generation == self.applyGeneration else {
                            completion(.ok) // obsolete write — discard ack
                            return
                        }
                        self.ledger.acknowledgeWrite(enabled)
                        self.lastChangeAt = Date()
                        let persistOutcome = self.persistAfterMutation()
                        if case .error = persistOutcome, !enabled {
                            // write0 ack + save fail: re-stage recovery intent (W1-8).
                            self.ledger.setByHelper = true
                            self.ledger.pendingRestore = true
                            self.persistRetryNeeded = true
                        }
                        self.rearmIdleAfterStateChange()
                        completion(persistOutcome)
                    }
                } catch {
                    self.queue.async {
                        guard generation == self.applyGeneration else {
                            completion(.ok)
                            return
                        }
                        self.ledger.noteWriteFailure()
                        self.rearmIdleAfterStateChange()
                        completion(.error("pmsetFailed"))
                    }
                }
            }
        case let .externalInterference(shouldRestore):
            lastForcedOffReason = "externalInterference"
            lastChangeAt = Date()
            if shouldRestore {
                applyAction(.write(false), generation: generation, completion: completion)
            } else {
                let outcome = persistAfterMutation()
                rearmIdleAfterStateChange()
                completion(outcome)
            }
        case .recoveryBlocked:
            completion(.error("recoveryBlocked"))
        case .systemValueUnknown:
            completion(.error("systemValueUnknown"))
        }
    }

    /// Persist current ledger; surface failure without swallowing (W1-8).
    private func persistAfterMutation() -> ApplyOutcome {
        do {
            try store.save(ledger)
            persistRetryNeeded = false
            return .ok
        } catch {
            persistRetryNeeded = true
            return .error("storeFailed")
        }
    }

    private func encodeStatus(callerID: UInt64, systemValue: Bool?) -> Data {
        let callerIsHolder = ledger.holders[callerID] != nil
        let callerUID = ledger.holders[callerID]?.uid
        let otherUsers = ledger.holders.values.contains { holder in
            if let callerUID { return holder.uid != callerUID }
            return true
        }
        let status = PowerHelperStatus(
            protocolVersion: PowerHelperConstants.protocolVersion,
            helperBuild: helperBuild,
            sleepDisabled: systemValue,
            setByHelper: ledger.setByHelper,
            priorValueWasDisabled: ledger.priorValueWasDisabled,
            holderCount: ledger.holders.count,
            callerIsHolder: callerIsHolder,
            otherUsersHolding: otherUsers && ledger.holders.count > 0,
            watchdogSeconds: Int(PowerHelperConstants.watchdogTimeout),
            lastForcedOffReason: lastForcedOffReason,
            lastChangeAt: lastChangeAt,
            recoveryBlocked: ledger.recoveryBlocked,
            pendingRestore: ledger.pendingRestore,
            persistRetryNeeded: persistRetryNeeded
        )
        return (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
    }

    // MARK: - Watchdog / safety / idle

    private func installWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.runWatchdogTick()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func runWatchdogTick() {
        guard startupReady, !restorationInProgress else { return }
        let generation = beginApply()
        // Retry failed persistence without renewing idle (W1-8/9).
        if persistRetryNeeded {
            _ = persistAfterMutation()
            rearmIdleAfterStateChange()
        }
        readSystemValue(generation: generation) { [weak self] systemValue in
            guard let self else { return }
            self.queue.async {
                guard generation == self.applyGeneration else { return }
                let (action, expired) = self.ledger.expire(
                    now: self.now(),
                    timeout: PowerHelperConstants.watchdogTimeout,
                    currentSystemValue: systemValue
                )
                if !expired.isEmpty {
                    self.lastForcedOffReason = "watchdog"
                    self.lastChangeAt = Date()
                }
                let protectsRestore: Bool
                if case .write(false) = action {
                    protectsRestore = true
                    self.restorationInProgress = true
                } else {
                    protectsRestore = false
                }
                self.applyAction(action, generation: generation) { _ in
                    if protectsRestore { self.finishRestoration() }
                    self.rearmIdleAfterStateChange()
                }
                // Do NOT touchExternalActivity — watchdog must not reset idle (W1-9).
            }
        }
    }

    private func installSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.runSafetyTick()
        }
        timer.resume()
        safetyTimer = timer
    }

    private func runSafetyTick() {
        guard !ledger.holders.isEmpty else { return }
        guard let refuse = safety.snapshot().refusesAcquire else { return }
        initiateProtectedForceOff(reason: refuse.forcedOffReason) {}
    }

    /// Non-cancellable restoration path for safety / unsafe heartbeat (W1-1 / W1-7).
    private func initiateProtectedForceOff(reason: String, completion: @escaping () -> Void) {
        guard !restorationInProgress else {
            pendingSafetyReason = reason
            completion()
            return
        }
        restorationInProgress = true
        let generation = beginApply()
        // Ownership already decides whether restoration is allowed; no read is needed to
        // clear holders. Cancel queued acquire immediately, then append at most one write0.
        let action = ledger.forceOff(currentSystemValue: nil)
        lastForcedOffReason = reason
        lastChangeAt = Date()
        applyAction(action, generation: generation) { _ in
            self.finishRestoration()
            self.rearmIdleAfterStateChange()
            completion()
        }
    }

    private func finishRestoration() {
        restorationInProgress = false
        if let reason = pendingSafetyReason {
            pendingSafetyReason = nil
            initiateProtectedForceOff(reason: reason) {}
        }
        let disconnected = deferredDisconnects
        deferredDisconnects.removeAll()
        for id in disconnected { handleDisconnect(connectionID: id) }
    }

    private func touchExternalActivityAndRescheduleIdle() {
        lastExternalActivity = Date()
        scheduleIdleTimer(delay: idleExitDelay)
    }

    /// W1-16: re-evaluate idle after blockers clear without resetting external activity.
    private func rearmIdleAfterStateChange() {
        let elapsed = Date().timeIntervalSince(lastExternalActivity)
        let remaining = max(0.05, idleExitDelay - elapsed)
        scheduleIdleTimer(delay: remaining)
    }

    private func scheduleIdleTimer(delay: TimeInterval) {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.evaluateIdleExit()
        }
        timer.resume()
        idleTimer = timer
    }

    private func evaluateIdleExit() {
        guard startupReady, !restorationInProgress else {
            rearmIdleAfterStateChange()
            return
        }
        guard ledger.holders.isEmpty else {
            rearmIdleAfterStateChange()
            return
        }
        // Pending owned restore / persist retry must stay alive (W1-9 / W1-16).
        if ledger.pendingRestore, ledger.setByHelper {
            rearmIdleAfterStateChange()
            return
        }
        if persistRetryNeeded {
            rearmIdleAfterStateChange()
            return
        }
        guard Date().timeIntervalSince(lastExternalActivity) >= idleExitDelay - 0.5 else {
            rearmIdleAfterStateChange()
            return
        }
        onIdleExit()
    }
}

// MARK: - Listener delegate

final class PowerHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: PowerHelperService

    init(service: PowerHelperService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        service.shouldAccept(connection: newConnection)
    }
}
