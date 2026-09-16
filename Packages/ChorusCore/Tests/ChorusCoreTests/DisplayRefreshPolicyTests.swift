import Testing
@testable import ChorusCore

@Suite("DisplayRefreshPolicy")
struct DisplayRefreshPolicyTests {
    private let policy = DisplayRefreshPolicy(
        coalesceWindow: .milliseconds(200),
        maxCoalesceDelay: .seconds(1),
        wakeSettle: .seconds(3)
    )

    @Test("一般通知合併到 coalesce 窗口，不立刻開始")
    func coalescesNotifications() {
        var state = DisplayRefreshPolicy.State()
        let action = policy.noteEvent(
            state: &state,
            reason: .notification,
            displayIDs: [1],
            now: .milliseconds(0)
        )
        #expect(action == .schedule(at: .milliseconds(200)))
        #expect(!state.inFlight)

        let again = policy.noteEvent(
            state: &state,
            reason: .notification,
            displayIDs: [2],
            now: .milliseconds(50)
        )
        #expect(again == .schedule(at: .milliseconds(250)))
        #expect(state.pendingDisplayIDs == [1, 2])
    }

    @Test("連續通知最多拖到 maxCoalesceDelay")
    func maxCoalesceDelay() {
        var state = DisplayRefreshPolicy.State()
        _ = policy.noteEvent(state: &state, reason: .notification, displayIDs: [], now: .zero)
        let late = policy.noteEvent(
            state: &state,
            reason: .modeChanged,
            displayIDs: [],
            now: .milliseconds(900)
        )
        #expect(late == .schedule(at: .seconds(1)))
        #expect(state.scheduledFireAt == .seconds(1))

        let fire = policy.fire(state: &state, now: .seconds(1))
        guard case let .startRefresh(_, reasons, forceFull) = fire else {
            Issue.record("expected startRefresh, got \(fire)")
            return
        }
        #expect(reasons.contains(.notification))
        #expect(reasons.contains(.modeChanged))
        #expect(!forceFull)
        #expect(state.inFlight)
        #expect(state.generation == 1)
    }

    @Test("喚醒設絕對期限；一般通知不得縮短")
    func wakeDeadlineNotShortened() {
        var state = DisplayRefreshPolicy.State()
        let wake = policy.noteWake(state: &state, now: .zero)
        #expect(wake == .schedule(at: .seconds(3)))
        #expect(state.wakeSettleUntil == .seconds(3))

        let early = policy.noteEvent(
            state: &state,
            reason: .notification,
            displayIDs: [],
            now: .milliseconds(100)
        )
        // debounce 想排到 300ms，但 wake 期限卡在 3s
        #expect(early == .none)
        #expect(state.scheduledFireAt == .seconds(3))

        let tooEarly = policy.fire(state: &state, now: .seconds(1))
        #expect(tooEarly == .schedule(at: .seconds(3)))
        #expect(!state.inFlight)

        let ready = policy.fire(state: &state, now: .seconds(3))
        guard case .startRefresh = ready else {
            Issue.record("expected startRefresh after settle")
            return
        }
    }

    @Test("重複喚醒只延長、不縮短期限")
    func repeatedWakeExtends() {
        var state = DisplayRefreshPolicy.State()
        _ = policy.noteWake(state: &state, now: .zero)
        _ = policy.noteWake(state: &state, now: .seconds(2))
        #expect(state.wakeSettleUntil == .seconds(5))
    }

    @Test("進行中只累積 pending；結束後再排")
    func pendingWhileInFlight() {
        var state = DisplayRefreshPolicy.State()
        _ = policy.noteEvent(state: &state, reason: .topologyChanged, displayIDs: [], now: .zero)
        _ = policy.fire(state: &state, now: .milliseconds(200))
        #expect(state.inFlight)

        let during = policy.noteEvent(
            state: &state,
            reason: .notification,
            displayIDs: [9],
            now: .milliseconds(300)
        )
        #expect(during == .none)
        #expect(state.pendingReasons == [.notification])

        let after = policy.refreshFinished(state: &state, generation: 1, now: .milliseconds(400))
        #expect(after == .schedule(at: .milliseconds(400)))
        #expect(!state.inFlight)
    }

    @Test("舊 generation 結束不影響新狀態")
    func staleGenerationFinishIgnored() {
        var state = DisplayRefreshPolicy.State()
        _ = policy.noteEvent(state: &state, reason: .userForce, displayIDs: [], now: .zero)
        _ = policy.fire(state: &state, now: .milliseconds(200))
        let gen = state.generation
        let ignored = policy.refreshFinished(state: &state, generation: gen &- 1, now: .seconds(1))
        #expect(ignored == .none)
        #expect(state.inFlight)
    }
}
