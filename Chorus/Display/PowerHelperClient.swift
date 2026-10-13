import ChorusCore
import Darwin
import Foundation
import ServiceManagement

/// Why a service-status refresh was requested (PERF-1).
enum PowerHelperRefreshReason: Sendable, Equatable {
    case launch
    case wake
    case settingsOpened
    case userAction
    case connectionInvalidated
    case retry
}

/// Sendable SMAppService status snapshot for background reads (PERF-1).
enum PowerHelperServiceStatusValue: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }
}

/// Worker-safe SM status reader. Never capture MainActor SMAppService in a detached task.
protocol PowerHelperServiceStatusReading: Sendable {
    func readStatus() -> PowerHelperServiceStatusValue
}

/// Production reader: creates/uses daemon on a dedicated serial queue.
final class SMAppServiceStatusReader: PowerHelperServiceStatusReading, @unchecked Sendable {
    private let queue: DispatchQueue
    private let plistName: String
    private var daemon: SMAppService?

    init(plistName: String, queue: DispatchQueue? = nil) {
        self.plistName = plistName
        self.queue = queue ?? DispatchQueue(label: "com.hermes.Chorus.PowerHelper.smStatus")
    }

    func readStatus() -> PowerHelperServiceStatusValue {
        queue.sync {
            if daemon == nil {
                daemon = SMAppService.daemon(plistName: plistName)
            }
            return PowerHelperServiceStatusValue(daemon!.status)
        }
    }
}

/// Test reader with lock-protected call count (PERF-1).
final class LockCountedStatusReader: PowerHelperServiceStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private let read: () -> PowerHelperServiceStatusValue
    private(set) var count = 0
    /// Optional artificial delay inside `readStatus` (simulates wedged SM getter).
    var delay: TimeInterval = 0
    private let delayImpl: (TimeInterval) -> Void

    init(
        delayImpl: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        read: @escaping () -> PowerHelperServiceStatusValue
    ) {
        self.delayImpl = delayImpl
        self.read = read
    }

    func readStatus() -> PowerHelperServiceStatusValue {
        lock.lock()
        count += 1
        let delay = self.delay
        lock.unlock()
        if delay > 0 { delayImpl(delay) }
        return read()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// App ↔ ChorusPowerHelper XPC client (spec §6.4 / §6.5 / §14.2 / W1-4..6 / W1-13..14).
@MainActor
protocol PowerHelperClienting: AnyObject {
    var availability: LidHelperAvailability { get }
    var onAvailabilityChange: (() -> Void)? { get set }
    func refreshAvailability(reason: PowerHelperRefreshReason) async
    func register() async throws
    func unregister() async throws
    func openApprovalSettings()
    func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus
    func status() async throws -> PowerHelperStatus
    func setSleepDisabledSynchronously(_ on: Bool, timeout: TimeInterval) -> Bool
}

/// Maps service status → `LidHelperAvailability` (pure; V-C06-1 / PERF-1).
enum PowerHelperAvailabilityMapping {
    static func availability(
        from status: SMAppService.Status,
        handshake: PowerHelperHandshakeResult? = nil
    ) -> LidHelperAvailability {
        availability(from: PowerHelperServiceStatusValue(status), handshake: handshake)
    }

    static func availability(
        from status: PowerHelperServiceStatusValue,
        handshake: PowerHelperHandshakeResult? = nil
    ) -> LidHelperAvailability {
        switch status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            // W1-4: enabled alone is never `.ready` without a fresh handshake.
            if let handshake {
                return handshake.availability
            }
            return .connecting
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .unknown:
            return .error("unknown SMAppService.Status")
        }
    }
}

enum PowerHelperHandshakeResult: Equatable, Sendable {
    case ready
    case versionMismatch(helper: String, app: String)
    case error(String)

    var availability: LidHelperAvailability {
        switch self {
        case .ready: return .ready
        case let .versionMismatch(helper, app): return .versionMismatch(helper: helper, app: app)
        case let .error(message): return .error(message)
        }
    }

    /// Protocol match → ready even when build differs; protocol differ → mismatch (V-C06-2).
    static func evaluate(
        status: PowerHelperStatus,
        appBuild: String,
        expectedProtocol: Int = PowerHelperConstants.protocolVersion
    ) -> PowerHelperHandshakeResult {
        if status.protocolVersion != expectedProtocol {
            return .versionMismatch(helper: status.helperBuild, app: appBuild)
        }
        return .ready
    }
}

enum PowerHelperClientError: Error, Equatable {
    case unavailable
    case timedOut
    case remote(String)
    case decodingFailed
    case notConnected
    case unregisterBlocked(String)
    case versionMismatch
    case acquireRequiresHandshake
}

/// Injectable XPC proxy for tests (V-C06-3 / V-C06-4).
@MainActor
protocol PowerHelperXPCProxying: AnyObject {
    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Data?, String?) -> Void)
    func status(reply: @escaping (Data) -> Void)
    /// Optional: real connections notify interruption/invalidation (W1-4).
    var onConnectionEvent: ((PowerHelperConnectionEvent) -> Void)? { get set }
    func invalidate()
}

enum PowerHelperConnectionEvent: Sendable {
    case interrupted
    case invalidated
}

/// Injectable SMAppService repair operations (W1-14 / A1). Never call real install in verifier tests.
@MainActor
protocol PowerHelperRepairing: AnyObject {
    func unregisterDaemon() throws
    func registerDaemon() throws
}

enum PowerHelperRepairOutcome: Equatable, Sendable {
    case notNeeded
    case repaired
    case blocked(String)
    case skippedUnsafe
}

/// Automatic protocol-mismatch repair gated on holders / recovery safety (A1 §D / W1-14).
@MainActor
final class PowerHelperRepairStateMachine {
    private let repairing: PowerHelperRepairing
    private let authorizeRepair: () -> Bool
    private(set) var unregisterCalls = 0
    private(set) var registerCalls = 0

    init(repairing: PowerHelperRepairing, authorizeRepair: @escaping () -> Bool = { false }) {
        self.repairing = repairing
        self.authorizeRepair = authorizeRepair
    }

    /// Returns whether service ops were invoked. Unsafe evidence never calls unregister/register.
    func repairIfNeeded(status: PowerHelperStatus, handshake: PowerHelperHandshakeResult) -> PowerHelperRepairOutcome {
        guard case .versionMismatch = handshake else { return .notNeeded }
        if status.holderCount > 0 {
            return .skippedUnsafe
        }
        if status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded {
            return .skippedUnsafe
        }
        if status.sleepDisabled != false {
            // Unknown or still disabled — not safe to unregister (may drop restore path).
            return .skippedUnsafe
        }
        if status.setByHelper {
            return .skippedUnsafe
        }
        guard authorizeRepair() else { return .blocked("authorizationRequired") }
        do {
            unregisterCalls += 1
            try repairing.unregisterDaemon()
            registerCalls += 1
            try repairing.registerDaemon()
            return .repaired
        } catch {
            return .blocked(error.localizedDescription)
        }
    }
}

@MainActor
final class PowerHelperClient: PowerHelperClienting {
    private(set) var availability: LidHelperAvailability = .notRegistered
    var onAvailabilityChange: (() -> Void)?

    private let plistName: String
    private let appBuild: String
    private let isRelease: Bool
    private let callTimeout: TimeInterval
    private let makeProxy: () -> PowerHelperXPCProxying?
    private let statusReader: any PowerHelperServiceStatusReading
    private let statusQueue: DispatchQueue
    private let registerService: () throws -> Void
    private let unregisterService: () throws -> Void
    private let openSettings: () -> Void
    private let repairMachine: PowerHelperRepairStateMachine?
    private let now: () -> TimeInterval
    private let refreshTimeout: TimeInterval
    private let minimumPhysicalInterval: TimeInterval

    private var proxy: PowerHelperXPCProxying?
    /// Identity of the current proxy — connection events must match (W1-4).
    private var connectionToken: UInt64 = 0
    private var nextConnectionToken: UInt64 = 1
    private var generation: UInt64 = 0
    /// True only after a successful status() handshake on the current connection (W1-5).
    private var handshakeComplete = false
    private var recoveryEvidenceComplete = false
    /// At most one automatic repair attempt per client instance (W1-14).
    private var didAttemptProtocolRepair = false
    /// PERF1-R1: bumps when SM evidence revokes readiness so a late XPC status()
    /// cannot republish `.ready`. Safe release ignores this epoch.
    private var readinessEpoch: UInt64 = 0

    // MARK: PERF-1 service-status cache / single-flight
    private var cachedServiceStatus: PowerHelperServiceStatusValue?
    private var lastSuccessfulSampleAt: TimeInterval?
    private var lastPhysicalStartAt: TimeInterval?
    private var cacheEpoch: UInt64 = 0
    private var physicalInFlightToken: UInt64?
    private var nextPhysicalToken: UInt64 = 1
    private var timedOutPhysicalTokens: Set<UInt64> = []
    /// Waiters keyed so cancellation can remove a single continuation (PERF1-R2).
    private var refreshWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextRefreshWaiterID: UInt64 = 1
    private var refreshTimeoutTask: Task<Void, Never>?
    private var pendingPhysicalIntent = false
    /// When true, the next physical start may bypass the 5s floor (post register/unregister).
    private var bypassFloorOnce = false
    private var intentionalTeardown = false

    /// Exposed for PERF-1 tests.
    var cachedServiceStatusForTesting: PowerHelperServiceStatusValue? { cachedServiceStatus }
    var physicalInFlightForTesting: Bool { physicalInFlightToken != nil }
    var readinessEpochForTesting: UInt64 { readinessEpoch }
    var handshakeCompleteForTesting: Bool { handshakeComplete }

    init(
        plistName: String = PowerHelperConstants.daemonPlistName,
        appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
        isRelease: Bool = {
            #if DEBUG
            false
            #else
            true
            #endif
        }(),
        callTimeout: TimeInterval = 3,
        refreshTimeout: TimeInterval = 3,
        minimumPhysicalInterval: TimeInterval = 5,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        makeProxy: (() -> PowerHelperXPCProxying?)? = nil,
        statusReader: (any PowerHelperServiceStatusReading)? = nil,
        /// Legacy test seam — wrapped into a lock-counted reader.
        serviceStatus: (() -> SMAppService.Status)? = nil,
        registerService: (() throws -> Void)? = nil,
        unregisterService: (() throws -> Void)? = nil,
        openSettings: (() -> Void)? = nil,
        repairMachine: PowerHelperRepairStateMachine? = nil,
        authorizeProtocolRepair: @escaping () -> Bool = { false }
    ) {
        self.plistName = plistName
        self.appBuild = appBuild
        self.isRelease = isRelease
        self.callTimeout = callTimeout
        self.refreshTimeout = refreshTimeout
        self.minimumPhysicalInterval = minimumPhysicalInterval
        self.now = now
        self.statusQueue = DispatchQueue(label: "com.hermes.Chorus.PowerHelper.smStatus.\(plistName)")
        self.makeProxy = makeProxy ?? {
            RealPowerHelperXPCProxy(
                machServiceName: PowerHelperConstants.machServiceName,
                requirement: PowerHelperConstants.helperRequirement(forRelease: isRelease)
            )
        }
        // PERF1-R6: no runtime XCTest switches in Release — inject deps in tests;
        // Debug test-host stubs at most.
        #if DEBUG
        let underTestHost =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        #else
        let underTestHost = false
        #endif
        if let statusReader {
            self.statusReader = statusReader
        } else if let serviceStatus {
            self.statusReader = LockCountedStatusReader {
                PowerHelperServiceStatusValue(serviceStatus())
            }
        } else if underTestHost {
            // Test host must never call real SMAppService.status (wedges the runner).
            self.statusReader = LockCountedStatusReader { .notRegistered }
        } else {
            // Own serial queue inside the reader — never share with the client's dispatch wrapper.
            self.statusReader = SMAppServiceStatusReader(plistName: plistName)
        }

        let resolvedRegister: () throws -> Void
        let resolvedUnregister: () throws -> Void
        if let registerService {
            resolvedRegister = registerService
        } else if underTestHost {
            resolvedRegister = {}
        } else {
            let daemon = SMAppService.daemon(plistName: plistName)
            resolvedRegister = { try daemon.register() }
        }
        if let unregisterService {
            resolvedUnregister = unregisterService
        } else if underTestHost {
            resolvedUnregister = {}
        } else {
            let daemon = SMAppService.daemon(plistName: plistName)
            resolvedUnregister = { try daemon.unregister() }
        }
        self.registerService = resolvedRegister
        self.unregisterService = resolvedUnregister
        self.openSettings = openSettings ?? {
            if underTestHost { return }
            SMAppService.openSystemSettingsLoginItems()
        }
        if let repairMachine {
            self.repairMachine = repairMachine
        } else if registerService != nil || unregisterService != nil || underTestHost {
            // Injected / test-host seams — wrap them so repair never touches real SMAppService.
            self.repairMachine = PowerHelperRepairStateMachine(
                repairing: InjectedRepairing(register: resolvedRegister, unregister: resolvedUnregister),
                authorizeRepair: authorizeProtocolRepair
            )
        } else {
            // Production: repair uses the same daemon APIs (Fi A1; not exercised in verifier).
            let daemon = SMAppService.daemon(plistName: plistName)
            self.repairMachine = PowerHelperRepairStateMachine(
                repairing: InjectedRepairing(
                    register: { try daemon.register() },
                    unregister: { try daemon.unregister() }
                ),
                authorizeRepair: authorizeProtocolRepair
            )
        }
    }

    func refreshAvailability(reason: PowerHelperRefreshReason) async {
        let wantsBypass = bypassFloorOnce && reason == .userAction

        // PERF1-R2: if the physical slot is held after timeout, do not wait forever —
        // return the timeout state immediately (unless a post-op pending refresh is owed).
        if let inFlight = physicalInFlightToken, timedOutPhysicalTokens.contains(inFlight) {
            if wantsBypass || pendingPhysicalIntent {
                pendingPhysicalIntent = true
                // Bounded wait for stuck getter → replacement; never hang settings/register.
                await joinPhysicalRefresh(cancellationAware: true, bound: refreshTimeout)
            }
            return
        }

        if physicalInFlightToken != nil {
            // Join in-flight; post-op bypass schedules one replacement for the new epoch (R4).
            if wantsBypass {
                pendingPhysicalIntent = true
            }
            await joinPhysicalRefresh(cancellationAware: true, bound: refreshTimeout)
            return
        }

        let t = now()
        let withinFloor: Bool = {
            guard !wantsBypass, let last = lastPhysicalStartAt else { return false }
            return t - last < minimumPhysicalInterval
        }()

        if withinFloor {
            if let cached = cachedServiceStatus {
                applyCachedServiceStatus(cached)
                return
            }
            // PERF1-R1: cache cleared (e.g. invalidate) with no sample — do not
            // return early on the floor; require a fresh physical read.
        }

        // Register waiter BEFORE kicking the worker so a fast result cannot resume an empty list.
        let id = nextRefreshWaiterID
        nextRefreshWaiterID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                refreshWaiters[id] = cont
                if physicalInFlightToken == nil {
                    beginPhysicalRefreshLocked(consumeFloorBypass: wantsBypass)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRefreshWaiter(id)
            }
        }
    }

    /// PERF1-R2: join current/pending physical refresh with cancellation removing the waiter.
    /// Bounded completion after timeout so settings/wake/user ops never hang on a stuck getter.
    /// Optional `bound` resumes the waiter even if the uncancellable getter never finishes.
    private func joinPhysicalRefresh(cancellationAware: Bool, bound: TimeInterval? = nil) async {
        let id = nextRefreshWaiterID
        nextRefreshWaiterID &+= 1
        let timeoutTask: Task<Void, Never>? = {
            guard let bound else { return nil }
            return Task { @MainActor [weak self] in
                let ns = UInt64(max(bound, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                self?.cancelRefreshWaiter(id)
            }
        }()
        defer { timeoutTask?.cancel() }

        if cancellationAware {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    refreshWaiters[id] = cont
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelRefreshWaiter(id)
                }
            }
        } else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                refreshWaiters[id] = cont
            }
        }
    }

    private func cancelRefreshWaiter(_ id: UInt64) {
        if let cont = refreshWaiters.removeValue(forKey: id) {
            cont.resume()
        }
    }

    private func beginPhysicalRefreshLocked(consumeFloorBypass: Bool = false) {
        if consumeFloorBypass {
            bypassFloorOnce = false
        } else if bypassFloorOnce, pendingPhysicalIntent {
            // Post-operation replacement read for the new epoch keeps its floor bypass (R4).
            bypassFloorOnce = false
        }
        let token = nextPhysicalToken
        nextPhysicalToken &+= 1
        physicalInFlightToken = token
        lastPhysicalStartAt = now()
        let epochAtStart = cacheEpoch
        let reader = statusReader
        let queue = statusQueue

        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = Task { @MainActor [weak self] in
            let ns = UInt64(max(self?.refreshTimeout ?? 3, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            self.handlePhysicalTimeout(token: token, epochAtStart: epochAtStart)
        }

        queue.async {
            let value = reader.readStatus()
            Task { @MainActor [weak self] in
                self?.handlePhysicalResult(token: token, epochAtStart: epochAtStart, value: value)
            }
        }
    }

    private func handlePhysicalTimeout(token: UInt64, epochAtStart: UInt64) {
        guard physicalInFlightToken == token else { return }
        timedOutPhysicalTokens.insert(token)
        // Complete waiters without waiting for the uncancellable getter.
        if cacheEpoch == epochAtStart {
            revokeReadinessEvidence(reason: .serviceTimeout)
            cachedServiceStatus = .unknown
            applyAvailability(.error("serviceStatusTimeout"))
        }
        resumeRefreshWaiters()
        // Keep physicalInFlightToken until the worker finishes.
    }

    private func handlePhysicalResult(
        token: UInt64,
        epochAtStart: UInt64,
        value: PowerHelperServiceStatusValue
    ) {
        let wasTimedOut = timedOutPhysicalTokens.remove(token) != nil
        if physicalInFlightToken == token {
            physicalInFlightToken = nil
        }
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil

        let epochMismatch = cacheEpoch != epochAtStart
        // PERF1-R4: discarded epoch result must not complete post-op waiters before
        // the replacement physical read for the new epoch finishes.
        let startPendingReplacement = pendingPhysicalIntent && physicalInFlightToken == nil
            && (epochMismatch || wasTimedOut || !refreshWaiters.isEmpty)

        if startPendingReplacement {
            pendingPhysicalIntent = false
            // Stale / timed-out / superseded results never recreate ready evidence.
            if !wasTimedOut && !epochMismatch {
                lastSuccessfulSampleAt = now()
                applyCachedServiceStatus(value)
            }
            beginPhysicalRefreshLocked(consumeFloorBypass: true)
            return
        }

        pendingPhysicalIntent = false

        // Stale / timed-out / superseded results never recreate ready evidence.
        if wasTimedOut || epochMismatch {
            resumeRefreshWaiters()
            return
        }

        lastSuccessfulSampleAt = now()
        applyCachedServiceStatus(value)
        resumeRefreshWaiters()
    }

    private func resumeRefreshWaiters() {
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume() }
    }

    private enum ReadinessRevokeReason {
        case serviceTimeout
        case serviceNotEnabled
        case connectionEvent
        case intentionalInvalidate
    }

    /// PERF1-R1: bump readiness epoch and clear handshake so late XPC cannot republish ready.
    private func revokeReadinessEvidence(reason: ReadinessRevokeReason) {
        readinessEpoch &+= 1
        handshakeComplete = false
        _ = reason
    }

    private func applyCachedServiceStatus(_ status: PowerHelperServiceStatusValue) {
        cachedServiceStatus = status
        switch status {
        case .requiresApproval, .notRegistered, .notFound, .unknown:
            revokeReadinessEvidence(reason: .serviceNotEnabled)
            let mapped = PowerHelperAvailabilityMapping.availability(
                from: status,
                handshake: nil
            )
            applyAvailability(mapped)
        case .enabled:
            // Enabled cache alone never means ready — derive from current handshake evidence.
            let mapped = PowerHelperAvailabilityMapping.availability(
                from: status,
                handshake: handshakeComplete ? .ready : nil
            )
            applyAvailability(mapped)
        }
    }

    private func invalidateServiceCache(allowFloorBypass: Bool) {
        cacheEpoch &+= 1
        cachedServiceStatus = nil
        lastSuccessfulSampleAt = nil
        // Drop ready until the new epoch's SM evidence is applied (PERF1-R1/R4).
        revokeReadinessEvidence(reason: .serviceNotEnabled)
        // PERF1-R1 round3: publish revocation immediately — do not leave .ready visible.
        if case .ready = availability {
            applyAvailability(.connecting)
        }
        if allowFloorBypass {
            bypassFloorOnce = true
        }
        // PERF1-R4: preserve one pending refresh for the new epoch when a getter is in flight.
        // Post-operation floor bypass is consumed when that replacement physical read starts.
        if physicalInFlightToken != nil {
            pendingPhysicalIntent = true
        }
    }

    func register() async throws {
        try registerService()
        invalidateServiceCache(allowFloorBypass: true)
        await refreshAvailability(reason: .userAction)
        if case .requiresApproval = availability { return }
        // PERF1-R4 round3: handshake only after a successful current-epoch enabled sample.
        // Bounded waiter completion (timeout/cancel) must not open a ready handshake.
        guard cachedServiceStatus == .enabled else {
            throw PowerHelperClientError.timedOut
        }
        _ = try await status()
    }

    /// Verified removal (W1-6 / §14.1 / Fi A1): confirm own release, verified false readback,
    /// cleared recovery health — gather evidence before invalidating / unregistering.
    func unregister() async throws {
        // Evidence first — do not invalidate yet.
        let snap: PowerHelperStatus
        do {
            snap = try await status()
        } catch {
            throw PowerHelperClientError.unregisterBlocked("statusUnavailable")
        }

        try requireRecoveryEvidence()

        // Unknown / hard recovery block: do not unregister (preserve connection).
        if snap.recoveryBlocked {
            throw PowerHelperClientError.unregisterBlocked("recoveryBlocked")
        }
        if snap.sleepDisabled == nil {
            throw PowerHelperClientError.unregisterBlocked("systemValueUnknown")
        }

        if snap.holderCount > 0 {
            if snap.callerIsHolder {
                _ = try await setSleepDisabled(false)
            }
            let after = try await status()
            try requireRecoveryEvidence()
            try Self.verifyUnregisterEvidence(after, phase: .afterRelease)
        } else if snap.sleepDisabled == true, snap.setByHelper || snap.pendingRestore {
            // Own residual / pending restore without live holders — attempt release (W1-6).
            _ = try await setSleepDisabled(false)
            let after = try await status()
            try requireRecoveryEvidence()
            try Self.verifyUnregisterEvidence(after, phase: .afterRelease)
        } else if snap.sleepDisabled == true {
            throw PowerHelperClientError.unregisterBlocked("foreignSleepDisabled")
        } else if snap.pendingRestore || snap.persistRetryNeeded {
            // Safe false readback but recovery intent still set — not removal-safe.
            throw PowerHelperClientError.unregisterBlocked(
                snap.pendingRestore ? "pendingRestore" : "persistRetryNeeded"
            )
        }

        let finalStatus = try await status()
        try requireRecoveryEvidence()
        try Self.verifyUnregisterEvidence(finalStatus, phase: .final)

        invalidateConnection(intentional: true)
        try unregisterService()
        invalidateServiceCache(allowFloorBypass: true)
        await refreshAvailability(reason: .userAction)
    }

    private func requireRecoveryEvidence() throws {
        guard recoveryEvidenceComplete else {
            throw PowerHelperClientError.unregisterBlocked("recoveryEvidenceUnavailable")
        }
    }

    private enum UnregisterPhase {
        case initial
        case afterRelease
        case final
    }

    /// Shared evidence gates after release / final check (W1-6).
    private static func verifyUnregisterEvidence(
        _ status: PowerHelperStatus,
        phase: UnregisterPhase
    ) throws {
        if status.recoveryBlocked {
            throw PowerHelperClientError.unregisterBlocked("recoveryBlocked")
        }
        if status.pendingRestore {
            throw PowerHelperClientError.unregisterBlocked("pendingRestore")
        }
        if status.persistRetryNeeded {
            throw PowerHelperClientError.unregisterBlocked("persistRetryNeeded")
        }
        if status.sleepDisabled == nil {
            throw PowerHelperClientError.unregisterBlocked("systemValueUnknown")
        }
        switch phase {
        case .initial:
            return
        case .afterRelease, .final:
            if status.holderCount > 0 {
                throw PowerHelperClientError.unregisterBlocked("otherHolders")
            }
            // Require verified false readback — nil/true never passes.
            guard status.sleepDisabled == false else {
                if status.sleepDisabled == true, status.setByHelper {
                    throw PowerHelperClientError.unregisterBlocked("restoreFailed")
                }
                if status.sleepDisabled == true {
                    throw PowerHelperClientError.unregisterBlocked("foreignSleepDisabled")
                }
                throw PowerHelperClientError.unregisterBlocked("systemValueUnknown")
            }
            if status.setByHelper {
                throw PowerHelperClientError.unregisterBlocked("ownedIntentRetained")
            }
        }
    }

    func openApprovalSettings() {
        openSettings()
    }

    func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus {
        if on {
            // W1-5: handshake each connection before acquire.
            try await ensureHandshake()
            if case .versionMismatch = availability {
                throw PowerHelperClientError.versionMismatch
            }
            guard case .ready = availability else {
                throw PowerHelperClientError.unavailable
            }
        }
        let gen = beginGeneration()
        let proxy = try ensureProxy()
        // C8-1: XPC replies arrive off MainActor; withTimeout hops before resume.
        let data: Data = try await withTimeout(callTimeout) { continuation in
            proxy.setSleepDisabled(on) { statusJSON, errorCode in
                if let errorCode {
                    continuation(.failure(PowerHelperClientError.remote(errorCode)))
                } else if let statusJSON {
                    continuation(.success(statusJSON))
                } else {
                    continuation(.failure(PowerHelperClientError.remote("emptyReply")))
                }
            }
        }
        guard gen == generation else { throw PowerHelperClientError.timedOut }
        return try decodeStatus(data)
    }

    func status() async throws -> PowerHelperStatus {
        let gen = beginGeneration()
        let proxy = try ensureProxy()
        // Capture after ensureProxy — a fresh connection must be able to publish ready (PERF1-R1).
        let connectionAtStart = connectionToken
        let readinessAtStart = readinessEpoch
        // C8-1: XPC replies arrive off MainActor; withTimeout hops before resume.
        let data: Data = try await withTimeout(callTimeout) { continuation in
            proxy.status { statusJSON in
                continuation(.success(statusJSON))
            }
        }
        guard gen == generation else { throw PowerHelperClientError.timedOut }
        let status = try decodeStatus(data)
        let handshake = PowerHelperHandshakeResult.evaluate(status: status, appBuild: appBuild)
        if case .versionMismatch = handshake, recoveryEvidenceComplete, !didAttemptProtocolRepair {
            // W1-14 / A1: automatic repair only when safe; never during unsafe evidence.
            if let repairMachine {
                didAttemptProtocolRepair = true
                let outcome = repairMachine.repairIfNeeded(status: status, handshake: handshake)
                switch outcome {
                case .repaired:
                    invalidateConnection()
                    // Re-handshake on a fresh connection after repair.
                    return try await self.status()
                case .skippedUnsafe, .blocked, .notNeeded:
                    break
                }
            }
        }
        // PERF1-R1: publish ready only when connection identity + readiness epoch still
        // match and current-epoch SM evidence is enabled. Nil/unknown SM never means ready.
        // Non-ready handshake outcomes (versionMismatch) still publish without enabled SM.
        // Safe release ignores readinessEpoch.
        let connectionStillCurrent = connectionToken == connectionAtStart && connectionToken != 0
        let readinessStillCurrent = readinessEpoch == readinessAtStart
        let smAllowsReady = cachedServiceStatus == PowerHelperServiceStatusValue.enabled
        guard connectionStillCurrent, readinessStillCurrent else {
            // SM/connection revoked readiness while status was in flight — discard publish.
            return status
        }
        switch handshake {
        case .ready:
            if smAllowsReady {
                handshakeComplete = true
                applyAvailability(
                    PowerHelperAvailabilityMapping.availability(
                        from: PowerHelperServiceStatusValue.enabled,
                        handshake: .ready
                    )
                )
            } else {
                handshakeComplete = false
                if let sm = cachedServiceStatus {
                    applyCachedServiceStatus(sm)
                } else {
                    applyAvailability(.connecting)
                }
            }
        case .versionMismatch, .error:
            handshakeComplete = false
            applyAvailability(handshake.availability)
        }
        return status
    }

    /// Bounded wait for shutdown (§14.2). Acquire (`true`) requires verified ready handshake (W1-13).
    func setSleepDisabledSynchronously(_ on: Bool, timeout: TimeInterval) -> Bool {
        if on {
            guard handshakeComplete, case .ready = availability else {
                return false
            }
        }
        let gen = beginGeneration()
        guard let proxy = try? ensureProxy() else { return false }
        let token = connectionToken
        let box = ReplyBox()
        let sem = DispatchSemaphore(value: 0)
        // C8-1: sync shutdown must not hop to MainActor (would deadlock on wait).
        // ReplyBox is lock-protected for off-actor XPC queues.
        proxy.setSleepDisabled(on) { _, error in
            box.setOK(error == nil)
            sem.signal()
        }
        let result = sem.wait(timeout: .now() + timeout)
        guard gen == generation, token == connectionToken else { return false }
        return result == .success && box.ok
    }

    private func ensureHandshake() async throws {
        if handshakeComplete, case .ready = availability { return }
        _ = try await status()
    }

    private func ensureProxy() throws -> PowerHelperXPCProxying {
        if let proxy { return proxy }
        guard let created = makeProxy() else { throw PowerHelperClientError.notConnected }
        let token = nextConnectionToken
        nextConnectionToken += 1
        connectionToken = token
        created.onConnectionEvent = { [weak self] event in
            // Capture token + proxy identity; discard stale events from replaced connections (W1-4).
            Task { @MainActor in
                self?.handleConnectionEvent(event, token: token, proxy: created)
            }
        }
        proxy = created
        handshakeComplete = false
        applyAvailability(.connecting)
        return created
    }

    private func handleConnectionEvent(
        _ event: PowerHelperConnectionEvent,
        token: UInt64,
        proxy eventProxy: PowerHelperXPCProxying
    ) {
        // W1-4: ignore events from a connection that is no longer current.
        guard token == connectionToken, proxy === eventProxy else { return }
        generation += 1
        revokeReadinessEvidence(reason: .connectionEvent)
        proxy?.onConnectionEvent = nil
        proxy?.invalidate()
        proxy = nil
        connectionToken = 0
        // Revoke ready/hold display synchronously.
        applyAvailability(.connecting)
        cacheEpoch &+= 1
        cachedServiceStatus = nil
        lastSuccessfulSampleAt = nil
        lastPhysicalStartAt = nil
        // Unexpected invalidation schedules one refresh; intentional teardown must not reconnect.
        if !intentionalTeardown {
            Task { await self.refreshAvailability(reason: .connectionInvalidated) }
        }
        _ = event
    }

    func invalidateConnection(intentional: Bool = false) {
        intentionalTeardown = intentional
        generation += 1
        revokeReadinessEvidence(reason: .intentionalInvalidate)
        // PERF1-R1 round3: drop SM sample with the connection so late XPC cannot
        // recombine with a stale enabled cache into ready. Clear the physical-floor
        // clock so the next refresh must sample a new epoch before ready.
        cacheEpoch &+= 1
        cachedServiceStatus = nil
        lastSuccessfulSampleAt = nil
        lastPhysicalStartAt = nil
        connectionToken = 0
        proxy?.onConnectionEvent = nil
        proxy?.invalidate()
        proxy = nil
        applyAvailability(.connecting)
        if intentional {
            // Reset after teardown so a later unexpected event can still refresh.
            intentionalTeardown = false
        }
    }

    private func beginGeneration() -> UInt64 {
        generation += 1
        return generation
    }

    private func applyAvailability(_ next: LidHelperAvailability) {
        guard availability != next else { return }
        availability = next
        onAvailabilityChange?()
    }

    private func decodeStatus(_ data: Data) throws -> PowerHelperStatus {
        do {
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            recoveryEvidenceComplete = ["recoveryBlocked", "pendingRestore", "persistRetryNeeded"].allSatisfy {
                guard let value = fields?[$0] as? NSNumber else { return false }
                return CFGetTypeID(value) == CFBooleanGetTypeID()
            }
            return try JSONDecoder().decode(PowerHelperStatus.self, from: data)
        } catch {
            throw PowerHelperClientError.decodingFailed
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        _ body: (@escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate()
            body { result in
                // C8-1: real XPC reply queues are off-actor; hop before resume.
                Task { @MainActor in
                    guard gate.claim() else { return }
                    continuation.resume(with: result)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard gate.claim() else { return }
                continuation.resume(throwing: PowerHelperClientError.timedOut)
            }
        }
    }
}

/// Test/production seam for repair without embedding SMAppService calls in the state machine body.
@MainActor
private final class InjectedRepairing: PowerHelperRepairing {
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(register: @escaping () throws -> Void, unregister: @escaping () throws -> Void) {
        self.register = register
        self.unregister = unregister
    }

    func unregisterDaemon() throws { try unregister() }
    func registerDaemon() throws { try register() }
}

/// User-level `pmset -g` probe for leftover detection (§6.6). Never requires root.
enum SleepDisabledProbe {
    static let timeout: TimeInterval = 3
    private static let termGraceSeconds: TimeInterval = 0.5
    private static let drainGraceSeconds: TimeInterval = 0.5
    private static let maxStdoutBytes = 256 * 1024

    static func readSleepDisabled(
        run: (URL, [String], TimeInterval) throws -> (exit: Int32, stdout: Data, truncated: Bool)
            = SleepDisabledProbe.runSubprocess
    ) -> Bool? {
        do {
            let result = try run(
                URL(fileURLWithPath: "/usr/bin/pmset"),
                ["-g"],
                timeout
            )
            guard result.exit == 0, !result.truncated,
                  let text = String(data: result.stdout, encoding: .utf8)
            else { return nil }
            return PMSetOutputParser.sleepDisabled(fromPMSetG: text)
        } catch {
            return nil
        }
    }

    /// V1-3: never block MainActor — leftover probe runs off-actor.
    static func readSleepDisabledOffMainActor() async -> Bool? {
        await Task.detached(priority: .userInitiated) {
            readSleepDisabled()
        }.value
    }

    /// Continuous-clock drain + TERM/KILL + bounded reap/EOF (V1-3).
    /// Wall-clock changes cannot extend any advertised bound.
    static func runSubprocess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> (exit: Int32, stdout: Data, truncated: Bool) {
        // Establish the group at spawn time. setpgid after Process.launch races exec
        // and can fail with EACCES, leaving inherited pipe writers alive.
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let outFD = pipe.fileHandleForReading.fileDescriptor
        let writerFD = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(outFD, F_GETFL)
        guard flags >= 0, fcntl(outFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(.EIO)
        }
        let nullFD = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0 else { throw POSIXError(.EIO) }
        defer { close(nullFD) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ code: Int32) throws {
            guard code == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, writerFD, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO))
        try checked(posix_spawn_file_actions_addclose(&actions, outFD))
        try checked(posix_spawn_file_actions_addclose(&actions, writerFD))
        try checked(posix_spawn_file_actions_addclose(&actions, nullFD))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawnattr_setflags(&attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))

        let strings = ([executableURL.path] + arguments).map { strdup($0) }
        defer { for string in strings { free(string) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var argv = strings + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeMutableBufferPointer { argumentsBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(&pid, executableURL.path, &actions, &attributes,
                    argumentsBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
        try checked(spawnError)
        try? pipe.fileHandleForWriting.close()

        let box = ProbeOutputBox(limit: maxStdoutBytes)
        var waitStatus: Int32 = 0
        var reaped = false
        var waitFailed = false
        func pollChild() -> Bool {
            if reaped || waitFailed { return true }
            let result = waitpid(pid, &waitStatus, WNOHANG)
            if result == pid { reaped = true }
            else if result < 0, errno != EINTR { waitFailed = true; box.markTruncated() }
            return reaped || waitFailed
        }
        // The spawn attributes guarantee an isolated group. Always clean that group,
        // even when the direct child exits normally or closes stdout before descendants.
        defer { kill(-pid, SIGKILL) }
        let runDeadline = ContinuousClock.now + .seconds(timeout)
        while !pollChild(), ContinuousClock.now < runDeadline {
            _ = drainAvailable(fd: outFD, box: box)
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = !pollChild()
        if timedOut {
            kill(-pid, SIGTERM)
            let termDeadline = ContinuousClock.now + .seconds(termGraceSeconds)
            while !pollChild(), ContinuousClock.now < termDeadline {
                _ = drainAvailable(fd: outFD, box: box)
                Thread.sleep(forTimeInterval: 0.01)
            }
            // A reaped parent does not prove its descendants respected TERM.
            kill(-pid, SIGKILL)
            let reapDeadline = ContinuousClock.now + .seconds(drainGraceSeconds)
            while !pollChild(), ContinuousClock.now < reapDeadline {
                _ = drainAvailable(fd: outFD, box: box)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        var sawEOF = false
        let drainDeadline = ContinuousClock.now + .seconds(drainGraceSeconds)
        repeat {
            sawEOF = drainAvailable(fd: outFD, box: box)
            if sawEOF { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while ContinuousClock.now < drainDeadline
        if !sawEOF || !reaped { box.markTruncated() }
        // waitpid's status is an exit code only for normal exits, never for a signal.
        let normalExit = reaped && (waitStatus & 0x7f) == 0
        let exitCode: Int32 = normalExit && !timedOut ? (waitStatus >> 8) & 0xff : -1
        return (exit: exitCode, stdout: box.data, truncated: box.truncated || timedOut)
    }

    @discardableResult
    private static func drainAvailable(fd: Int32, box: ProbeOutputBox) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { box.markTruncated() }
                return false
            }
            box.append(Data(buffer.prefix(count)))
        }
        return false
    }
}

private final class ProbeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false

    init(limit: Int) { self.limit = limit }

    func markTruncated() {
        lock.lock(); defer { lock.unlock() }
        truncated = true
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if data.count >= limit {
            truncated = true
            return
        }
        let remaining = limit - data.count
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            truncated = true
        } else {
            data.append(chunk)
        }
    }
}

// MARK: - Real XPC proxy

@MainActor
final class RealPowerHelperXPCProxy: PowerHelperXPCProxying {
    private let connection: NSXPCConnection
    var onConnectionEvent: ((PowerHelperConnectionEvent) -> Void)?

    init(machServiceName: String, requirement: String) {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ChorusPowerHelperXPC.self)
        connection.setCodeSigningRequirement(requirement)
        self.connection = connection
        // C8-1: NSXPC handlers fire off MainActor — hop first, then touch actor state.
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.onConnectionEvent?(.invalidated)
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.onConnectionEvent?(.interrupted)
            }
        }
        connection.resume()
    }

    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Data?, String?) -> Void) {
        // Reply may run off MainActor; callers (withTimeout / ReplyBox) are responsible for hops.
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            reply(nil, "xpc:\(error.localizedDescription)")
        }
        guard let helper = proxy as? ChorusPowerHelperXPC else {
            reply(nil, "badProxy")
            return
        }
        helper.setSleepDisabled(enabled, withReply: reply)
    }

    func status(reply: @escaping (Data) -> Void) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            reply(Data())
        }
        guard let helper = proxy as? ChorusPowerHelperXPC else {
            reply(Data())
            return
        }
        helper.status(withReply: reply)
    }

    func invalidate() {
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        onConnectionEvent = nil
        connection.invalidate()
    }
}

private final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Thread-safe box for synchronous set replies (C8-1; must not require MainActor).
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _ok = false
    var ok: Bool {
        lock.lock(); defer { lock.unlock() }
        return _ok
    }
    func setOK(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _ok = value
    }
}
