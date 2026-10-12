import ChorusCore
import Foundation

/// Core helper orchestration: ledger + pmset + safety + watchdog (spec §6.3 / §14.1).
///
/// All ledger mutations run on `queue`. pmset I/O runs off-queue so the watchdog
/// timer is never blocked by a wedged subprocess (V-C05-2).
final class PowerHelperService: NSObject, @unchecked Sendable {
    typealias IdleExitHandler = () -> Void
    typealias NowProvider = () -> Double

    private let queue: DispatchQueue
    private let runner: PMSetRunning
    private let store: LedgerStoring
    private let safety: HelperPowerSafetyChecking
    private let helperBuild: String
    private let isRelease: Bool
    private let now: NowProvider
    private let onIdleExit: IdleExitHandler

    private var ledger = SleepGuardLedger()
    private var lastForcedOffReason: String?
    private var lastChangeAt: Date?
    private var nextConnectionID: UInt64 = 1
    /// connectionID → connection (for invalidation / uid checks).
    private var connections: [UInt64: NSXPCConnection] = [:]
    private var lastActivity = Date()
    private var watchdogTimer: DispatchSourceTimer?
    private var safetyTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    /// Serializes apply(action) so forceOff cannot be overwritten by a queued acquire (§14.1).
    private var applyGeneration: UInt64 = 0

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
        runner: PMSetRunning,
        store: LedgerStoring,
        safety: HelperPowerSafetyChecking,
        helperBuild: String,
        isRelease: Bool = false,
        now: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime },
        onIdleExit: @escaping IdleExitHandler = { exit(0) }
    ) {
        self.queue = queue
        self.runner = runner
        self.store = store
        self.safety = safety
        self.helperBuild = helperBuild
        self.isRelease = isRelease
        self.now = now
        self.onIdleExit = onIdleExit
        super.init()
    }

    var clientRequirementString: String {
        PowerHelperConstants.clientRequirement(forRelease: isRelease)
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.reconcileOnLaunch()
            self?.installWatchdog()
            self?.installSafetyTimer()
            self?.touchActivityAndRescheduleIdle()
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

    /// Test seam: current ledger snapshot.
    func ledgerSnapshotForTesting() -> SleepGuardLedger {
        queue.sync { ledger }
    }

    // MARK: - NSXPCListenerDelegate helpers

    func shouldAccept(connection: NSXPCConnection) -> Bool {
        // Dual verification: listener already has setConnectionCodeSigningRequirement;
        // we still bind a fresh exported object per connection (no shared mutable auth).
        let uid = connection.effectiveUserIdentifier
        let pid = connection.processIdentifier
        let id: UInt64 = queue.sync {
            let assigned = nextConnectionID
            nextConnectionID += 1
            connections[assigned] = connection
            touchActivityAndRescheduleIdle()
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
            self.touchActivityAndRescheduleIdle()
            let generation = self.beginApply()

            if enabled {
                // Hard floor first (every acquire / heartbeat).
                if let refuse = self.safety.snapshot().refusesAcquire {
                    self.lastForcedOffReason = refuse.forcedOffReason
                    reply(nil, refuse.errorCode)
                    return
                }

                // Restore-before-reacquire: finish pending owned restore first (C03 handoff).
                if self.ledger.pendingRestore, self.ledger.setByHelper, self.ledger.holders.isEmpty {
                    let restoreOK = self.applyWrite(false, generation: generation)
                    if !restoreOK {
                        reply(nil, "pmsetFailed")
                        return
                    }
                }

                if self.ledger.recoveryBlocked {
                    reply(nil, "recoveryBlocked")
                    return
                }

                let systemValue = self.safeReadSystemValue()
                let action = self.ledger.acquire(
                    connectionID: connectionID,
                    uid: uid,
                    pid: pid,
                    now: self.now(),
                    currentSystemValue: systemValue
                )
                let outcome = self.applyAction(
                    action,
                    generation: generation,
                    rollbackConnectionID: connectionID
                )
                switch outcome {
                case .ok:
                    self.persistBestEffort()
                    reply(self.encodeStatus(callerID: connectionID), nil)
                case let .error(code):
                    reply(nil, code)
                }
            } else {
                let systemValue = self.safeReadSystemValue()
                let action = self.ledger.release(
                    connectionID: connectionID,
                    currentSystemValue: systemValue
                )
                let outcome = self.applyAction(action, generation: generation)
                switch outcome {
                case .ok:
                    self.persistBestEffort()
                    reply(self.encodeStatus(callerID: connectionID), nil)
                case let .error(code):
                    reply(nil, code)
                }
            }
        }
    }

    private func handleStatus(connectionID: UInt64, reply: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.touchActivityAndRescheduleIdle()
            reply(self.encodeStatus(callerID: connectionID))
        }
    }

    private func handleDisconnect(connectionID: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connections.removeValue(forKey: connectionID)
            let generation = self.beginApply()
            let systemValue = self.safeReadSystemValue()
            let action = self.ledger.dropConnection(connectionID, currentSystemValue: systemValue)
            _ = self.applyAction(action, generation: generation)
            if action != .none {
                self.lastForcedOffReason = "disconnect"
                self.lastChangeAt = Date()
            }
            self.persistBestEffort()
            self.touchActivityAndRescheduleIdle()
        }
    }

    // MARK: - Launch reconcile

    private func reconcileOnLaunch() {
        let generation = beginApply()
        let systemValue = safeReadSystemValue()
        let persisted: SleepGuardLedger?
        do {
            persisted = try store.load()
        } catch {
            // Corrupt / unsupported → treat as missing (Fi A8).
            persisted = nil
            if systemValue != false {
                let (blocked, action) = SleepGuardLedger.reconcileOnLaunch(
                    persisted: nil,
                    currentSystemValue: systemValue
                )
                ledger = blocked
                _ = applyAction(action, generation: generation)
                persistBestEffort()
                return
            }
        }

        let (restored, action) = SleepGuardLedger.reconcileOnLaunch(
            persisted: persisted,
            currentSystemValue: systemValue
        )
        ledger = restored
        if case .write(false) = action {
            lastForcedOffReason = "bootReconcile"
            lastChangeAt = Date()
        }
        _ = applyAction(action, generation: generation)
        persistBestEffort()
    }

    // MARK: - Apply ledger actions

    private enum ApplyOutcome {
        case ok
        case error(String)
    }

    private func beginApply() -> UInt64 {
        applyGeneration += 1
        return applyGeneration
    }

    private func applyAction(
        _ action: SleepGuardLedger.Action,
        generation: UInt64,
        rollbackConnectionID: UInt64? = nil
    ) -> ApplyOutcome {
        guard generation == applyGeneration else { return .ok } // superseded
        switch action {
        case .none:
            return .ok
        case let .write(enabled):
            // Persist recovery intent before writing 1 (§14.1).
            if enabled {
                ledger.setByHelper = true
                ledger.pendingRestore = false
                do {
                    try store.save(ledger)
                } catch {
                    ledger.noteWriteFailure()
                    // Do not write 1 if store failed; roll back the acquire holder.
                    if let rollbackConnectionID {
                        _ = ledger.holders.removeValue(forKey: rollbackConnectionID)
                        if ledger.holders.isEmpty, !ledger.pendingRestore {
                            // Fresh acquire that never reached the system — drop ownership claim.
                            ledger.setByHelper = false
                            ledger.priorValueWasDisabled = nil
                        }
                    }
                    return .error("storeFailed")
                }
            }
            let ok = applyWrite(enabled, generation: generation)
            return ok ? .ok : .error("pmsetFailed")
        case let .externalInterference(shouldRestore):
            lastForcedOffReason = "externalInterference"
            lastChangeAt = Date()
            if shouldRestore {
                let ok = applyWrite(false, generation: generation)
                return ok ? .ok : .error("pmsetFailed")
            }
            return .ok
        case .recoveryBlocked:
            return .error("recoveryBlocked")
        case .systemValueUnknown:
            return .error("systemValueUnknown")
        }
    }

    @discardableResult
    private func applyWrite(_ enabled: Bool, generation: UInt64) -> Bool {
        guard generation == applyGeneration else { return false }
        do {
            try runner.writeSleepDisabled(enabled)
            guard generation == applyGeneration else { return false }
            ledger.acknowledgeWrite(enabled)
            lastChangeAt = Date()
            return true
        } catch {
            ledger.noteWriteFailure()
            // write(false) failure must NOT clear ownership (§14.1 / V-C05-1).
            return false
        }
    }

    private func safeReadSystemValue() -> Bool? {
        do {
            return try runner.readSleepDisabled()
        } catch {
            return nil
        }
    }

    private func persistBestEffort() {
        do {
            try store.save(ledger)
        } catch {
            // Keep in-memory state; next mutation retries. Do not claim restored.
        }
    }

    private func encodeStatus(callerID: UInt64) -> Data {
        let systemValue = safeReadSystemValue()
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
            lastChangeAt: lastChangeAt
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
        let generation = beginApply()
        let systemValue = safeReadSystemValue()
        let (action, expired) = ledger.expire(
            now: now(),
            timeout: PowerHelperConstants.watchdogTimeout,
            currentSystemValue: systemValue
        )
        if !expired.isEmpty {
            lastForcedOffReason = "watchdog"
            lastChangeAt = Date()
        }
        _ = applyAction(action, generation: generation)
        persistBestEffort()
        touchActivityAndRescheduleIdle()
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
        // Only sample hard floor while holders exist (spec §6.3).
        guard !ledger.holders.isEmpty else { return }
        guard let refuse = safety.snapshot().refusesAcquire else { return }
        let generation = beginApply()
        let systemValue = safeReadSystemValue()
        let action = ledger.forceOff(currentSystemValue: systemValue)
        lastForcedOffReason = refuse.forcedOffReason
        lastChangeAt = Date()
        _ = applyAction(action, generation: generation)
        persistBestEffort()
    }

    private func touchActivityAndRescheduleIdle() {
        lastActivity = Date()
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delay = PowerHelperConstants.idleExitDelay
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.ledger.holders.isEmpty else { return }
            guard Date().timeIntervalSince(self.lastActivity) >= delay - 0.5 else {
                self.touchActivityAndRescheduleIdle()
                return
            }
            self.onIdleExit()
        }
        timer.resume()
        idleTimer = timer
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
