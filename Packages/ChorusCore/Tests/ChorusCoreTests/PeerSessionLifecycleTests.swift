import Testing
@testable import ChorusCore

@Suite("RedialBackoff")
struct RedialBackoffTests {
    @Test("Steps double up to 30 s and stay there")
    func steps() {
        var backoff = RedialBackoff()
        let delays = (0..<8).map { _ in backoff.next(random: 0.5) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    }

    @Test("Jitter stays within ±20%")
    func jitterBounds() {
        var low = RedialBackoff()
        var high = RedialBackoff()
        let lowest = low.next(random: 0)
        let highest = high.next(random: 1)
        #expect(lowest == .milliseconds(800))
        #expect(highest == .milliseconds(1_200))
    }

    @Test("Reset starts over from 1 s")
    func reset() {
        var backoff = RedialBackoff()
        _ = backoff.next(random: 0.5)
        _ = backoff.next(random: 0.5)
        backoff.reset()
        let delay = backoff.next(random: 0.5)
        #expect(delay == .seconds(1))
    }
}

@Suite("PeerSessionSlots")
struct PeerSessionSlotsTests {
    /// "a" < "b"：本機是撥號方。
    private func dialer() -> PeerSessionSlots {
        var slots = PeerSessionSlots(localPeerID: "a")
        slots.start()
        return slots
    }

    private func generation(_ decision: PeerSessionSlots.DialDecision) -> UInt64? {
        if case let .start(generation) = decision { return generation }
        return nil
    }

    @Test("Only one piece of work per peer, however often discovery fires")
    func singleFlight() {
        var slots = dialer()
        let first = slots.requestDial("b", endpoint: "e1", now: .zero)
        let again = slots.requestDial("b", endpoint: "e1", now: .zero)
        let otherEndpoint = slots.requestDial("b", endpoint: "e2", now: .zero)
        #expect(generation(first) != nil)
        #expect(again == .ignore)
        #expect(otherEndpoint == .ignore)
        #expect(slots.phase(of: "b") == .dialing)
    }

    @Test("The larger peerID never dials")
    func nonDialer() {
        var slots = PeerSessionSlots(localPeerID: "z")
        slots.start()
        let decision = slots.requestDial("b", endpoint: nil, now: .zero)
        #expect(decision == .ignore)
    }

    @Test("Nothing dials before start or after stop")
    func stopped() throws {
        var slots = PeerSessionSlots(localPeerID: "a")
        let beforeStart = slots.requestDial("b", endpoint: nil, now: .zero)
        #expect(beforeStart == .ignore)
        slots.start()
        let decision1 = slots.requestDial("b", endpoint: nil, now: .zero)
        let work = try #require(generation(decision1))
        let active = slots.stop()
        #expect(active == ["b"])
        #expect(slots.phase(of: "b") == .idle)
        let afterStop = slots.requestDial("b", endpoint: nil, now: .seconds(60))
        #expect(afterStop == .ignore)
        // 停止前那件工作晚到的失敗不排重撥
        let lateFailure = slots.attemptFailed("b", generation: work, now: .seconds(1), random: 0.5)
        #expect(lateFailure == nil)
    }

    @Test("Any early failure backs off; it never stays connecting")
    func failureBacksOff() throws {
        var slots = dialer()
        let firstDecision = slots.requestDial("b", endpoint: nil, now: .zero)
        var work = try #require(generation(firstDecision))
        let ready = slots.connectReady("b", generation: work)
        #expect(ready)
        #expect(slots.phase(of: "b") == .awaitingHello)
        let firstDelay = slots.attemptFailed("b", generation: work, now: .seconds(5), random: 0.5)
        #expect(firstDelay == .seconds(1))
        #expect(slots.phase(of: "b") == .backoff(until: .seconds(6)))

        // 退避中探索到同一個端點：不理
        let duringBackoff = slots.requestDial("b", endpoint: nil, now: .seconds(5.5))
        #expect(duringBackoff == .ignore)
        let decision2 = slots.backoffElapsed("b", generation: work)
        work = try #require(generation(decision2))
        let secondDelay = slots.attemptFailed("b", generation: work, now: .seconds(6), random: 0.5)
        #expect(secondDelay == .seconds(2))
        let decision3 = slots.backoffElapsed("b", generation: work)
        work = try #require(generation(decision3))
        let thirdDelay = slots.attemptFailed("b", generation: work, now: .seconds(8), random: 0.5)
        #expect(thirdDelay == .seconds(4))
    }

    @Test("A fresh endpoint during backoff dials right away; the old timer is void")
    func freshEndpointCutsBackoff() throws {
        var slots = dialer()
        let decision4 = slots.requestDial("b", endpoint: "old", now: .zero)
        let first = try #require(generation(decision4))
        _ = slots.attemptFailed("b", generation: first, now: .zero, random: 0.5)
        let second = slots.requestDial("b", endpoint: "new", now: .milliseconds(100))
        #expect(generation(second) != nil)
        let staleTimer = slots.backoffElapsed("b", generation: first)
        #expect(staleTimer == .ignore)
    }

    @Test("Stale results never touch the newer attempt")
    func staleResults() throws {
        var slots = dialer()
        let decision5 = slots.requestDial("b", endpoint: nil, now: .zero)
        let old = try #require(generation(decision5))
        _ = slots.reset(peers: ["b"])
        let decision6 = slots.requestDial("b", endpoint: nil, now: .zero)
        let fresh = try #require(generation(decision6))
        let staleReady = slots.connectReady("b", generation: old)
        let staleFailure = slots.attemptFailed("b", generation: old, now: .zero, random: 0.5)
        let staleSession = slots.sessionEstablished("b", generation: old, now: .zero)
        #expect(!staleReady)
        #expect(staleFailure == nil)
        #expect(staleSession == nil)
        #expect(slots.phase(of: "b") == .dialing)
        let freshReady = slots.connectReady("b", generation: fresh)
        #expect(freshReady)
    }

    @Test("Connected resets backoff; a close redials after about 1 s")
    func closeRedials() throws {
        var slots = dialer()
        let firstDecision = slots.requestDial("b", endpoint: nil, now: .zero)
        var work = try #require(generation(firstDecision))
        _ = slots.attemptFailed("b", generation: work, now: .zero, random: 0.5)
        let decision7 = slots.backoffElapsed("b", generation: work)
        work = try #require(generation(decision7))
        _ = slots.connectReady("b", generation: work)
        let session = slots.sessionEstablished("b", generation: work, now: .zero)
        #expect(session == work)
        #expect(slots.phase(of: "b") == .connected)
        // 撐過 stableSession 才歸零：100 秒後斷線，從 1 秒重來
        let redial = slots.sessionClosed("b", generation: work, now: .seconds(100), random: 0.5)
        #expect(redial == .seconds(1))
        // 同一個 session 重複回報關閉：只算一次
        let duplicate = slots.sessionClosed("b", generation: work, now: .seconds(100), random: 0.5)
        #expect(duplicate == nil)
    }

    @Test("A session closed right after hello keeps backing off instead of retrying every second")
    func shortSessionKeepsBackingOff() throws {
        var slots = dialer()
        var delays: [Duration] = []
        var now = Duration.zero
        let opening = slots.requestDial("b", endpoint: nil, now: now)
        var work = try #require(generation(opening))
        for _ in 0..<4 {
            _ = slots.connectReady("b", generation: work)
            let session = slots.sessionEstablished("b", generation: work, now: now)
            #expect(session == work)
            now += .milliseconds(200)
            let closed = slots.sessionClosed("b", generation: work, now: now, random: 0.5)
            let delay = try #require(closed)
            delays.append(delay)
            now += delay
            let retry = slots.backoffElapsed("b", generation: work)
            work = try #require(generation(retry))
        }
        #expect(delays == [1, 2, 4, 8].map { Duration.seconds($0) })
    }

    @Test("Inbound sessions take over the slot and void our own dial")
    func inboundTakesOver() throws {
        var slots = dialer()
        let decision8 = slots.requestDial("b", endpoint: nil, now: .zero)
        let dial = try #require(generation(decision8))
        let established9 = slots.sessionEstablished("b", generation: nil, now: .zero)
        let inbound = try #require(established9)
        #expect(inbound != dial)
        let staleReady = slots.connectReady("b", generation: dial)
        #expect(!staleReady)
        #expect(slots.phase(of: "b") == .connected)
    }

    @Test("The non-dialer records state but never schedules a redial")
    func nonDialerClose() throws {
        var slots = PeerSessionSlots(localPeerID: "z")
        slots.start()
        let established10 = slots.sessionEstablished("b", generation: nil, now: .zero)
        let session = try #require(established10)
        let redial = slots.sessionClosed("b", generation: session, now: .zero, random: 0.5)
        #expect(redial == nil)
        #expect(slots.phase(of: "b") == .idle)
    }

    @Test("Wake voids everything and returns the peers to dial now")
    func wake() throws {
        var slots = dialer()
        let decision11 = slots.requestDial("b", endpoint: nil, now: .zero)
        let work = try #require(generation(decision11))
        _ = slots.attemptFailed("b", generation: work, now: .zero, random: 0.5)
        let dialNow = slots.reset(peers: ["b", "0", "c"])
        #expect(dialNow == ["b", "c"])
        #expect(slots.phase(of: "b") == .idle)
        let staleTimer = slots.backoffElapsed("b", generation: work)
        #expect(staleTimer == .ignore)
        let redial = slots.requestDial("b", endpoint: nil, now: .zero)
        #expect(generation(redial) != nil)
    }

    @Test("Removing a peer voids its pending work")
    func remove() throws {
        var slots = dialer()
        let decision12 = slots.requestDial("b", endpoint: nil, now: .zero)
        let work = try #require(generation(decision12))
        slots.remove("b")
        let staleReady = slots.connectReady("b", generation: work)
        #expect(!staleReady)
        #expect(slots.phase(of: "b") == .idle)
    }
}

@Suite("HelloWait")
struct HelloWaitTests {
    private let hello = Hello(peerID: "b", deviceName: "B", protocolVersion: ChorusProtocol.version)

    private func waitForSleepers(_ clock: ManualClock, count: Int = 1) async {
        while clock.sleeperCount < count {
            await Task.yield()
        }
    }

    @Test("Returns the hello and cancels the deadline")
    func receivesHello() async throws {
        let (local, remote) = InMemoryTransport.pair()
        let clock = ManualClock()
        try await remote.send(Envelope(msg: .hello(hello)))
        var iterator = local.incoming.makeAsyncIterator()
        let outcome = await HelloWait.awaitHello(from: &iterator, clock: clock, close: { local.close() })
        #expect(outcome == .hello(hello))
        // watchdog 取消後不留 sleeper
        for _ in 0..<100 where clock.sleeperCount > 0 { await Task.yield() }
        #expect(clock.sleeperCount == 0)
    }

    @Test("A silent peer times out: the connection is closed and the wait ends")
    func silentPeerTimesOut() async {
        let (local, _) = InMemoryTransport.pair()
        let clock = ManualClock()
        let task = Task {
            var iterator = local.incoming.makeAsyncIterator()
            return await HelloWait.awaitHello(
                from: &iterator, timeout: .seconds(5), clock: clock, close: { local.close() }
            )
        }
        await waitForSleepers(clock)
        clock.advance(by: .seconds(4))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        #expect(await task.value == .timedOut)
    }

    @Test("Sending our own hello counts against the same deadline")
    func ownHelloWithinDeadline() async {
        let (local, _) = InMemoryTransport.pair()
        let clock = ManualClock()
        let task = Task {
            var iterator = local.incoming.makeAsyncIterator()
            return await HelloWait.awaitHello(
                from: &iterator, timeout: .seconds(5), clock: clock,
                close: { local.close() }
            ) {
                try? await clock.sleep(for: .seconds(10)) // 送出卡住
            }
        }
        await waitForSleepers(clock, count: 2)
        clock.advance(by: .seconds(5))
        clock.advance(by: .seconds(5))
        #expect(await task.value == .timedOut)
    }

    @Test("A non-hello first message is a protocol error")
    func unexpectedFirstMessage() async throws {
        let (local, remote) = InMemoryTransport.pair()
        try await remote.send(Envelope(msg: .ping(0)))
        var iterator = local.incoming.makeAsyncIterator()
        let outcome = await HelloWait.awaitHello(from: &iterator, clock: ManualClock(), close: { local.close() })
        #expect(outcome == .unexpected)
    }

    @Test("Closed before anything arrives")
    func closedEarly() async {
        let (local, remote) = InMemoryTransport.pair()
        remote.close()
        var iterator = local.incoming.makeAsyncIterator()
        let outcome = await HelloWait.awaitHello(from: &iterator, clock: ManualClock(), close: { local.close() })
        #expect(outcome == .closed)
    }
}
