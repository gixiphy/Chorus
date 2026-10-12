import ChorusCore
import Foundation
import ServiceManagement

/// App ↔ ChorusPowerHelper XPC client (spec §6.4 / §6.5 / §14.2 / W1-4..6 / W1-13..14).
@MainActor
protocol PowerHelperClienting: AnyObject {
    var availability: LidHelperAvailability { get }
    var onAvailabilityChange: (() -> Void)? { get set }
    func refreshAvailability()
    func register() async throws
    func unregister() async throws
    func openApprovalSettings()
    func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus
    func status() async throws -> PowerHelperStatus
    func setSleepDisabledSynchronously(_ on: Bool, timeout: TimeInterval) -> Bool
}

/// Maps `SMAppService.Status` → `LidHelperAvailability` (pure; V-C06-1).
enum PowerHelperAvailabilityMapping {
    static func availability(
        from status: SMAppService.Status,
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
        @unknown default:
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
    private(set) var unregisterCalls = 0
    private(set) var registerCalls = 0

    init(repairing: PowerHelperRepairing) {
        self.repairing = repairing
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
    private let serviceStatus: () -> SMAppService.Status
    private let registerService: () throws -> Void
    private let unregisterService: () throws -> Void
    private let openSettings: () -> Void
    private let repairMachine: PowerHelperRepairStateMachine?

    private var proxy: PowerHelperXPCProxying?
    /// Identity of the current proxy — connection events must match (W1-4).
    private var connectionToken: UInt64 = 0
    private var nextConnectionToken: UInt64 = 1
    private var generation: UInt64 = 0
    /// True only after a successful status() handshake on the current connection (W1-5).
    private var handshakeComplete = false
    /// At most one automatic repair attempt per client instance (W1-14).
    private var didAttemptProtocolRepair = false

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
        makeProxy: (() -> PowerHelperXPCProxying?)? = nil,
        serviceStatus: (() -> SMAppService.Status)? = nil,
        registerService: (() throws -> Void)? = nil,
        unregisterService: (() throws -> Void)? = nil,
        openSettings: (() -> Void)? = nil,
        repairMachine: PowerHelperRepairStateMachine? = nil
    ) {
        self.plistName = plistName
        self.appBuild = appBuild
        self.isRelease = isRelease
        self.callTimeout = callTimeout
        self.makeProxy = makeProxy ?? {
            RealPowerHelperXPCProxy(
                machServiceName: PowerHelperConstants.machServiceName,
                requirement: PowerHelperConstants.helperRequirement(forRelease: isRelease)
            )
        }
        let daemon = SMAppService.daemon(plistName: plistName)
        self.serviceStatus = serviceStatus ?? { daemon.status }
        self.registerService = registerService ?? { try daemon.register() }
        self.unregisterService = unregisterService ?? { try daemon.unregister() }
        self.openSettings = openSettings ?? { SMAppService.openSystemSettingsLoginItems() }
        if let repairMachine {
            self.repairMachine = repairMachine
        } else if registerService != nil || unregisterService != nil {
            // Injected test seams — wrap them so repair never touches real SMAppService.
            self.repairMachine = PowerHelperRepairStateMachine(
                repairing: InjectedRepairing(register: registerService ?? {}, unregister: unregisterService ?? {})
            )
        } else {
            // Production: repair uses the same daemon APIs (Fi A1; not exercised in verifier).
            self.repairMachine = PowerHelperRepairStateMachine(
                repairing: InjectedRepairing(
                    register: { try daemon.register() },
                    unregister: { try daemon.unregister() }
                )
            )
        }
    }

    func refreshAvailability() {
        let mapped = PowerHelperAvailabilityMapping.availability(
            from: serviceStatus(),
            handshake: handshakeComplete ? .ready : nil
        )
        // If SM says enabled but we have no handshake, stay connecting (W1-4).
        if case .enabled = serviceStatus(), !handshakeComplete {
            applyAvailability(.connecting)
            return
        }
        applyAvailability(mapped)
    }

    func register() async throws {
        try registerService()
        refreshAvailability()
        if case .requiresApproval = availability { return }
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
            try Self.verifyUnregisterEvidence(after, phase: .afterRelease)
        } else if snap.sleepDisabled == true, snap.setByHelper || snap.pendingRestore {
            // Own residual / pending restore without live holders — attempt release (W1-6).
            _ = try await setSleepDisabled(false)
            let after = try await status()
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
        try Self.verifyUnregisterEvidence(finalStatus, phase: .final)

        invalidateConnection()
        try unregisterService()
        handshakeComplete = false
        refreshAvailability()
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
        let data: Data = try await withTimeout(callTimeout) { continuation in
            proxy.status { statusJSON in
                continuation(.success(statusJSON))
            }
        }
        guard gen == generation else { throw PowerHelperClientError.timedOut }
        let status = try decodeStatus(data)
        let handshake = PowerHelperHandshakeResult.evaluate(status: status, appBuild: appBuild)
        if case .versionMismatch = handshake, !didAttemptProtocolRepair {
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
        handshakeComplete = (handshake == .ready)
        applyAvailability(handshake.availability)
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
        proxy.setSleepDisabled(on) { _, error in
            box.ok = (error == nil)
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
        handshakeComplete = false
        proxy?.onConnectionEvent = nil
        proxy?.invalidate()
        proxy = nil
        applyAvailability(.connecting)
        _ = event
    }

    func invalidateConnection() {
        generation += 1
        handshakeComplete = false
        connectionToken = 0
        proxy?.onConnectionEvent = nil
        proxy?.invalidate()
        proxy = nil
        applyAvailability(.connecting)
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
                guard gate.claim() else { return }
                continuation.resume(with: result)
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

    static func runSubprocess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> (exit: Int32, stdout: Data, truncated: Bool) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [:]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.launch()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return (exit: -1, stdout: Data(), truncated: true)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let truncated = data.count > 256 * 1024
        return (exit: process.terminationStatus, stdout: data.prefix(256 * 1024), truncated: truncated)
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
        // Bind handlers to this proxy instance; client discards events if token/proxy mismatch (W1-4).
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            let handler = self.onConnectionEvent
            Task { @MainActor in
                handler?(.invalidated)
            }
        }
        connection.interruptionHandler = { [weak self] in
            guard let self else { return }
            let handler = self.onConnectionEvent
            Task { @MainActor in
                handler?(.interrupted)
            }
        }
        connection.resume()
    }

    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Data?, String?) -> Void) {
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

private final class ReplyBox: @unchecked Sendable {
    var ok = false
}
