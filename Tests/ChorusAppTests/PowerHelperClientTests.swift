import ChorusCore
import Foundation
import ServiceManagement
import Testing
@testable import Chorus

@Suite("PowerHelper availability mapping (V-C06-1)")
struct PowerHelperAvailabilityMappingTests {
    @Test("SMAppService.Status table")
    func statusTable() {
        #expect(PowerHelperAvailabilityMapping.availability(from: .notRegistered) == .notRegistered)
        #expect(PowerHelperAvailabilityMapping.availability(from: .enabled) == .ready)
        #expect(PowerHelperAvailabilityMapping.availability(from: .requiresApproval) == .requiresApproval)
        #expect(PowerHelperAvailabilityMapping.availability(from: .notFound) == .notFound)
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
    private(set) var setCalls: [Bool] = []

    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Data?, String?) -> Void) {
        setCalls.append(enabled)
        if let setHandler {
            setHandler(enabled, reply)
        } else {
            let status = PowerHelperStatus(helperBuild: "136", sleepDisabled: enabled, setByHelper: enabled)
            reply(try? JSONEncoder().encode(status), nil)
        }
    }

    func status(reply: @escaping (Data) -> Void) {
        if let statusHandler {
            statusHandler(reply)
        } else {
            let status = PowerHelperStatus(helperBuild: "136")
            reply((try? JSONEncoder().encode(status)) ?? Data())
        }
    }
}

@Suite("PowerHelperClient XPC timeout (V-C06-3)")
@MainActor
struct PowerHelperClientTimeoutTests {
    @Test("silent proxy times out in ~3s")
    func timeout() async {
        let proxy = FakePowerHelperProxy()
        proxy.setHandler = { _, _ in /* never reply */ }
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

@Suite("PowerHelperClient shutdown bound (V-C06-4)")
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
        proxy.setHandler = { _, reply in
            // Reply after client invalidates.
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
            // May succeed or time out depending on race; availability must not stay holding badge.
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

@Suite("LidClosedSessionStore (Fi A3 restart deadline)")
struct LidClosedSessionStoreTests {
    @Test("restore projects wall clock into uptime domain")
    func restore() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        let wallClosed = Date(timeIntervalSince1970: 1_000)
        store.save(wallClosedAt: wallClosed, maxDurationLatched: true)
        let wallNow = Date(timeIntervalSince1970: 1_000 + 120)
        let restored = store.restoredLidClosedSince(nowUptime: 500, wallNow: wallNow)
        #expect(restored?.sinceUptime == 380)
        #expect(restored?.latched == true)
    }

    @Test("open clears session")
    func clear() {
        let suite = "chorus.lid.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LidClosedSessionStore(suiteName: suite)
        store.save(wallClosedAt: Date(), maxDurationLatched: false)
        store.clear()
        #expect(store.load() == nil)
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
}
