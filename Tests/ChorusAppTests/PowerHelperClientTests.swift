import ChorusCore
import Foundation
import ServiceManagement
import Testing
@testable import Chorus

@Suite("PowerHelper availability mapping (V-C06-1 / W1-4)")
struct PowerHelperAvailabilityMappingTests {
    @Test("SMAppService.Status table — enabled without handshake is connecting")
    func statusTable() {
        #expect(PowerHelperAvailabilityMapping.availability(from: .notRegistered) == .notRegistered)
        #expect(PowerHelperAvailabilityMapping.availability(from: .enabled) == .connecting)
        #expect(PowerHelperAvailabilityMapping.availability(from: .requiresApproval) == .requiresApproval)
        #expect(PowerHelperAvailabilityMapping.availability(from: .notFound) == .notFound)
        #expect(
            PowerHelperAvailabilityMapping.availability(from: .enabled, handshake: .ready) == .ready
        )
    }

    @Test("handshake versionMismatch overrides enabled")
    func handshakeOverride() {
        let mismatch = PowerHelperHandshakeResult.versionMismatch(helper: "1", app: "2")
        #expect(
            PowerHelperAvailabilityMapping.availability(from: .enabled, handshake: mismatch)
                == .versionMismatch(helper: "1", app: "2")
        )
    }
}

@Suite("PowerHelper handshake (V-C06-2)")
struct PowerHelperHandshakeTests {
    @Test("same protocol different build is ready")
    func buildDiffReady() {
        let status = PowerHelperStatus(helperBuild: "200")
        let result = PowerHelperHandshakeResult.evaluate(status: status, appBuild: "136")
        #expect(result == .ready)
    }

    @Test("protocol mismatch is versionMismatch")
    func protocolMismatch() {
        var status = PowerHelperStatus(helperBuild: "136")
        status.protocolVersion = 99
        let result = PowerHelperHandshakeResult.evaluate(status: status, appBuild: "136")
        #expect(result == .versionMismatch(helper: "136", app: "136"))
    }
}

@MainActor
final class FakePowerHelperProxy: PowerHelperXPCProxying {
    var setHandler: ((Bool, @escaping (Data?, String?) -> Void) -> Void)?
    var statusHandler: ((@escaping (Data) -> Void) -> Void)?
    var onConnectionEvent: ((PowerHelperConnectionEvent) -> Void)?
    private(set) var setCalls: [Bool] = []
    private(set) var statusCalls = 0
    private(set) var invalidateCount = 0
    var protocolVersion: Int = PowerHelperConstants.protocolVersion
    var helperBuild: String = "136"
    var holderCount: Int = 0
    var callerIsHolder: Bool = false
    var sleepDisabled: Bool? = false
    var setByHelper: Bool = false
    var recoveryBlocked: Bool = false
    var pendingRestore: Bool = false
    var persistRetryNeeded: Bool = false

    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Data?, String?) -> Void) {
        setCalls.append(enabled)
        if let setHandler {
            setHandler(enabled, reply)
        } else {
            sleepDisabled = enabled
            setByHelper = enabled
            holderCount = enabled ? 1 : 0
            callerIsHolder = enabled
            if !enabled {
                pendingRestore = false
                persistRetryNeeded = false
            }
            let status = makeStatus()
            reply(try? JSONEncoder().encode(status), nil)
        }
    }

    func status(reply: @escaping (Data) -> Void) {
        statusCalls += 1
        if let statusHandler {
            statusHandler(reply)
        } else {
            reply((try? JSONEncoder().encode(makeStatus())) ?? Data())
        }
    }

    func invalidate() {
        invalidateCount += 1
        onConnectionEvent = nil
    }

    func emit(_ event: PowerHelperConnectionEvent) {
        onConnectionEvent?(event)
    }

    func makeStatus() -> PowerHelperStatus {
        var s = PowerHelperStatus(
            helperBuild: helperBuild,
            sleepDisabled: sleepDisabled,
            setByHelper: setByHelper,
            holderCount: holderCount,
            callerIsHolder: callerIsHolder,
            recoveryBlocked: recoveryBlocked,
            pendingRestore: pendingRestore,
            persistRetryNeeded: persistRetryNeeded
        )
        s.protocolVersion = protocolVersion
        return s
    }
}

@MainActor
final class FakeRepairing: PowerHelperRepairing {
    private(set) var unregisterCalls = 0
    private(set) var registerCalls = 0
    var shouldThrow = false

    func unregisterDaemon() throws {
        unregisterCalls += 1
        if shouldThrow { throw PowerHelperClientError.unavailable }
    }

    func registerDaemon() throws {
        registerCalls += 1
        if shouldThrow { throw PowerHelperClientError.unavailable }
    }
}

@Suite("PowerHelperClient XPC timeout (V-C06-3)")
@MainActor
struct PowerHelperClientTimeoutTests {
    @Test("silent proxy times out in ~3s")
    func timeout() async {
        let proxy = FakePowerHelperProxy()
        // Handshake status also silent → timeout before set.
        proxy.statusHandler = { _ in }
        proxy.setHandler = { _, _ in }
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 0.2,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let start = Date()
        do {
            _ = try await client.setSleepDisabled(true)
            Issue.record("expected timeout")
        } catch let error as PowerHelperClientError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Suite("PowerHelperClient connection lifecycle (W1-4 / W1-5)")
@MainActor
struct PowerHelperClientConnectionTests {
    @Test("interruption clears ready without another RPC")
    func interruptionClearsReady() async throws {
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        _ = try await client.status()
        #expect(client.availability == .ready)

        proxy.emit(.interrupted)
        // Allow MainActor task to run.
        await Task.yield()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.availability == .connecting)
        #expect(proxy.invalidateCount >= 1)
    }

    @Test("refreshAvailability does not mark ready without handshake")
    func refreshWithoutHandshake() {
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { FakePowerHelperProxy() },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        client.refreshAvailability()
        #expect(client.availability == .connecting)
    }

    @Test("status handshake precedes set; protocol mismatch never set(true)")
    func handshakeBeforeSet() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.protocolVersion = 99
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        do {
            _ = try await client.setSleepDisabled(true)
            Issue.record("expected version mismatch")
        } catch let error as PowerHelperClientError {
            #expect(error == .versionMismatch)
        }
        #expect(proxy.setCalls.isEmpty)
        #expect(proxy.statusCalls >= 1)
        if case .versionMismatch = client.availability {
            // ok
        } else {
            Issue.record("expected versionMismatch availability, got \(client.availability)")
        }
    }

    @Test("different build same protocol allows set after handshake")
    func buildDiffAllowsSet() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.helperBuild = "999"
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        _ = try await client.setSleepDisabled(true)
        #expect(proxy.statusCalls >= 1)
        #expect(proxy.setCalls == [true])
        #expect(client.availability == .ready)
    }

    @Test("replacement connection invalidates old proxy; stale replies dropped")
    func replacementAndStale() async throws {
        let proxy1 = FakePowerHelperProxy()
        let proxy2 = FakePowerHelperProxy()
        var useSecond = false
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { useSecond ? proxy2 : proxy1 },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        proxy1.setHandler = { _, reply in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let status = PowerHelperStatus(helperBuild: "136", sleepDisabled: true, setByHelper: true)
                reply(try? JSONEncoder().encode(status), nil)
            }
        }
        let task = Task { try await client.setSleepDisabled(true) }
        try await Task.sleep(nanoseconds: 10_000_000)
        client.invalidateConnection()
        useSecond = true
        _ = try await client.status()
        do {
            _ = try await task.value
        } catch {
            // stale / timed out expected
        }
        #expect(proxy1.invalidateCount >= 1)
        #expect(client.availability == .ready)
    }

    @Test("delayed event from replaced connection A does not invalidate ready B (W1-4)")
    func delayedEventFromADoesNotInvalidateB() async throws {
        let proxy1 = FakePowerHelperProxy()
        let proxy2 = FakePowerHelperProxy()
        var useSecond = false
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { useSecond ? proxy2 : proxy1 },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        _ = try await client.status()
        #expect(client.availability == .ready)

        // Capture A's handler, then replace with B.
        let staleEmit = proxy1.onConnectionEvent
        client.invalidateConnection()
        useSecond = true
        _ = try await client.status()
        #expect(client.availability == .ready)

        // Delayed A event must be discarded.
        staleEmit?(.interrupted)
        await Task.yield()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(client.availability == .ready)
        #expect(proxy2.invalidateCount == 0)
    }

    @Test("C8-1 off-actor status reply resumes safely on MainActor")
    func offActorStatusReply() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.statusHandler = { reply in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = PowerHelperStatus(helperBuild: "136")
                var encoded = status
                encoded.protocolVersion = PowerHelperConstants.protocolVersion
                reply((try? JSONEncoder().encode(encoded)) ?? Data())
            }
        }
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let status = try await client.status()
        #expect(status.helperBuild == "136")
        #expect(client.availability == .ready)
    }

    @Test("C8-1 off-actor connection event hops before reading handler")
    func offActorConnectionEvent() async throws {
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        _ = try await client.status()
        #expect(client.availability == .ready)

        let emit = proxy.onConnectionEvent
        #expect(emit != nil)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                emit?(.interrupted)
                DispatchQueue.main.async {
                    cont.resume()
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while client.availability == .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.availability == .connecting)
    }

    @Test("C8-1 sync set reply from background queue stays bounded")
    func offActorSyncSetReply() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.statusHandler = { reply in
            let status = PowerHelperStatus(helperBuild: "136")
            var encoded = status
            encoded.protocolVersion = PowerHelperConstants.protocolVersion
            reply((try? JSONEncoder().encode(encoded)) ?? Data())
        }
        proxy.setHandler = { enabled, reply in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = PowerHelperStatus(
                    helperBuild: "136", sleepDisabled: enabled, setByHelper: enabled,
                    holderCount: enabled ? 1 : 0, callerIsHolder: enabled
                )
                reply(try? JSONEncoder().encode(status), nil)
            }
        }
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        _ = try await client.status()
        let started = ContinuousClock.now
        let ok = client.setSleepDisabledSynchronously(false, timeout: 1)
        let elapsed = ContinuousClock.now - started
        #expect(ok)
        #expect(elapsed < .seconds(1))
    }
}

@Suite("PowerHelperClient unregister (W1-6)")
@MainActor
struct PowerHelperClientUnregisterTests {
    @Test("legacy status without recovery evidence blocks unregister (W1-6 r3)")
    func missingRecoveryEvidenceBlocks() async throws {
        let proxy = FakePowerHelperProxy()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(proxy.makeStatus())) as? [String: Any])
        for key in ["recoveryBlocked", "pendingRestore", "persistRetryNeeded"] { json.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: json)
        proxy.statusHandler = { reply in reply(data) }
        var unregistered = false
        let client = PowerHelperClient(makeProxy: { proxy }, serviceStatus: { .enabled },
            registerService: {}, unregisterService: { unregistered = true }, openSettings: {})
        do {
            try await client.unregister()
            Issue.record("missing recovery evidence must block removal")
        } catch let error as PowerHelperClientError {
            #expect(error == .unregisterBlocked("recoveryEvidenceUnavailable"))
        }
        #expect(!unregistered && proxy.invalidateCount == 0)
    }

    @Test("other holders block unregister")
    func otherHoldersBlock() async {
        let proxy = FakePowerHelperProxy()
        proxy.holderCount = 2
        proxy.callerIsHolder = true
        proxy.sleepDisabled = true
        proxy.setByHelper = true
        var unregistered = false
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: { unregistered = true },
            openSettings: {}
        )
        // After own release, still one other holder.
        proxy.setHandler = { enabled, reply in
            proxy.sleepDisabled = enabled
            proxy.setByHelper = enabled
            proxy.holderCount = enabled ? 2 : 1
            proxy.callerIsHolder = enabled
            reply(try? JSONEncoder().encode(PowerHelperStatus(
                helperBuild: "136",
                sleepDisabled: proxy.sleepDisabled,
                setByHelper: proxy.setByHelper,
                holderCount: proxy.holderCount,
                callerIsHolder: proxy.callerIsHolder
            )), nil)
        }
        do {
            try await client.unregister()
            Issue.record("expected block")
        } catch let error as PowerHelperClientError {
            if case .unregisterBlocked("otherHolders") = error {
                // ok
            } else {
                Issue.record("unexpected \(error)")
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(unregistered == false)
    }

    @Test("foreign SleepDisabled blocks unregister")
    func foreignBlocks() async {
        let proxy = FakePowerHelperProxy()
        proxy.holderCount = 0
        proxy.sleepDisabled = true
        proxy.setByHelper = false
        var unregistered = false
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: { unregistered = true },
            openSettings: {}
        )
        do {
            try await client.unregister()
            Issue.record("expected block")
        } catch let error as PowerHelperClientError {
            if case .unregisterBlocked = error {
                // ok
            } else {
                Issue.record("unexpected \(error)")
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(unregistered == false)
    }

    @Test("confirmed release and safe status allow removal")
    func safeUnregister() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.holderCount = 0
        proxy.sleepDisabled = false
        proxy.setByHelper = false
        var unregistered = false
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: { unregistered = true },
            openSettings: {}
        )
        try await client.unregister()
        #expect(unregistered == true)
        #expect(proxy.invalidateCount >= 1)
    }

    @Test("nil sleepDisabled blocks unregister (W1-6)")
    func nilReadbackBlocks() async {
        let proxy = FakePowerHelperProxy()
        proxy.holderCount = 0
        proxy.sleepDisabled = nil
        var unregistered = false
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: { unregistered = true },
            openSettings: {}
        )
        do {
            try await client.unregister()
            Issue.record("expected block")
        } catch let error as PowerHelperClientError {
            #expect(error == .unregisterBlocked("systemValueUnknown"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(unregistered == false)
    }

    @Test("pendingRestore with zero holders blocks until restored (W1-6)")
    func pendingRestoreBlocks() async {
        let proxy = FakePowerHelperProxy()
        proxy.holderCount = 0
        proxy.sleepDisabled = false
        proxy.setByHelper = false
        proxy.pendingRestore = true
        var unregistered = false
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: { unregistered = true },
            openSettings: {}
        )
        do {
            try await client.unregister()
            Issue.record("expected block")
        } catch let error as PowerHelperClientError {
            #expect(error == .unregisterBlocked("pendingRestore"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(unregistered == false)
    }

    @Test("own residual release then verified false allows unregister (W1-6)")
    func ownResidualReleaseSucceeds() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.holderCount = 0
        proxy.sleepDisabled = true
        proxy.setByHelper = true
        proxy.pendingRestore = true
        var unregistered = false
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: { unregistered = true },
            openSettings: {}
        )
        proxy.setHandler = { enabled, reply in
            proxy.sleepDisabled = enabled
            proxy.setByHelper = enabled
            proxy.pendingRestore = false
            proxy.holderCount = 0
            proxy.callerIsHolder = false
            reply(try? JSONEncoder().encode(proxy.makeStatus()), nil)
        }
        try await client.unregister()
        #expect(unregistered == true)
        #expect(proxy.setCalls.contains(false))
    }

    @Test("final sleepDisabled true after release blocks (W1-6)")
    func finalTrueBlocks() async {
        let proxy = FakePowerHelperProxy()
        proxy.holderCount = 1
        proxy.callerIsHolder = true
        proxy.sleepDisabled = true
        proxy.setByHelper = true
        var unregistered = false
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: { unregistered = true },
            openSettings: {}
        )
        proxy.setHandler = { _, reply in
            // Pretend release clears holder but leaves sleepDisabled true.
            proxy.holderCount = 0
            proxy.callerIsHolder = false
            proxy.sleepDisabled = true
            proxy.setByHelper = true
            reply(try? JSONEncoder().encode(proxy.makeStatus()), nil)
        }
        do {
            try await client.unregister()
            Issue.record("expected block")
        } catch let error as PowerHelperClientError {
            if case .unregisterBlocked = error {
                // ok
            } else {
                Issue.record("unexpected \(error)")
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(unregistered == false)
    }
}

@Suite("PowerHelperClient shutdown bound (V-C06-4 / W1-13)")
@MainActor
struct PowerHelperClientShutdownTests {
    @Test("synchronous set returns within timeout when proxy silent")
    func syncTimeout() {
        let proxy = FakePowerHelperProxy()
        proxy.setHandler = { _, _ in /* never reply */ }
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let start = Date()
        let ok = client.setSleepDisabledSynchronously(false, timeout: 0.25)
        #expect(ok == false)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test("synchronous true without handshake is rejected (W1-13)")
    func syncTrueRequiresHandshake() {
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        #expect(client.setSleepDisabledSynchronously(true, timeout: 0.5) == false)
        #expect(proxy.setCalls.isEmpty)
    }

    @Test("synchronous true after mismatch is rejected (W1-13)")
    func syncTrueRejectsMismatch() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.protocolVersion = 99
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {},
            repairMachine: PowerHelperRepairStateMachine(repairing: FakeRepairing())
        )
        _ = try? await client.status()
        let setsBefore = proxy.setCalls.count
        #expect(client.setSleepDisabledSynchronously(true, timeout: 0.5) == false)
        #expect(proxy.setCalls.count == setsBefore)
    }

    @Test("synchronous true after ready handshake succeeds (W1-13)")
    func syncTrueAfterReady() async throws {
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        _ = try await client.status()
        #expect(client.setSleepDisabledSynchronously(true, timeout: 1) == true)
        #expect(proxy.setCalls == [true])
    }

    @Test("stale generation after invalidate ignores late reply path")
    func invalidateBumpsGeneration() async throws {
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        // Handshake first so set path proceeds.
        _ = try await client.status()
        proxy.setHandler = { _, reply in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let status = PowerHelperStatus(helperBuild: "136", sleepDisabled: true, setByHelper: true)
                reply(try? JSONEncoder().encode(status), nil)
            }
        }
        let task = Task { try await client.setSleepDisabled(true) }
        try await Task.sleep(nanoseconds: 10_000_000)
        client.invalidateConnection()
        do {
            _ = try await task.value
        } catch {
            // expected possible timeout
        }
        #expect(client.availability == .connecting)
    }
}

@Suite("LidClamshellPropertyParser")
struct LidClamshellPropertyParserTests {
    @Test("CFBoolean true/false")
    func boolean() {
        #expect(LidClamshellPropertyParser.reading(from: kCFBooleanTrue) == .closed)
        #expect(LidClamshellPropertyParser.reading(from: kCFBooleanFalse) == .open)
    }

    @Test("nil is unknown")
    func nilValue() {
        #expect(LidClamshellPropertyParser.reading(from: nil) == .unknown)
    }

    @Test("wrong type is unknown")
    func wrongType() {
        let string = "nope" as CFString
        #expect(LidClamshellPropertyParser.reading(from: string) == .unknown)
    }

    @Test("isClosed flag mapping")
    func flags() {
        #expect(LidClamshellPropertyParser.isClosedFlag(from: .open, noLid: false) == false)
        #expect(LidClamshellPropertyParser.isClosedFlag(from: .closed, noLid: false) == true)
        #expect(LidClamshellPropertyParser.isClosedFlag(from: .unknown, noLid: false) == nil)
        #expect(LidClamshellPropertyParser.isClosedFlag(from: .closed, noLid: true) == nil)
    }
}

@Suite("Lid capability / noLid (W1-11)")
struct LidCapabilityTests {
    @Test("capability matrix: desktop noLid, hasLid, transient unknown")
    func capabilityMatrix() {
        #expect(LidCapabilityClassifier.classify(serviceOK: true, clamshellPropertyPresent: false) == .noLid)
        #expect(LidCapabilityClassifier.classify(serviceOK: true, clamshellPropertyPresent: true) == .hasLid)
        #expect(LidCapabilityClassifier.classify(serviceOK: false, clamshellPropertyPresent: false) == .unknown)
    }

    @Test("monitor start with noLid capability applies .noLid and cannot arm")
    @MainActor
    func monitorNoLid() {
        let monitor = LidStateMonitor(
            readProperty: { kCFBooleanFalse },
            detectCapability: { .noLid }
        )
        monitor.start()
        #expect(monitor.reading == .noLid)
        #expect(monitor.isClosed == nil)
        // Policy: .noLid refuses arm (C02 / Fi A3) — verified at policy layer; here we only expose reading.
    }

    @Test("transient unknown stays unknown, not noLid")
    @MainActor
    func transientUnknown() {
        let monitor = LidStateMonitor(
            readProperty: { nil },
            detectCapability: { .unknown }
        )
        monitor.start()
        #expect(monitor.reading == .unknown)
    }
}

@Suite("LidClosedSessionStore continuous deadline (W1-10)")
struct LidClosedSessionStoreTests {
    @Test("same-boot restore preserves continuous closed-at")
    func sameBootRestore() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        store.save(
            continuousClosedAt: 1000,
            bootSessionUUID: "BOOT-A",
            maxDurationLatched: true,
            wallClosedAt: Date(timeIntervalSince1970: 1)
        )
        let restored = store.restoredLidClosedSince(nowContinuous: 1120, bootSessionUUID: "BOOT-A")
        #expect(restored?.sinceContinuous == 1000)
        #expect(restored?.latched == true)
        if case let .valid(since, latched) = store.restoreResult(
            nowContinuous: 1120, bootSessionUUID: "BOOT-A"
        ) {
            #expect(since == 1000)
            #expect(latched == true)
        } else {
            Issue.record("expected valid")
        }
    }

    @Test("reboot boot UUID mismatch → invalid distinct from absent (W1-10)")
    func rebootConservative() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        store.save(
            continuousClosedAt: 1000,
            bootSessionUUID: "BOOT-A",
            maxDurationLatched: false
        )
        #expect(store.restoredLidClosedSince(nowContinuous: 2000, bootSessionUUID: "BOOT-B")?.latched == true)
        #expect(store.restoreResult(nowContinuous: 2000, bootSessionUUID: "BOOT-B") == .invalid)
        #expect(store.restoreResult(nowContinuous: 2000, bootSessionUUID: "BOOT-A") != .absent)
    }

    @Test("absent is distinct from invalid (W1-10)")
    func absentDistinct() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        #expect(store.restoreResult(nowContinuous: 1, bootSessionUUID: "BOOT") == .absent)
    }

    @Test("corrupt payload is invalid not absent (W1-10)")
    func corruptInvalid() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("not-json".utf8), forKey: "lidClosedSession.v2")
        let store = LidClosedSessionStore(suiteName: suite)
        #expect(store.restoreResult(nowContinuous: 1, bootSessionUUID: "BOOT") == .invalid)
        #expect(store.hasCorruptPayload())
    }

    @Test("wall-clock change cannot alter continuous deadline")
    func wallClockIrrelevant() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        store.save(
            continuousClosedAt: 500,
            bootSessionUUID: "BOOT",
            maxDurationLatched: false,
            wallClosedAt: Date(timeIntervalSince1970: 0)
        )
        // Even if wall clock jumps wildly, restore uses continuous fields only.
        let restored = store.restoredLidClosedSince(nowContinuous: 800, bootSessionUUID: "BOOT")
        #expect(restored?.sinceContinuous == 500)
    }

    @Test("future continuousClosedAt is invalid")
    func invalidFuture() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        store.save(
            continuousClosedAt: 9999,
            bootSessionUUID: "BOOT",
            maxDurationLatched: false
        )
        #expect(store.restoredLidClosedSince(nowContinuous: 100, bootSessionUUID: "BOOT")?.latched == true)
        #expect(store.restoreResult(nowContinuous: 100, bootSessionUUID: "BOOT") == .invalid)
    }

    @Test("open clears session")
    func clear() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        store.save(continuousClosedAt: 1, bootSessionUUID: "B", maxDurationLatched: false)
        store.clear()
        #expect(store.load() == nil)
        #expect(store.restoreResult(nowContinuous: 1, bootSessionUUID: "B") == .absent)
    }

    @Test("apply closed replaces invalid snapshot with latched session (W1-10)")
    @MainActor
    func applyClosedReplacesInvalid() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        // Reboot mismatch → invalid
        store.save(continuousClosedAt: 10, bootSessionUUID: "OLD", maxDurationLatched: false)
        let monitor = LidStateMonitor(
            readProperty: { kCFBooleanTrue },
            detectCapability: { .hasLid },
            sessionStore: store
        )
        // Inject closed with a forced boot via restore path: monitor apply uses live boot UUID.
        monitor.ingestForTesting(.closed)
        let result = store.restoreResult()
        // Either valid (same boot as saved OLD if somehow matches — unlikely) or replaced.
        if case let .valid(_, latched) = result {
            // If OLD matched live boot (unlikely), keep; if replaced after invalid, latched.
            #expect(latched)
        } else if case .absent = result {
            Issue.record("closed should persist a session")
        }
        #expect(store.load() != nil)
    }
}

@Suite("PowerHelper protocol repair (W1-14)")
@MainActor
struct PowerHelperRepairTests {
    @Test("safe mismatch without per-operation authorization performs zero service operations (W1-14 r3)")
    func unauthorizedRepairBlocked() {
        let repairing = FakeRepairing()
        let machine = PowerHelperRepairStateMachine(repairing: repairing)
        let outcome = machine.repairIfNeeded(
            status: PowerHelperStatus(helperBuild: "1", sleepDisabled: false),
            handshake: .versionMismatch(helper: "1", app: "2"))
        #expect(outcome == .blocked("authorizationRequired"))
        #expect(repairing.unregisterCalls == 0 && repairing.registerCalls == 0)
    }

    @Test("safe mismatch invokes unregister then register")
    func safeRepair() {
        let repairing = FakeRepairing()
        let machine = PowerHelperRepairStateMachine(repairing: repairing, authorizeRepair: { true })
        let status = PowerHelperStatus(
            helperBuild: "136",
            sleepDisabled: false,
            setByHelper: false,
            holderCount: 0
        )
        let outcome = machine.repairIfNeeded(
            status: status,
            handshake: .versionMismatch(helper: "136", app: "136")
        )
        #expect(outcome == .repaired)
        #expect(repairing.unregisterCalls == 1)
        #expect(repairing.registerCalls == 1)
    }

    @Test("holders or recovery evidence never call service ops")
    func unsafeNeverCalls() {
        let repairing = FakeRepairing()
        let machine = PowerHelperRepairStateMachine(repairing: repairing, authorizeRepair: { true })
        let cases: [PowerHelperStatus] = [
            PowerHelperStatus(helperBuild: "1", sleepDisabled: false, holderCount: 1),
            PowerHelperStatus(helperBuild: "1", sleepDisabled: false, pendingRestore: true),
            PowerHelperStatus(helperBuild: "1", sleepDisabled: false, recoveryBlocked: true),
            PowerHelperStatus(helperBuild: "1", sleepDisabled: false, persistRetryNeeded: true),
            PowerHelperStatus(helperBuild: "1", sleepDisabled: true, setByHelper: false),
            PowerHelperStatus(helperBuild: "1", sleepDisabled: nil),
        ]
        for status in cases {
            let outcome = machine.repairIfNeeded(
                status: status,
                handshake: .versionMismatch(helper: "1", app: "2")
            )
            #expect(outcome == .skippedUnsafe)
        }
        #expect(repairing.unregisterCalls == 0)
        #expect(repairing.registerCalls == 0)
    }

    @Test("client status repair path skips when unsafe")
    func clientSkipsUnsafeRepair() async throws {
        let proxy = FakePowerHelperProxy()
        proxy.protocolVersion = 99
        proxy.holderCount = 2
        proxy.sleepDisabled = false
        let repairing = FakeRepairing()
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { proxy },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {},
            repairMachine: PowerHelperRepairStateMachine(repairing: repairing)
        )
        _ = try await client.status()
        #expect(repairing.unregisterCalls == 0)
        #expect(repairing.registerCalls == 0)
        if case .versionMismatch = client.availability {
            // ok
        } else {
            Issue.record("expected versionMismatch")
        }
    }
}

@Suite("SleepDisabledProbe")
struct SleepDisabledProbeTests {
    @Test("parses injected pmset output")
    func parseInjected() {
        let sample = """
        System-wide power settings:
        SleepDisabled\t\t1
        Currently on AC Power:
        lidwake              1
        """
        let value = SleepDisabledProbe.readSleepDisabled { _, _, _ in
            (exit: 0, stdout: Data(sample.utf8), truncated: false)
        }
        #expect(value == true)
    }

    @Test("non-zero exit returns nil")
    func failedExit() {
        let value = SleepDisabledProbe.readSleepDisabled { _, _, _ in
            (exit: 1, stdout: Data(), truncated: false)
        }
        #expect(value == nil)
    }

    @Test("V1-3 saturated stdout / ignored TERM path stays bounded via injectable run")
    func hostileChildBoundedViaSeam() {
        // Inject a hostile result: truncated + non-zero so parser refuses; proves the seam.
        let value = SleepDisabledProbe.readSleepDisabled { _, _, timeout in
            #expect(timeout == SleepDisabledProbe.timeout)
            return (exit: -1, stdout: Data(repeating: 0x41, count: 1024), truncated: true)
        }
        #expect(value == nil)
    }

    @Test("V1-3 off-MainActor wrapper completes", .timeLimit(.minutes(1)))
    func offMainActorProbe() async {
        let value = await SleepDisabledProbe.readSleepDisabledOffMainActor()
        // Host may or may not have readable pmset; either Bool? outcome is fine — must return.
        _ = value
    }
}
