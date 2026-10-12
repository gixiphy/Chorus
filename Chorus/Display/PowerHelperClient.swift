import ChorusCore
import Foundation
import ServiceManagement

/// App ↔ ChorusPowerHelper XPC client (spec §6.4 / §6.5 / §14.2).
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
            if let handshake {
                return handshake.availability
            }
            return .ready
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
}

/// Injectable XPC proxy for tests (V-C06-3 / V-C06-4).
@MainActor
protocol PowerHelperXPCProxying: AnyObject {
    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Data?, String?) -> Void)
    func status(reply: @escaping (Data) -> Void)
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

    private var proxy: PowerHelperXPCProxying?
    private var generation: UInt64 = 0

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
        openSettings: (() -> Void)? = nil
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
    }

    func refreshAvailability() {
        let mapped = PowerHelperAvailabilityMapping.availability(from: serviceStatus())
        applyAvailability(mapped)
    }

    func register() async throws {
        try registerService()
        refreshAvailability()
        if case .requiresApproval = availability { return }
        _ = try await status()
    }

    func unregister() async throws {
        invalidateConnection()
        try unregisterService()
        refreshAvailability()
    }

    func openApprovalSettings() {
        openSettings()
    }

    func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus {
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
        applyAvailability(handshake.availability)
        return status
    }

    /// Bounded wait for shutdown (§14.2): must not rely on sync proxy alone.
    func setSleepDisabledSynchronously(_ on: Bool, timeout: TimeInterval) -> Bool {
        let gen = beginGeneration()
        guard let proxy = try? ensureProxy() else { return false }
        let box = ReplyBox()
        let sem = DispatchSemaphore(value: 0)
        proxy.setSleepDisabled(on) { _, error in
            box.ok = (error == nil)
            sem.signal()
        }
        let result = sem.wait(timeout: .now() + timeout)
        guard gen == generation else { return false }
        return result == .success && box.ok
    }

    private func ensureProxy() throws -> PowerHelperXPCProxying {
        if let proxy { return proxy }
        guard let created = makeProxy() else { throw PowerHelperClientError.notConnected }
        proxy = created
        applyAvailability(.connecting)
        return created
    }

    func invalidateConnection() {
        generation += 1
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

    init(machServiceName: String, requirement: String) {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ChorusPowerHelperXPC.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        self.connection = connection
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
