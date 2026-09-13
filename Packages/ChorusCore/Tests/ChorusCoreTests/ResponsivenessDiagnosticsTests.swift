import Testing
@testable import ChorusCore

@Suite("LatencyHistogram")
struct LatencyHistogramTests {
    @Test("Empty histogram has no percentiles")
    func empty() {
        let histogram = LatencyHistogram()
        #expect(histogram.percentile(0.95) == nil)
        #expect(histogram.meanMillis == nil)
    }

    @Test("Percentile reports the bucket upper bound, capped by the observed max")
    func percentileBuckets() {
        var histogram = LatencyHistogram()
        for _ in 0..<95 { histogram.record(millis: 5) }
        for _ in 0..<5 { histogram.record(millis: 700) }
        #expect(histogram.count == 100)
        #expect(histogram.percentile(0.5) == 8)
        #expect(histogram.percentile(0.95) == 8)
        #expect(histogram.percentile(0.96) == 700)
        #expect(histogram.maxMillis == 700)
    }

    @Test("Values beyond the last bound land in the overflow bucket")
    func overflow() {
        var histogram = LatencyHistogram()
        histogram.record(.seconds(30))
        #expect(histogram.bucketCounts.last == 1)
        #expect(histogram.percentile(0.99) == 30_000)
    }

    @Test("Duration converts to fractional milliseconds")
    func durationMillis() {
        #expect(Duration.milliseconds(1_500).millis == 1_500)
        #expect(Duration.microseconds(250).millis == 0.25)
    }
}

@Suite("MainLoopProbe")
struct MainLoopProbeTests {
    private let thresholds = MainLoopProbe.Thresholds(lag: .milliseconds(500), hang: .seconds(2))

    @Test("Only one probe is outstanding at a time")
    func singleProbe() {
        var probe = MainLoopProbe(thresholds: thresholds)
        let first = probe.tick(now: .seconds(1))
        #expect(first.probe != nil)
        #expect(probe.tick(now: .seconds(1.5)).probe == nil)
        _ = probe.answer(probe: first.probe!, now: .milliseconds(1_010))
        #expect(probe.tick(now: .seconds(2)).probe != nil)
    }

    @Test("Fast answers record latency without lag")
    func fastAnswer() {
        var probe = MainLoopProbe(thresholds: thresholds)
        let id = probe.tick(now: .zero).probe!
        #expect(probe.answer(probe: id, now: .milliseconds(20)).isEmpty)
        #expect(probe.lifetime.latency.count == 1)
        #expect(probe.lifetime.lagCount == 0)
        #expect(probe.lifetime.hangCount == 0)
    }

    @Test("A stuck main loop reports hang once, then its total stall on recovery")
    func hangLifecycle() {
        var probe = MainLoopProbe(thresholds: thresholds)
        let id = probe.tick(now: .zero).probe!
        #expect(probe.tick(now: .seconds(1)).events.isEmpty)
        #expect(probe.tick(now: .seconds(2)).events == [.hangBegan(pendingFor: .seconds(2))])
        #expect(probe.tick(now: .seconds(3)).events.isEmpty)
        #expect(probe.pendingAge(now: .seconds(3)) == .seconds(3))
        #expect(probe.answer(probe: id, now: .seconds(4)) == [.hangEnded(stall: .seconds(4))])
        #expect(probe.lifetime.hangCount == 1)
        #expect(probe.lifetime.lagCount == 1)
        #expect(probe.lifetime.longestStall == .seconds(4))
    }

    @Test("A hang the timer never saw is still counted when the probe returns")
    func hangSeenOnlyAtAnswer() {
        var probe = MainLoopProbe(thresholds: thresholds)
        let id = probe.tick(now: .zero).probe!
        #expect(probe.answer(probe: id, now: .seconds(3)) == [.hangEnded(stall: .seconds(3))])
        #expect(probe.lifetime.hangCount == 1)
    }

    @Test("Discarded probes (sleep/wake) are ignored when they finally run")
    func discardPending() {
        var probe = MainLoopProbe(thresholds: thresholds)
        let id = probe.tick(now: .zero).probe!
        probe.discardPending()
        #expect(probe.answer(probe: id, now: .seconds(60)).isEmpty)
        #expect(probe.lifetime.latency.count == 0)
    }

    @Test("Window summaries reset while lifetime keeps accumulating")
    func windows() {
        var probe = MainLoopProbe(thresholds: thresholds)
        let id = probe.tick(now: .zero).probe!
        _ = probe.answer(probe: id, now: .milliseconds(600))
        let window = probe.takeWindow()
        #expect(window.lagCount == 1)
        #expect(probe.window.lagCount == 0)
        #expect(probe.lifetime.lagCount == 1)
    }
}

@Suite("OperationLedger")
struct OperationLedgerTests {
    @Test("Begin/end tracks in-flight count, outcome and latency")
    func beginEnd() {
        var ledger = OperationLedger()
        let a = ledger.begin("cloud.write", now: .zero)
        let b = ledger.begin("cloud.write", now: .seconds(1))
        #expect(ledger.operations["cloud.write"]?.inFlight == 2)
        #expect(ledger.operations["cloud.write"]?.inFlightHighWater == 2)

        let result = ledger.end(a, outcome: .success, now: .seconds(3))
        #expect(result?.elapsed == .seconds(3))
        ledger.end(b, outcome: .failure, now: .seconds(2))
        let stats = ledger.operations["cloud.write"]!
        #expect(stats.inFlight == 0)
        #expect(stats.inFlightHighWater == 2)
        #expect(stats.outcomes[.success] == 1)
        #expect(stats.outcomes[.failure] == 1)
        #expect(stats.completed == 2)
    }

    @Test("Ending a token twice is ignored")
    func doubleEnd() {
        var ledger = OperationLedger()
        let token = ledger.begin("sync.send", now: .zero)
        #expect(ledger.end(token, outcome: .success, now: .seconds(1)) != nil)
        #expect(ledger.end(token, outcome: .success, now: .seconds(2)) == nil)
        #expect(ledger.operations["sync.send"]?.completed == 1)
    }

    @Test("Stalls are reported once per token, and oldest age is tracked")
    func stalls() {
        var ledger = OperationLedger()
        let token = ledger.begin("sync.hello", now: .zero)
        _ = ledger.begin("sync.hello", now: .seconds(8))
        #expect(ledger.collectNewStalls(now: .seconds(4), threshold: .seconds(5)).isEmpty)
        #expect(ledger.collectNewStalls(now: .seconds(10), threshold: .seconds(5))
            == [.init(token: token, name: "sync.hello", age: .seconds(10))])
        #expect(ledger.collectNewStalls(now: .seconds(20), threshold: .seconds(5)).count == 1) // only the second
        #expect(ledger.oldestInFlightAge(now: .seconds(20))["sync.hello"] == .seconds(20))
    }

    @Test("Name and in-flight tables are bounded")
    func bounded() {
        var ledger = OperationLedger(maxNames: 2, maxInFlight: 3)
        _ = ledger.begin("a", now: .zero)
        _ = ledger.begin("b", now: .zero)
        _ = ledger.begin("c", now: .zero)
        #expect(Set(ledger.operations.keys) == ["a", "b", OperationLedger.overflowName])
        #expect(ledger.begin("a", now: .zero) == 0)
        #expect(ledger.untrackedBegins == 1)
        ledger.end(0, outcome: .success, now: .zero)
        #expect(ledger.operations["a"]?.completed == 0)
    }

    @Test("Gauges keep current and high-water, never below zero")
    func gauges() {
        var ledger = OperationLedger()
        ledger.adjustGauge("ddc.queue", by: 3)
        ledger.adjustGauge("ddc.queue", by: -2)
        #expect(ledger.gauges["ddc.queue"] == {
            var gauge = GaugeStats()
            gauge.current = 1
            gauge.highWater = 3
            return gauge
        }())
        ledger.adjustGauge("ddc.queue", by: -5)
        #expect(ledger.gauges["ddc.queue"]?.current == 0)
    }
}

@Suite("FaultSpec")
struct FaultSpecTests {
    @Test("Parses each behavior")
    func parsesBehaviors() throws {
        #expect(try FaultSpec.parse("cloud.write=delay:3.5") == (.cloudWrite, .delay(.milliseconds(3_500))))
        #expect(try FaultSpec.parse("cloud.scan=hang") == (.cloudScan, .hang))
        #expect(try FaultSpec.parse("sync.send=fail") == (.syncSend, .fail))
        #expect(try FaultSpec.parse("sync.hello=withhold") == (.syncHello, .withhold))
        #expect(try FaultSpec.parse("cloud.read=off") == (.cloudRead, nil))
    }

    @Test("Rejects unknown points, behaviors and unsupported combinations")
    func rejects() {
        #expect(throws: FaultSpec.ParseError.malformed("cloud.write")) { try FaultSpec.parse("cloud.write") }
        #expect(throws: FaultSpec.ParseError.unknownPoint("disk.write")) { try FaultSpec.parse("disk.write=fail") }
        #expect(throws: FaultSpec.ParseError.unknownBehavior("explode")) { try FaultSpec.parse("cloud.write=explode") }
        #expect(throws: FaultSpec.ParseError.unsupported(point: .cloudWrite, behavior: "withhold")) {
            try FaultSpec.parse("cloud.write=withhold")
        }
        #expect(throws: FaultSpec.ParseError.unsupported(point: .syncHello, behavior: "fail")) {
            try FaultSpec.parse("sync.hello=fail")
        }
        #expect(throws: FaultSpec.ParseError.delayOutOfRange("delay:0")) { try FaultSpec.parse("cloud.write=delay:0") }
        #expect(throws: FaultSpec.ParseError.delayOutOfRange("delay:9999")) { try FaultSpec.parse("cloud.write=delay:9999") }
    }
}

@Suite("ManualClock")
struct ManualClockTests {
    private func waitForSleepers(_ clock: ManualClock, count: Int) async {
        while clock.sleeperCount < count {
            await Task.yield()
        }
    }

    @Test("Sleep resumes only after time is advanced past the deadline")
    func advanceWakes() async throws {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(for: .seconds(5)) }
        await waitForSleepers(clock, count: 1)
        clock.advance(by: .seconds(4))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        try await task.value
        #expect(clock.sleeperCount == 0)
        #expect(clock.now == ManualClock.Instant(offset: .seconds(5)))
    }

    @Test("A deadline already in the past returns immediately")
    func pastDeadline() async throws {
        let clock = ManualClock()
        clock.advance(by: .seconds(10))
        try await clock.sleep(until: ManualClock.Instant(offset: .seconds(3)), tolerance: nil)
    }

    @Test("Cancellation throws and removes the sleeper")
    func cancellation() async {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(for: .seconds(5)) }
        await waitForSleepers(clock, count: 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test("Works as a deadline source for a timeout race")
    func timeoutRace() async {
        let clock = ManualClock()
        let outcome = Task { () -> String in
            await withTaskGroup(of: String.self) { group in
                group.addTask {
                    do {
                        try await clock.sleep(for: .seconds(5))
                        return "timeout"
                    } catch {
                        return "cancelled"
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3_600))
                    return "work"
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
        }
        await waitForSleepers(clock, count: 1)
        clock.advance(by: .seconds(5))
        #expect(await outcome.value == "timeout")
    }
}
