import Foundation
import Testing
@testable import ChorusCore

@Suite("KeepAwakeBusyAggregator")
struct KeepAwakeSourcesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func report(
        id: String,
        kind: KeepAwakeSourceKind = .agentActivity,
        workingNow: Bool = false,
        last: Date? = nil,
        health: KeepAwakeSourceHealth = .ok,
        name: String? = nil
    ) -> KeepAwakeSourceReport {
        KeepAwakeSourceReport(
            id: id,
            kind: kind,
            displayName: name ?? id,
            isWorkingNow: workingNow,
            lastWorkingAt: last,
            health: health
        )
    }

    @Test("V-C01-1 empty input is not busy")
    func emptyNotBusy() {
        let state = KeepAwakeBusyAggregator.evaluate([], now: now)
        #expect(!state.isBusy)
        #expect(state.contributing.isEmpty)
        #expect(state.releaseAt == nil)
    }

    @Test("V-C01-1 isWorkingNow makes busy with nil releaseAt")
    func workingNowBusy() {
        let state = KeepAwakeBusyAggregator.evaluate(
            [report(id: "orca", kind: .orca, workingNow: true, last: now)],
            now: now
        )
        #expect(state.isBusy)
        #expect(state.contributing.map(\.id) == ["orca"])
        #expect(state.releaseAt == nil)
    }

    @Test("V-C01-1 grace boundary: 299s busy, 300s not")
    func graceBoundary() {
        let last = now.addingTimeInterval(-299)
        let busy = KeepAwakeBusyAggregator.evaluate(
            [report(id: "a", last: last)],
            now: now
        )
        #expect(busy.isBusy)

        let idle = KeepAwakeBusyAggregator.evaluate(
            [report(id: "a", last: now.addingTimeInterval(-300))],
            now: now
        )
        #expect(!idle.isBusy)
        #expect(idle.contributing.isEmpty)
    }

    @Test("V-C01-1 / W0-8 future timestamp clamped: releaseAt = now+grace")
    func futureTimestamp() {
        let future = now.addingTimeInterval(600)
        let state = KeepAwakeBusyAggregator.evaluate(
            [report(id: "skew", last: future)],
            now: now
        )
        #expect(state.isBusy)
        #expect(state.contributing.map(\.id) == ["skew"])
        #expect(state.contributing.first?.lastWorkingAt == now)
        #expect(state.releaseAt == now.addingTimeInterval(300))
    }

    @Test("W0-8 normalized unchanged future evidence is idle at exactly 300s")
    func normalizedFutureIdleAtGrace() {
        // C07 第一次觀察時 clamp 並固定；此處模擬已正規化證據（不再帶未來值重送）
        let observedClamped = now
        let atBoundary = KeepAwakeBusyAggregator.evaluate(
            [report(id: "skew", last: observedClamped)],
            now: now.addingTimeInterval(300)
        )
        #expect(!atBoundary.isBusy)
        #expect(atBoundary.releaseAt == nil)
    }

    @Test("W0-8 mixed future/past reports have consistent deadlines and ordering")
    func mixedFuturePastConsistent() {
        let past = now.addingTimeInterval(-50)
        let future = now.addingTimeInterval(100)
        let state = KeepAwakeBusyAggregator.evaluate(
            [
                report(id: "past", last: past),
                report(id: "future", last: future),
            ],
            now: now
        )
        #expect(state.isBusy)
        // future clamped to now → newest; past older
        #expect(state.contributing.map(\.id) == ["future", "past"])
        #expect(state.releaseAt == now.addingTimeInterval(300))
    }

    @Test("V-C01-1 degraded source can still report working")
    func degradedStillWorking() {
        let state = KeepAwakeBusyAggregator.evaluate(
            [report(
                id: "orca",
                kind: .orca,
                workingNow: true,
                last: now,
                health: .degraded(reason: "CLI failed")
            )],
            now: now
        )
        #expect(state.isBusy)
        #expect(state.contributing.first?.health == .degraded(reason: "CLI failed"))
    }

    @Test("V-C01-1 contributing sort: workingNow first, then newest lastWorkingAt")
    func contributingSort() {
        let older = now.addingTimeInterval(-100)
        let newer = now.addingTimeInterval(-10)
        let state = KeepAwakeBusyAggregator.evaluate(
            [
                report(id: "idle-old", last: older),
                report(id: "working", workingNow: true, last: older),
                report(id: "idle-new", last: newer),
            ],
            now: now
        )
        #expect(state.contributing.map(\.id) == ["working", "idle-new", "idle-old"])
    }

    @Test("V-C01-1 releaseAt is max(lastWorkingAt)+grace when all idle in grace")
    func releaseAtCalculation() {
        let a = now.addingTimeInterval(-50)
        let b = now.addingTimeInterval(-20)
        let state = KeepAwakeBusyAggregator.evaluate(
            [
                report(id: "a", last: a),
                report(id: "b", last: b),
            ],
            now: now
        )
        #expect(state.isBusy)
        #expect(state.releaseAt == b.addingTimeInterval(300))
    }

    @Test("V-C01-1 health unavailable does not by itself make busy")
    func unavailableAloneNotBusy() {
        let state = KeepAwakeBusyAggregator.evaluate(
            [report(id: "orca", kind: .orca, health: .unavailable(reason: "missing"))],
            now: now
        )
        #expect(!state.isBusy)
    }

    @Test("V-C07-6 / W0-8: aggregator clamps future; C07 must still clamp on first observe")
    func futureMtimeStillContributesWithinGraceSemantics() {
        // 單次 evaluate 已正規化；C07 須對同一份未變動 mtime 做穩定 first-observation clamp。
        let future = now.addingTimeInterval(1)
        let state = KeepAwakeBusyAggregator.evaluate(
            [report(id: "mtime", last: future)],
            now: now
        )
        #expect(state.isBusy)
        #expect(state.releaseAt == now.addingTimeInterval(300))
    }
}
