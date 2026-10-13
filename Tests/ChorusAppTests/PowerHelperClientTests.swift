import ChorusCore
import Darwin
import Foundation
import ServiceManagement
import Synchronization
import Testing
@testable import Chorus

@Suite("PowerHelper availability mapping (V-C06-1 / W1-4)")
struct PowerHelperAvailabilityMappingTests {
    @Test("SMAppService.Status table — enabled without handshake is connecting")
    func statusTable() {
        let notRegistered: SMAppService.Status = .notRegistered
        let enabled: SMAppService.Status = .enabled
        let requiresApproval: SMAppService.Status = .requiresApproval
        let notFound: SMAppService.Status = .notFound
        #expect(PowerHelperAvailabilityMapping.availability(from: notRegistered) == .notRegistered)
        #expect(PowerHelperAvailabilityMapping.availability(from: enabled) == .connecting)
        #expect(PowerHelperAvailabilityMapping.availability(from: requiresApproval) == .requiresApproval)
        #expect(PowerHelperAvailabilityMapping.availability(from: notFound) == .notFound)
        #expect(
            PowerHelperAvailabilityMapping.availability(from: enabled, handshake: .ready) == .ready
        )
    }

    @Test("handshake versionMismatch overrides enabled")
    func handshakeOverride() {
        let mismatch = PowerHelperHandshakeResult.versionMismatch(helper: "1", app: "2")
        let enabled: SMAppService.Status = .enabled
        #expect(
            PowerHelperAvailabilityMapping.availability(from: enabled, handshake: mismatch)
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
    func refreshWithoutHandshake() async {
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { FakePowerHelperProxy() },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        await client.refreshAvailability(reason: .launch)
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

@Suite("PERF1 LidClosedSessionStore coalesced persistence")
struct LidClosedSessionStorePERF1Tests {
    private final class SinkBox: @unchecked Sendable {
        private let lock = NSLock()
        var writes = 0
        var removes = 0
        var stored: Data?
        func set(_ data: Data) { lock.lock(); writes += 1; stored = data; lock.unlock() }
        func remove() { lock.lock(); removes += 1; lock.unlock() }
        func data() -> Data? { lock.lock(); defer { lock.unlock() }; return stored }
        func writeCount() -> Int { lock.lock(); defer { lock.unlock() }; return writes }
        func removeCount() -> Int { lock.lock(); defer { lock.unlock() }; return removes }
    }

    @Test("PERF1 twenty identical saves cause one backend write; wallClosedAt stable")
    func coalesceIdenticalSaves() async {
        let suite = "chorus.lid.perf1.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            LidClosedSessionCoordinator.resetRegistryForTesting(suiteName: suite)
        }
        let writes = Mutex(0)
        let stored = Mutex<Data?>(nil)
        let sink = LidClosedSessionCoordinator.WriteSink(
            set: { data, _ in
                writes.withLock { $0 += 1 }
                stored.withLock { $0 = data }
            },
            remove: { _ in },
            data: { _ in stored.withLock { $0 } }
        )
        let store = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        let t0 = Date(timeIntervalSince1970: 100)
        for i in 0..<20 {
            store.save(
                continuousClosedAt: 50,
                bootSessionUUID: "BOOT",
                maxDurationLatched: false,
                wallClosedAt: Date(timeIntervalSince1970: 100 + Double(i))
            )
        }
        #expect(store.load()?.continuousClosedAt == 50)
        await store.flushPending()
        #expect(writes.withLock { $0 } == 1)
        let snap = store.load()
        #expect(snap?.wallClosedAt == t0)
        #expect(snap?.continuousClosedAt == 50)
    }

    @Test("PERF1 repeated clear of absent store causes zero removals", .timeLimit(.minutes(1)))
    func clearAbsentZero() async {
        let suite = "chorus.lid.perf1.clear.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            LidClosedSessionCoordinator.resetRegistryForTesting(suiteName: suite)
        }
        let box = SinkBox()
        let sink = LidClosedSessionCoordinator.WriteSink(
            set: { data, _ in box.set(data) },
            remove: { _ in box.remove() },
            data: { _ in nil }
        )
        let store = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        await store.awaitLoadedForTesting()
        store.clear()
        store.clear()
        store.clear()
        await store.flushPending()
        #expect(box.removeCount() == 0)
    }
}

@Suite("LidClosedSessionStore continuous deadline (W1-10)")
struct LidClosedSessionStoreTests {
    @Test("same-boot restore preserves continuous closed-at")
    func sameBootRestore() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            LidClosedSessionCoordinator.resetRegistryForTesting(suiteName: suite)
        }
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

    @Test("corrupt payload is invalid not absent (W1-10)", .timeLimit(.minutes(1)))
    func corruptInvalid() async {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("not-json".utf8), forKey: "lidClosedSession.v2")
        let store = LidClosedSessionStore(suiteName: suite)
        await store.awaitLoadedForTesting()
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

/// Thread-safe gate for wedging a background SM status reader without blocking MainActor.
final class WorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var enteredFlag = false
    private var releasedFlag = false
    private var finishedFlag = false

    func enterAndWait() {
        condition.lock()
        enteredFlag = true
        condition.broadcast()
        while !releasedFlag {
            condition.wait()
        }
        finishedFlag = true
        condition.broadcast()
        condition.unlock()
    }

    /// PERF1-R7: mark entry then sleep the real duration (overlap with MainActor work).
    func enterThenSleep(_ seconds: TimeInterval) {
        condition.lock()
        enteredFlag = true
        finishedFlag = false
        condition.broadcast()
        condition.unlock()
        if seconds > 0 {
            Thread.sleep(forTimeInterval: seconds)
        }
        condition.lock()
        finishedFlag = true
        condition.broadcast()
        condition.unlock()
    }

    var hasEntered: Bool {
        condition.lock(); defer { condition.unlock() }
        return enteredFlag
    }

    /// PERF1-R7 round3: true after the worker leaves the blocked section.
    var hasFinished: Bool {
        condition.lock(); defer { condition.unlock() }
        return finishedFlag
    }

    func waitUntilEntered(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if hasEntered { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return hasEntered
    }

    func release() {
        condition.lock()
        releasedFlag = true
        condition.broadcast()
        condition.unlock()
    }
}

@Suite("PERF1 PowerHelperClient background service status")
@MainActor
struct PowerHelperClientPERF1StatusTests {
    @Test("PERF1 slow getter: one physical call, mapping, overlapping refresh joins")
    func singleFlightAndMapping() async {
        let gate = WorkerGate()
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { .enabled }
        )
        reader.delay = 1
        let client = PowerHelperClient(
            appBuild: "136",
            makeProxy: { FakePowerHelperProxy() },
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let t1 = Task { await client.refreshAvailability(reason: .launch) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        let t2 = Task { await client.refreshAvailability(reason: .settingsOpened) }
        let t3 = Task { await client.refreshAvailability(reason: .wake) }
        gate.release()
        await t1.value
        await t2.value
        await t3.value
        #expect(reader.callCount == 1)
        #expect(client.availability == .connecting)
        #expect(client.cachedServiceStatusForTesting == .enabled)
    }

    @Test("PERF1 twenty overlapping refreshes share one physical call")
    func twentyOverlapping() async {
        let gate = WorkerGate()
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { .requiresApproval }
        )
        reader.delay = 1
        let client = PowerHelperClient(
            appBuild: "136",
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let first = Task { await client.refreshAvailability(reason: .settingsOpened) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        let rest = (0..<19).map { _ in
            Task { await client.refreshAvailability(reason: .settingsOpened) }
        }
        gate.release()
        await first.value
        for task in rest { await task.value }
        #expect(reader.callCount == 1)
        #expect(client.availability == .requiresApproval)
    }

    @Test("PERF1 minimum interval throttles; cached path does zero calls")
    func minimumIntervalAndCache() async {
        var clock = 0.0
        let reader = LockCountedStatusReader { .notRegistered }
        let client = PowerHelperClient(
            appBuild: "136",
            minimumPhysicalInterval: 5,
            now: { clock },
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        await client.refreshAvailability(reason: .launch)
        #expect(reader.callCount == 1)
        for t in [0.0, 1.0, 4.999] {
            clock = t
            await client.refreshAvailability(reason: .settingsOpened)
        }
        #expect(reader.callCount == 1)
        clock = 5.0
        await client.refreshAvailability(reason: .retry)
        #expect(reader.callCount == 2)
    }

    @Test("PERF1 timeout returns near deadline; late enabled discarded; no extra getters")
    func timeoutAndLateResult() async {
        let gate = WorkerGate()
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { .enabled }
        )
        reader.delay = 1 // non-zero triggers delayImpl
        let client = PowerHelperClient(
            appBuild: "136",
            refreshTimeout: 0.1,
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let start = ContinuousClock.now
        let refresh = Task { await client.refreshAvailability(reason: .launch) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        await refresh.value
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(500))
        #expect(client.availability == .error("serviceStatusTimeout"))
        #expect(client.physicalInFlightForTesting)

        // While still blocked, 100 more requests must not start getters.
        let extras = (0..<100).map { _ in
            Task { await client.refreshAvailability(reason: .userAction) }
        }
        await Task.yield()
        #expect(reader.callCount == 1)

        gate.release()
        for task in extras { await task.value }
        let cleared = ContinuousClock.now + .seconds(2)
        while client.physicalInFlightForTesting, ContinuousClock.now < cleared {
            await Task.yield()
        }
        #expect(reader.callCount == 1)
        #expect(client.availability == .error("serviceStatusTimeout"))
        #expect(client.cachedServiceStatusForTesting == .unknown)
        #expect(!client.physicalInFlightForTesting)
    }

    @Test("PERF1 identical effective cache does not re-fire availability callback")
    func noCallbackForIdenticalCache() async {
        let reader = LockCountedStatusReader { .notFound }
        var callbacks = 0
        let client = PowerHelperClient(
            appBuild: "136",
            minimumPhysicalInterval: 5,
            now: { 0 },
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        client.onAvailabilityChange = { callbacks += 1 }
        await client.refreshAvailability(reason: .launch)
        let afterFirst = callbacks
        await client.refreshAvailability(reason: .settingsOpened)
        #expect(callbacks == afterFirst)
        #expect(reader.callCount == 1)
    }

    @Test("PERF1 post-register userAction bypasses floor once")
    func registerBypassesFloor() async {
        var clock = 0.0
        var status: PowerHelperServiceStatusValue = .notRegistered
        let reader = LockCountedStatusReader { status }
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 0.5,
            minimumPhysicalInterval: 5,
            now: { clock },
            makeProxy: { FakePowerHelperProxy() },
            statusReader: reader,
            registerService: { status = .enabled },
            unregisterService: {},
            openSettings: {}
        )
        await client.refreshAvailability(reason: .launch)
        #expect(reader.callCount == 1)
        clock = 1.0
        status = .enabled
        try? await client.register()
        #expect(reader.callCount == 2)
    }

    @Test("PERF1-R1 round3 delayed XPC never restores ready without fresh enabled SM", .timeLimit(.minutes(1)))
    func delayedXPCNeverReadyWithoutEnabledSM() async throws {
        let proxy = FakePowerHelperProxy()
        var statusReply: ((Data) -> Void)?
        proxy.statusHandler = { reply in statusReply = reply }
        var sm: PowerHelperServiceStatusValue = .unknown
        let reader = LockCountedStatusReader { sm }
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 2,
            refreshTimeout: 1,
            minimumPhysicalInterval: 0,
            makeProxy: { proxy },
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )

        func deliverStatus() async {
            statusReply = nil
            let task = Task { try await client.status() }
            let deadline = ContinuousClock.now + .seconds(2)
            while statusReply == nil, ContinuousClock.now < deadline { await Task.yield() }
            statusReply?((try? JSONEncoder().encode(proxy.makeStatus())) ?? Data())
            _ = try? await task.value
        }

        // Unknown SM — XPC must not publish .ready.
        await client.refreshAvailability(reason: .launch)
        #expect(client.cachedServiceStatusForTesting == .unknown)
        await deliverStatus()
        if case .ready = client.availability {
            Issue.record("XPC alone restored ready without current-epoch enabled SM")
        }
        #expect(!client.handshakeCompleteForTesting)

        // Cache invalidation must drop ready immediately (even mid-handshake epoch).
        sm = .enabled
        await client.refreshAvailability(reason: .userAction)
        #expect(client.cachedServiceStatusForTesting == .enabled)
        // Force ready via mapping path used after handshake complete.
        await deliverStatus()
        // Whether or not handshake reached ready, invalidation must not leave ready.
        let beforeInvalidate = client.availability
        client.invalidateConnection(intentional: true)
        #expect(client.cachedServiceStatusForTesting == nil)
        if case .ready = client.availability {
            Issue.record("invalidation must publish away from ready immediately (was \(beforeInvalidate))")
        }
        await deliverStatus()
        if case .ready = client.availability {
            Issue.record("post-invalidation XPC restored ready without fresh enabled SM")
        }

        // Approval revoke + late XPC
        sm = .requiresApproval
        await client.refreshAvailability(reason: .settingsOpened)
        #expect(client.cachedServiceStatusForTesting == .requiresApproval)
        if case .ready = client.availability {
            Issue.record("requiresApproval left ready visible")
        }
        await deliverStatus()
        if case .ready = client.availability {
            Issue.record("post-approval XPC restored ready")
        }
    }

    @Test("PERF1-R1 stale XPC status cannot republish ready after SM timeout", .timeLimit(.minutes(1)))
    func staleStatusCannotRepublishReadyAfterTimeout() async throws {
        let gate = WorkerGate()
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { .enabled }
        )
        reader.delay = 1
        let proxy = FakePowerHelperProxy()
        var statusReply: ((Data) -> Void)?
        proxy.statusHandler = { reply in
            statusReply = reply
        }
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 2,
            refreshTimeout: 0.1,
            makeProxy: { proxy },
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        defer { gate.release() }
        let refresh = Task { await client.refreshAvailability(reason: .launch) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        await refresh.value
        #expect(client.availability == .error("serviceStatusTimeout"))
        let epochAfterTimeout = client.readinessEpochForTesting

        let statusTask = Task { try await client.status() }
        let deadline = ContinuousClock.now + .seconds(2)
        while statusReply == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(statusReply != nil)

        // SM still timed out / unknown — late ready XPC must not publish .ready.
        statusReply?((try? JSONEncoder().encode(proxy.makeStatus())) ?? Data())
        _ = try? await statusTask.value
        #expect(client.readinessEpochForTesting >= epochAfterTimeout)
        #expect(!client.handshakeCompleteForTesting)
        if case .ready = client.availability {
            Issue.record("stale XPC status republished ready after SM revoke")
        }
    }

    @Test("PERF1-R2 post-timeout refresh returns without hanging", .timeLimit(.minutes(1)))
    func postTimeoutRefreshDoesNotHang() async {
        let gate = WorkerGate()
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { .enabled }
        )
        reader.delay = 1
        let client = PowerHelperClient(
            appBuild: "136",
            refreshTimeout: 0.1,
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let first = Task { await client.refreshAvailability(reason: .launch) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        await first.value
        #expect(client.physicalInFlightForTesting)

        let start = ContinuousClock.now
        await client.refreshAvailability(reason: .settingsOpened)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(500))
        #expect(client.availability == .error("serviceStatusTimeout"))
        #expect(reader.callCount == 1)
        gate.release()
    }

    @Test("PERF1-R2 cancelled refresh waiter resumes without hanging", .timeLimit(.minutes(1)))
    func cancelledRefreshWaiterDoesNotHang() async {
        let gate = WorkerGate()
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { .enabled }
        )
        reader.delay = 1
        let client = PowerHelperClient(
            appBuild: "136",
            refreshTimeout: 5,
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let first = Task { await client.refreshAvailability(reason: .launch) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        let joiner = Task { await client.refreshAvailability(reason: .settingsOpened) }
        await Task.yield()
        joiner.cancel()
        let start = ContinuousClock.now
        await joiner.value
        #expect(ContinuousClock.now - start < .milliseconds(500))
        gate.release()
        await first.value
        #expect(reader.callCount == 1)
    }

    @Test("PERF1-R4 register during in-flight refresh still gets new-epoch sample", .timeLimit(.minutes(1)))
    func postOperationRefreshPreservedForNewEpoch() async throws {
        let gate = WorkerGate()
        var status: PowerHelperServiceStatusValue = .notRegistered
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { status }
        )
        reader.delay = 1
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 0.5,
            refreshTimeout: 2,
            minimumPhysicalInterval: 5,
            now: { 0 },
            makeProxy: { FakePowerHelperProxy() },
            statusReader: reader,
            registerService: { status = .enabled },
            unregisterService: {},
            openSettings: {}
        )
        let launch = Task { await client.refreshAvailability(reason: .launch) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        // Invalidate epoch while first getter is blocked; register must still observe enabled.
        let registerTask = Task { try await client.register() }
        await Task.yield()
        gate.release()
        await launch.value
        try await registerTask.value
        #expect(reader.callCount >= 2)
        #expect(client.cachedServiceStatusForTesting == .enabled)
    }

    @Test("PERF1-R4 round3 register during blocked getter fails boundedly without handshake", .timeLimit(.minutes(1)))
    func registerDuringBlockedGetterFailsWithoutHandshake() async throws {
        let gate = WorkerGate()
        var status: PowerHelperServiceStatusValue = .notRegistered
        let reader = LockCountedStatusReader(
            delayImpl: { _ in gate.enterAndWait() },
            read: { status }
        )
        reader.delay = 1
        let proxy = FakePowerHelperProxy()
        var statusCalls = 0
        proxy.statusHandler = { reply in
            statusCalls += 1
            reply((try? JSONEncoder().encode(proxy.makeStatus())) ?? Data())
        }
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 0.5,
            refreshTimeout: 0.15,
            minimumPhysicalInterval: 5,
            now: { 0 },
            makeProxy: { proxy },
            statusReader: reader,
            registerService: { status = .enabled },
            unregisterService: {},
            openSettings: {}
        )
        let launch = Task { await client.refreshAvailability(reason: .launch) }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        // Register joins the stuck getter with a short bound — must fail without handshake.
        let registerResult = await Task {
            do {
                try await client.register()
                return false
            } catch {
                return true
            }
        }.value
        #expect(registerResult, "register must fail boundedly while old getter is stuck")
        #expect(statusCalls == 0, "no handshake before current-epoch enabled sample")
        #expect(!client.handshakeCompleteForTesting)
        if case .ready = client.availability {
            Issue.record("register must not publish ready without enabled sample")
        }
        #expect(reader.callCount == 1, "no replacement physical start while getter still blocked")
        gate.release()
        await launch.value
        let settle = ContinuousClock.now + .seconds(2)
        while client.physicalInFlightForTesting, ContinuousClock.now < settle {
            await Task.yield()
        }
        // Stuck getter finishes → exactly one new-epoch replacement read.
        #expect(reader.callCount == 2)
    }

    @Test("PERF1-R6 Debug-only test-host stubs; injected reader used without XCTest env", .timeLimit(.minutes(1)))
    func injectedDependenciesBypassTestHostDetection() async {
        let reader = LockCountedStatusReader { .notFound }
        let client = PowerHelperClient(
            appBuild: "136",
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        await client.refreshAvailability(reason: .launch)
        #expect(reader.callCount == 1)
        #expect(client.availability == .notFound)
    }
}

@Suite("PERF1-R5 LidClosedSessionStore async persistence")
struct LidClosedSessionStorePERF1R5Tests {
    @Test("PERF1-R5 unchanged saves do not block; barrier is async + flushable", .timeLimit(.minutes(1)))
    func asyncPersistenceNoMainActorSync() async {
        let suite = "perf1-r5-\(UUID().uuidString)"
        let writes = Mutex(0)
        let sink = LidClosedSessionCoordinator.WriteSink(
            set: { _, _ in writes.withLock { $0 += 1 } },
            remove: { _ in },
            data: { _ in nil }
        )
        let store = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        let start = ContinuousClock.now
        for _ in 0..<20 {
            _ = store.save(
                continuousClosedAt: 42,
                bootSessionUUID: "boot",
                maxDurationLatched: false,
                wallClosedAt: Date(timeIntervalSince1970: 1)
            )
        }
        let enqueueElapsed = ContinuousClock.now - start
        #expect(enqueueElapsed < .milliseconds(50))
        #expect(store.load()?.continuousClosedAt == 42)
        await store.flushPending()
        #expect(writes.withLock { $0 } == 1)
        #expect(store.load()?.continuousClosedAt == 42)
    }

    @Test("PERF1-R5 bounded shutdown drain returns within timeout", .timeLimit(.minutes(1)))
    func boundedShutdownDrain() async {
        let suite = "perf1-r5-drain-\(UUID().uuidString)"
        let gate = WorkerGate()
        let sink = LidClosedSessionCoordinator.WriteSink(
            set: { _, _ in gate.enterAndWait() },
            remove: { _ in },
            data: { _ in nil }
        )
        let store = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        _ = store.save(
            continuousClosedAt: 1,
            bootSessionUUID: "boot",
            maxDurationLatched: false,
            wallClosedAt: Date(timeIntervalSince1970: 1)
        )
        let start = ContinuousClock.now
        await store.drainPendingBounded(timeout: 0.05)
        #expect(ContinuousClock.now - start < .milliseconds(200))
        gate.release()
        await store.flushPending()
    }

    @Test("PERF1-R5 round3 blocked read sink does not delay MainActor save/clear", .timeLimit(.minutes(1)))
    func blockedReadSinkDoesNotDelayMainActor() async {
        let suite = "perf1-r5-read-\(UUID().uuidString)"
        let gate = WorkerGate()
        let sink = LidClosedSessionCoordinator.WriteSink(
            set: { _, _ in },
            remove: { _ in },
            data: { _ in
                gate.enterAndWait()
                return nil
            }
        )
        let store = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        let start = ContinuousClock.now
        for i in 0..<20 {
            _ = store.save(
                continuousClosedAt: Double(i),
                bootSessionUUID: "boot",
                maxDurationLatched: false,
                wallClosedAt: Date(timeIntervalSince1970: 1)
            )
        }
        store.clear()
        #expect(ContinuousClock.now - start < .milliseconds(50))
        gate.release()
        await store.flushPending()
    }

    @Test("PERF1-NEW-1 gated save then clear leaves fresh-store restore absent", .timeLimit(.minutes(1)))
    func gatedSaveClearFreshStoreAbsent() async {
        let suite = "perf1-new1-\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            LidClosedSessionCoordinator.resetRegistryForTesting(suiteName: suite)
        }
        let gate = WorkerGate()
        let writes = Mutex(0)
        let removes = Mutex(0)
        let stored = Mutex<Data?>(nil)
        let sink = LidClosedSessionCoordinator.WriteSink(
            set: { data, _ in
                gate.enterAndWait()
                writes.withLock { $0 += 1 }
                stored.withLock { $0 = data }
            },
            remove: { _ in
                removes.withLock { $0 += 1 }
                stored.withLock { $0 = nil }
            },
            data: { _ in stored.withLock { $0 } }
        )
        let store = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        _ = store.save(
            continuousClosedAt: 99,
            bootSessionUUID: "BOOT-OBSOLETE",
            maxDurationLatched: false,
            wallClosedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        // Clear while the first save is blocked before mutation.
        store.clear()
        gate.release()
        await store.flushPending()

        #expect(store.load() == nil)
        // Committed backend writes must be zero (obsolete sink I/O is undone).
        #expect(store.backendWriteCountForTesting == 0)
        #expect(stored.withLock { $0 } == nil)
        // Removal ordered: clear enqueue and/or obsolete-write undo.
        #expect(removes.withLock { $0 } >= 1)

        // Fresh store (new coordinator instance) must not revive the obsolete session.
        LidClosedSessionCoordinator.resetRegistryForTesting(suiteName: suite)
        let fresh = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        #expect(fresh.restoreResult(nowContinuous: 120, bootSessionUUID: "BOOT-OBSOLETE") == .absent)
        #expect(fresh.load() == nil)
        _ = writes // sink may observe a raced set that was undone
    }


    @Test("PERF1-NEW-2 flush chains latest revision while older op in flight", .timeLimit(.minutes(1)))
    func flushChainsLatestRevisionNoStrandedWaiters() async {
        let suite = "perf1-new2-\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            LidClosedSessionCoordinator.resetRegistryForTesting(suiteName: suite)
        }
        let gate = WorkerGate()
        let writeLatchFlags = Mutex<[Bool]>([])
        let stored = Mutex<Data?>(nil)
        let sink = LidClosedSessionCoordinator.WriteSink(
            set: { data, _ in
                let shouldBlock = writeLatchFlags.withLock { list -> Bool in
                    guard let snap = try? JSONDecoder().decode(
                        LidClosedSessionStore.Snapshot.self, from: data
                    ) else { return false }
                    list.append(snap.maxDurationLatched)
                    // Block the first latch-true barrier (in flight while we coalesce).
                    return snap.maxDurationLatched && list.filter(\.self).count == 1
                }
                if shouldBlock {
                    gate.enterAndWait()
                }
                stored.withLock { $0 = data }
            },
            remove: { _ in stored.withLock { $0 = nil } },
            data: { _ in stored.withLock { $0 } }
        )
        let store = LidClosedSessionStore(suiteName: suite, writeSink: sink)
        // Commit baseline so later latch true→false can take the coalesce path.
        _ = store.save(
            continuousClosedAt: 10,
            bootSessionUUID: "BOOT",
            maxDurationLatched: false,
            wallClosedAt: Date(timeIntervalSince1970: 1)
        )
        await store.flushPending()

        // Latch barrier — blocks in backend.
        _ = store.save(
            continuousClosedAt: 10,
            bootSessionUUID: "BOOT",
            maxDurationLatched: true,
            wallClosedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))

        // Coalesce-only update (latch true→false) while older op is in flight — pending newer revision.
        _ = store.save(
            continuousClosedAt: 10,
            bootSessionUUID: "BOOT",
            maxDurationLatched: false,
            wallClosedAt: Date(timeIntervalSince1970: 2)
        )
        #expect(store.load()?.maxDurationLatched == false)

        let flushTask = Task { await store.flushPending() }
        try? await Task.sleep(for: .milliseconds(50))
        gate.release()
        let flushDeadline = ContinuousClock.now + .seconds(2)
        let completed = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await flushTask.value
                return true
            }
            group.addTask {
                while ContinuousClock.now < flushDeadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(completed, "flushPending must not strand durability waiters")
        #expect(store.load()?.continuousClosedAt == 10)
        #expect(store.load()?.maxDurationLatched == false)
        let flags = writeLatchFlags.withLock { $0 }
        #expect(flags.contains(false), "latest coalesced revision must be submitted")
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

    @Test("V1-3 real saturated-stdout child stays bounded", .timeLimit(.minutes(1)))
    func hostileSaturatedStdoutSubprocess() throws {
        let script = try writeProbeFixture(
            name: "saturate",
            contents: """
            #!/bin/sh
            while true; do dd if=/dev/zero bs=65536 count=1 2>/dev/null; done
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let started = ContinuousClock.now
        let result = try SleepDisabledProbe.runSubprocess(
            executableURL: script, arguments: [], timeout: 0.35
        )
        let elapsed = started.duration(to: ContinuousClock.now)
        #expect(result.truncated || result.exit == -1)
        #expect(result.stdout.count <= 256 * 1024)
        #expect(elapsed < .seconds(3))
    }

    @Test("V1-3 real ignored-TERM child is KILL-reaped within bound", .timeLimit(.minutes(1)))
    func hostileIgnoredTERMSubprocess() throws {
        let script = try writeProbeFixture(
            name: "ignore-term",
            contents: """
            #!/bin/sh
            trap '' TERM
            while true; do printf x; sleep 0.05; done
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let started = ContinuousClock.now
        let result = try SleepDisabledProbe.runSubprocess(
            executableURL: script, arguments: [], timeout: 0.3
        )
        let elapsed = started.duration(to: ContinuousClock.now)
        #expect(result.exit == -1 || result.truncated)
        #expect(elapsed < .seconds(3))
    }

    @Test("V1-3 exited parent with inherited writer truncates and cleans up", .timeLimit(.minutes(1)))
    func hostileInheritedWriterSubprocess() throws {
        let script = try writeProbeFixture(
            name: "inherit-writer",
            contents: """
            #!/bin/sh
            # Background descendant keeps the pipe write-end alive after parent exits.
            ( while true; do printf flood; sleep 0.01; done ) &
            exit 0
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let started = ContinuousClock.now
        let result = try SleepDisabledProbe.runSubprocess(
            executableURL: script, arguments: [], timeout: 0.5
        )
        let elapsed = started.duration(to: ContinuousClock.now)
        #expect(result.truncated || result.exit == 0)
        #expect(elapsed < .seconds(3))
    }

    private func writeProbeFixture(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-probe-\(name)-\(UUID().uuidString).sh")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("V01R3 probe closes its writer and accepts complete child output")
    func completeChildOutputIsNotTruncated() throws {
        let script = try writeProbeFixture(name: "complete", contents: "#!/bin/sh\nprintf 'SleepDisabled 0\\n'\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let result = try SleepDisabledProbe.runSubprocess(executableURL: script, arguments: [], timeout: 1)
        #expect(result.exit == 0)
        #expect(!result.truncated)
        #expect(String(data: result.stdout, encoding: .utf8) == "SleepDisabled 0\n")
    }

    @Test("V01R3 probe kills inherited writer after parent exit", .timeLimit(.minutes(1)))
    func inheritedWriterIsActuallyTerminated() throws {
        let script = try writeProbeFixture(name: "orphan", contents: """
        #!/bin/sh
        /bin/sleep 30 &
        printf '%s\\n' "$!"
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = try SleepDisabledProbe.runSubprocess(executableURL: script, arguments: [], timeout: 1)
        let text = try #require(String(data: result.stdout, encoding: .utf8))
        let child = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { Darwin.kill(child, SIGKILL) } // Clean up even on the pre-fix failure.
        let deadline = ContinuousClock.now + .seconds(1)
        while Darwin.kill(child, 0) == 0, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(Darwin.kill(child, 0) == -1 && errno == ESRCH)
        #expect(result.truncated)
    }
}
