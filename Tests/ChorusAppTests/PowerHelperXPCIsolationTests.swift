import ChorusCore
import Foundation
import Synchronization
import Testing
@testable import Chorus

enum B139XPCFixtures {
    static func encodeStatus(
        helperBuild: String = "136",
        sleepDisabled: Bool? = false,
        setByHelper: Bool = false
    ) -> Data {
        var status = PowerHelperStatus(
            helperBuild: helperBuild,
            sleepDisabled: sleepDisabled,
            setByHelper: setByHelper,
            holderCount: setByHelper ? 1 : 0,
            callerIsHolder: setByHelper
        )
        status.protocolVersion = PowerHelperConstants.protocolVersion
        return (try? JSONEncoder().encode(status)) ?? Data()
    }

    /// Dead helper: missing mach service reliably fires NSXPC errorHandler (plan §3.1 fallback).
    /// Anonymous-invalidate did not fire errorHandler in hosted RED on this machine.
    @MainActor
    static func deadProxy() -> RealPowerHelperXPCProxy {
        let name = "com.hermes.Chorus.b139test.\(UUID().uuidString)"
        let connection = NSXPCConnection(machServiceName: name, options: [])
        return RealPowerHelperXPCProxy(testConnection: connection)
    }
}

/// Exported object for live anonymous listener reply-path tests (X3).
/// Replies on a background queue to exercise off-main XPC reply delivery.
/// `ChorusPowerHelperXPC` reply types are not `@Sendable` (protocol frozen); use
/// `nonisolated(unsafe)` so the test can still call them from `DispatchQueue.global`.
final class B139TestHelperExported: NSObject, ChorusPowerHelperXPC {
    func setSleepDisabled(
        _ enabled: Bool,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        nonisolated(unsafe) let reply = reply
        let data = B139XPCFixtures.encodeStatus(sleepDisabled: enabled, setByHelper: enabled)
        DispatchQueue.global(qos: .userInitiated).async {
            reply(data, nil)
        }
    }

    func status(withReply reply: @escaping (Data) -> Void) {
        nonisolated(unsafe) let reply = reply
        let data = B139XPCFixtures.encodeStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            reply(data)
        }
    }
}

/// Keeps an anonymous listener alive and optionally invalidates the accepted peer (X3/X4).
final class B139AnonymousListenerHost: NSObject, NSXPCListenerDelegate {
    let listener = NSXPCListener.anonymous()
    private let exported = B139TestHelperExported()
    private let lock = NSLock()
    private var accepted: NSXPCConnection?

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    func start() {
        listener.delegate = self
        listener.resume()
    }

    func invalidateAcceptedPeer() {
        lock.lock()
        let peer = accepted
        accepted = nil
        lock.unlock()
        peer?.invalidate()
    }

    func stop() {
        lock.lock()
        let peer = accepted
        accepted = nil
        lock.unlock()
        peer?.invalidate()
        listener.invalidate()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ChorusPowerHelperXPC.self)
        newConnection.exportedObject = exported
        lock.lock()
        accepted = newConnection
        lock.unlock()
        newConnection.resume()
        return true
    }
}

@Suite("B139 XPC callback isolation")
@MainActor
struct PowerHelperXPCIsolationTests {
    @Test("X1 real NSXPC error path status reply off main", .timeLimit(.minutes(1)))
    func x1StatusErrorPath() async {
        let count = Mutex(0)
        let onMain = Mutex(true)
        let proxy = B139XPCFixtures.deadProxy()
        defer { proxy.invalidate() }

        let data = await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            proxy.status { @Sendable reply in
                onMain.withLock { $0 = Thread.isMainThread }
                count.withLock { $0 += 1 }
                cont.resume(returning: reply)
            }
        }
        #expect(data.isEmpty)
        #expect(count.withLock { $0 } == 1)
        #expect(onMain.withLock { $0 } == false)
    }

    @Test("X2 real NSXPC error path setSleepDisabled reply off main", .timeLimit(.minutes(1)))
    func x2SetErrorPath() async {
        let count = Mutex(0)
        let onMain = Mutex(true)
        let proxy = B139XPCFixtures.deadProxy()
        defer { proxy.invalidate() }

        let result = await withCheckedContinuation {
            (cont: CheckedContinuation<(Data?, String?), Never>) in
            proxy.setSleepDisabled(true) { @Sendable data, code in
                onMain.withLock { $0 = Thread.isMainThread }
                count.withLock { $0 += 1 }
                cont.resume(returning: (data, code))
            }
        }
        #expect(result.0 == nil)
        #expect(result.1?.hasPrefix("xpc:") == true)
        #expect(count.withLock { $0 } == 1)
        #expect(onMain.withLock { $0 } == false)
    }

    @Test("X3 real NSXPC reply path from background exported object", .timeLimit(.minutes(1)))
    func x3LiveReplyPath() async throws {
        let host = B139AnonymousListenerHost()
        host.start()
        defer { host.stop() }

        let connection = NSXPCConnection(listenerEndpoint: host.endpoint)
        let proxy = RealPowerHelperXPCProxy(testConnection: connection)
        defer { proxy.invalidate() }

        let count = Mutex(0)
        let onMain = Mutex(true)
        let data = await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            proxy.status { @Sendable reply in
                onMain.withLock { $0 = Thread.isMainThread }
                count.withLock { $0 += 1 }
                cont.resume(returning: reply)
            }
        }
        let status = try JSONDecoder().decode(PowerHelperStatus.self, from: data)
        #expect(status.helperBuild == "136")
        #expect(count.withLock { $0 } == 1)
        #expect(onMain.withLock { $0 } == false)
    }

    @Test("X4 real NSXPC invalidation hops to MainActor", .timeLimit(.minutes(1)))
    func x4InvalidationHandler() async {
        let host = B139AnonymousListenerHost()
        host.start()
        defer { host.stop() }

        let connection = NSXPCConnection(listenerEndpoint: host.endpoint)
        let proxy = RealPowerHelperXPCProxy(testConnection: connection)

        // Warm the connection so the peer is accepted.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proxy.status { @Sendable _ in cont.resume() }
        }

        let eventBox = Mutex<PowerHelperConnectionEvent?>(nil)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let gate = Mutex(false)
            proxy.onConnectionEvent = { @Sendable evt in
                MainActor.assertIsolated()
                // Prefer `.invalidated`; ignore a racing `.interrupted` so the first
                // resume is the handler we installed for T3 (same helper as T4).
                guard evt == .invalidated else { return }
                eventBox.withLock { $0 = evt }
                let first = gate.withLock { (taken: inout Bool) -> Bool in
                    if taken { return false }
                    taken = true
                    return true
                }
                if first { cont.resume() }
            }
            // Client-side invalidate with handlers still installed (DEBUG seam).
            // Listener-side peer invalidate alone was not reliably delivering
            // `.invalidated` before a racing `.interrupted` in hosted tests.
            proxy.invalidateConnectionKeepingHandlersForTesting()
        }
        #expect(eventBox.withLock { $0 } == .invalidated)
        proxy.invalidate()
    }

    @Test("X5 PowerHelperClient status with dead helper does not crash", .timeLimit(.minutes(1)))
    func x5ClientStatusDeadHelper() async {
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { B139XPCFixtures.deadProxy() },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        await client.refreshAvailability(reason: .launch)
        var threw = false
        do {
            _ = try await client.status()
        } catch is PowerHelperClientError {
            threw = true
        } catch {
            threw = true
        }
        #expect(threw)
        if case .ready = client.availability {
            Issue.record("availability must not be ready with dead helper")
        }
    }

    @Test("X6 sync set with dead helper returns false quickly", .timeLimit(.minutes(1)))
    func x6SyncSetDeadHelper() async {
        let client = PowerHelperClient(
            appBuild: "136",
            callTimeout: 1,
            makeProxy: { B139XPCFixtures.deadProxy() },
            serviceStatus: { .enabled },
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        await client.refreshAvailability(reason: .launch)
        let started = ContinuousClock.now
        let ok = client.setSleepDisabledSynchronously(false, timeout: 0.5)
        let elapsed = ContinuousClock.now - started
        #expect(!ok)
        #expect(elapsed < .seconds(1))
    }
}
