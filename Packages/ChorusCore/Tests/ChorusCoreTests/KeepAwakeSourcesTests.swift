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

    @Test("V-C01-1 future timestamp treated as just happened")
    func futureTimestamp() {
        let future = now.addingTimeInterval(600)
        let state = KeepAwakeBusyAggregator.evaluate(
            [report(id: "skew", last: future)],
            now: now
        )
        #expect(state.isBusy)
        #expect(state.contributing.map(\.id) == ["skew"])
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

    @Test("V-C07-6 / note: same future mtime stays busy for one evaluate (clamp is source-layer)")
    func futureMtimeStillContributesWithinGraceSemantics() {
        // Aggregator itself treats future as recent; C07 must clamp on first observe.
        let future = now.addingTimeInterval(1)
        let state = KeepAwakeBusyAggregator.evaluate(
            [report(id: "mtime", last: future)],
            now: now
        )
        #expect(state.isBusy)
    }
}
