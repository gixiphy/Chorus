import Foundation
import Testing
@testable import ChorusCore

@Suite("LidSleepGuardPolicy")
struct LidSleepGuardTests {
    private let t0: Double = 1_000

    private func settings(
        enabled: Bool = true,
        floor: Int = 30,
        maxSeconds: Double = 3 * 3600,
        limitOnAC: Bool = true
    ) -> LidSleepSettings {
        LidSleepSettings(
            enabled: enabled,
            batteryFloorPercent: floor,
            maxLidClosedSeconds: maxSeconds,
            limitDurationOnAC: limitOnAC
        )
    }

    private func power(
        battery: Bool = true,
        onBattery: Bool? = true,
        percent: Int? = 80,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> PowerSnapshot {
        PowerSnapshot(
            hasInternalBattery: battery,
            onBattery: onBattery,
            percent: percent,
            thermal: thermal
        )
    }

    private func input(
        settings: LidSleepSettings? = nil,
        agent: Bool = true,
        busy: Bool = true,
        helper: LidHelperAvailability = .ready,
        lid: LidClosedReading = .open,
        power: PowerSnapshot? = nil,
        now: Double? = nil,
        existingFloor: KeepAwakeBatteryFloor = .percent20
    ) -> LidSleepGuardInput {
        LidSleepGuardInput(
            settings: settings ?? self.settings(),
            agentModeActive: agent,
            busy: busy,
            helper: helper,
            lid: lid,
            power: power ?? self.power(),
            now: now ?? t0,
            existingBatteryFloor: existingFloor
        )
    }

    private func run(
        previous: LidSleepGuardState = .init(),
        input: LidSleepGuardInput
    ) -> (LidSleepGuardState, Bool, [LidSleepGuardEvent]) {
        let result = LidSleepGuardPolicy.step(previous, input: input)
        return (result.state, result.wantsSleepDisabled, result.events)
    }

    // MARK: §5.3 points

    @Test("§5.3.1 positive: closed sets lidClosedSince; §5.3.1 negative: open clears")
    func lidTiming() {
        var state = LidSleepGuardState()
        let (closed, _, _) = run(previous: state, input: input(lid: .closed, now: 50))
        #expect(closed.lidClosedSince == 50)

        let (opened, _, _) = run(previous: closed, input: input(lid: .open, now: 60))
        #expect(opened.lidClosedSince == nil)
        #expect(!opened.maxDurationLatched)
    }

    @Test("V-C02-7 true→unknown→true does not clear maxDuration latch")
    func unknownDoesNotClearLatch() {
        var state = LidSleepGuardState(lidClosedSince: 0, maxDurationLatched: true)
        let (mid, _, _) = run(previous: state, input: input(lid: .unknown, now: 10))
        #expect(mid.maxDurationLatched)
        #expect(mid.lidClosedSince == 0)

        let (again, _, _) = run(previous: mid, input: input(lid: .closed, now: 20))
        #expect(again.maxDurationLatched)
        #expect(again.lidClosedSince == 0)
    }

    @Test("§5.3.2 positive: userPaused blocks; negative: expired clears")
    func userPaused() {
        let paused = LidSleepGuardState(userPausedUntil: t0 + 100)
        let (blocked, wants, _) = run(previous: paused, input: input(now: t0 + 50))
        #expect(blocked.phase == .blocked(.userPaused(untilUptime: t0 + 100)))
        #expect(!wants)

        let (restored, wants2, _) = run(previous: paused, input: input(now: t0 + 100))
        #expect(restored.userPausedUntil == nil)
        #expect(restored.phase == .armed)
        #expect(wants2)
    }

    @Test("§14.2 off / non-agent takes priority over userPaused")
    func offBeatsUserPaused() {
        let paused = LidSleepGuardState(userPausedUntil: t0 + 999)
        let (off, _, _) = run(previous: paused, input: input(settings: settings(enabled: false), now: t0))
        #expect(off.phase == .off)

        let (off2, _, _) = run(previous: paused, input: input(agent: false, now: t0))
        #expect(off2.phase == .off)
    }

    @Test("§5.3.3 positive: disabled or non-agent → off; negative: both on continues")
    func offConditions() {
        let (a, _, _) = run(input: input(settings: settings(enabled: false)))
        #expect(a.phase == .off)
        let (b, _, _) = run(input: input(agent: false))
        #expect(b.phase == .off)
        let (c, wants, _) = run(input: input())
        #expect(c.phase == .armed)
        #expect(wants)
    }

    @Test("§5.3.4 positive: helper not ready → unavailable; negative: ready continues")
    func helperAvailability() {
        let (u, wants, _) = run(input: input(helper: .requiresApproval))
        #expect(u.phase == .unavailable(.requiresApproval))
        #expect(!wants)
        let (ok, _, _) = run(input: input(helper: .ready))
        #expect(ok.phase == .armed)
    }

    @Test("§5.3.5 positive: !busy → idle; negative: busy continues")
    func idleWhenNotBusy() {
        let (idle, wants, _) = run(input: input(busy: false))
        #expect(idle.phase == .idle)
        #expect(!wants)
        let (armed, _, _) = run(input: input(busy: true))
        #expect(armed.phase == .armed)
    }

    @Test("V-C02-3 thermal: fair arms; serious/critical block even with lid open")
    func thermal() {
        let (fair, wants, _) = run(input: input(power: power(thermal: .fair)))
        #expect(fair.phase == .armed)
        #expect(wants)

        let (serious, wants2, _) = run(input: input(power: power(thermal: .serious)))
        #expect(serious.phase == .blocked(.thermal))
        #expect(!wants2)

        let (critical, _, _) = run(input: input(power: power(thermal: .critical)))
        #expect(critical.phase == .blocked(.thermal))
    }

    @Test("V-C02-2 battery floor = max(30, settings, existing); nil percent blocked on known battery")
    func batteryFloor() {
        // existing 20 → effective 30
        let (a, _, _) = run(input: input(
            settings: settings(floor: 30),
            power: power(percent: 29),
            existingFloor: .percent20
        ))
        #expect(a.phase == .blocked(.lowBattery(percent: 29, floor: 30)))

        // settings 40 → 40
        let (b, _, _) = run(input: input(
            settings: settings(floor: 40),
            power: power(percent: 39),
            existingFloor: .percent20
        ))
        #expect(b.phase == .blocked(.lowBattery(percent: 39, floor: 40)))

        let (nilPct, _, _) = run(input: input(power: power(onBattery: true, percent: nil)))
        guard case let .blocked(.lowBattery(percent, floor)) = nilPct.phase else {
            Issue.record("expected lowBattery")
            return
        }
        #expect(percent == nil)
        #expect(floor == 30)
    }

    @Test("W0-3 / Fi A3 unknown power refuses from off, armed, and holding")
    func unknownPowerRefuses() {
        let cases: [(LidSleepGuardState, Int?)] = [
            (.init(), nil),
            (.init(), 100),
            (.init(), 10),
            (.init(phase: .armed), 100),
            (.init(phase: .holdingLidClosed(sinceUptime: 0), lidClosedSince: 0), 100),
        ]
        for (previous, percent) in cases {
            let lid: LidClosedReading = {
                if case .holdingLidClosed = previous.phase { return .closed }
                return .open
            }()
            let (state, wants, _) = run(
                previous: previous,
                input: input(lid: lid, power: power(onBattery: nil, percent: percent))
            )
            #expect(state.phase == .blocked(.unknownPower))
            #expect(!wants)
        }

        // 已知 AC／電池正例
        let (ac, acWants, _) = run(input: input(power: power(onBattery: false, percent: 100)))
        #expect(ac.phase == .armed)
        #expect(acWants)
        let (bat, batWants, _) = run(input: input(power: power(onBattery: true, percent: 80)))
        #expect(bat.phase == .armed)
        #expect(batWants)
    }

    @Test("W0-11 unknown power with no internal battery refuses; known AC/no-battery positive")
    func unknownPowerNoBatteryRefuses() {
        let phases: [LidSleepGuardState] = [
            .init(),
            .init(phase: .armed),
            .init(phase: .holdingLidClosed(sinceUptime: 0), lidClosedSince: 0),
        ]
        for previous in phases {
            let lid: LidClosedReading = {
                if case .holdingLidClosed = previous.phase { return .closed }
                return .open
            }()
            let (state, wants, _) = run(
                previous: previous,
                input: input(
                    lid: lid,
                    power: power(battery: false, onBattery: nil, percent: nil)
                )
            )
            #expect(state.phase == .blocked(.unknownPower))
            #expect(!wants)
        }

        // 正例：無內建電池 + 已知 AC → 可 arm（跳過電量百分比）
        let (ac, acWants, _) = run(
            input: input(power: power(battery: false, onBattery: false, percent: nil))
        )
        #expect(ac.phase == .armed)
        #expect(acWants)
    }

    @Test("V-C02-2 hysteresis 29→34 blocked, 35 clears; AC clears latch")
    func batteryHysteresis() {
        var state = LidSleepGuardState()
        let (low, _, _) = run(previous: state, input: input(power: power(percent: 29)))
        #expect(low.batteryLatched)
        guard case .blocked(.lowBattery) = low.phase else {
            Issue.record("expected blocked")
            return
        }

        let (mid, _, _) = run(previous: low, input: input(power: power(percent: 34)))
        #expect(mid.batteryLatched)
        guard case .blocked = mid.phase else {
            Issue.record("34 still blocked")
            return
        }

        let (ok, wants, _) = run(previous: mid, input: input(power: power(percent: 35)))
        #expect(!ok.batteryLatched)
        #expect(ok.phase == .armed)
        #expect(wants)

        // latch cleared by AC
        let latched = LidSleepGuardState(batteryLatched: true)
        let (ac, _, _) = run(previous: latched, input: input(power: power(onBattery: false, percent: 10)))
        #expect(!ac.batteryLatched)
        #expect(ac.phase == .armed)
    }

    @Test("V-C02-4 duration: 2:59:59 holding, 3:00:00 blocked+latch; open clears")
    func maxDuration() {
        let closedSince = t0
        var state = LidSleepGuardState(lidClosedSince: closedSince)
        let almost = t0 + 3 * 3600 - 1
        let (holding, wants, _) = run(previous: state, input: input(lid: .closed, now: almost))
        #expect(holding.phase == .holdingLidClosed(sinceUptime: closedSince))
        #expect(wants)
        #expect(!holding.maxDurationLatched)

        let exact = t0 + 3 * 3600
        let (blocked, wants2, _) = run(previous: holding, input: input(lid: .closed, now: exact))
        #expect(blocked.maxDurationLatched)
        #expect(!wants2)
        guard case let .blocked(.maxDuration(limit)) = blocked.phase else {
            Issue.record("expected maxDuration")
            return
        }
        #expect(limit == 3 * 3600)

        let (opened, _, _) = run(previous: blocked, input: input(lid: .open, now: exact + 1))
        #expect(!opened.maxDurationLatched)
        #expect(opened.lidClosedSince == nil)
    }

    @Test("V-C02-4 limitDurationOnAC false + on AC skips duration limit")
    func durationSkippedOnAC() {
        let closedSince = t0
        let state = LidSleepGuardState(lidClosedSince: closedSince)
        let (ok, wants, _) = run(previous: state, input: input(
                settings: settings(limitOnAC: false),
                lid: .closed,
                power: power(onBattery: false, percent: 100),
                now: t0 + 10 * 3600
            ))
        #expect(ok.phase == .holdingLidClosed(sinceUptime: closedSince))
        #expect(wants)
    }

    @Test("W0-2 latched duration stays blocked after AC + limitDurationOnAC=false; only open unlocks")
    func latchedBeatsACExemption() {
        // 電池上達時限
        let closedSince = t0
        var state = LidSleepGuardState(lidClosedSince: closedSince)
        let (blocked, wants, _) = run(
            previous: state,
            input: input(lid: .closed, power: power(onBattery: true, percent: 80), now: t0 + 3 * 3600)
        )
        #expect(blocked.maxDurationLatched)
        #expect(!wants)

        // 接 AC、關閉 AC 時限、仍闔蓋 → 仍 blocked
        let (still, stillWants, _) = run(
            previous: blocked,
            input: input(
                settings: settings(limitOnAC: false),
                lid: .closed,
                power: power(onBattery: false, percent: 100),
                now: t0 + 3 * 3600 + 10
            )
        )
        #expect(still.maxDurationLatched)
        #expect(!stillWants)
        guard case .blocked(.maxDuration) = still.phase else {
            Issue.record("expected maxDuration while latched on AC")
            return
        }

        // busy／mode／option 切換亦不解除
        let (busyOff, _, _) = run(previous: still, input: input(busy: false, lid: .closed, power: power(onBattery: false)))
        #expect(busyOff.maxDurationLatched)
        let (optOff, _, _) = run(
            previous: still,
            input: input(settings: settings(enabled: false, limitOnAC: false), lid: .closed, power: power(onBattery: false))
        )
        #expect(optOff.maxDurationLatched)
        let (agentOff, _, _) = run(
            previous: still,
            input: input(agent: false, lid: .closed, power: power(onBattery: false))
        )
        #expect(agentOff.maxDurationLatched)

        // 只有確認開蓋才解除
        let (opened, openWants, _) = run(
            previous: still,
            input: input(settings: settings(limitOnAC: false), lid: .open, power: power(onBattery: false), now: t0 + 4 * 3600)
        )
        #expect(!opened.maxDurationLatched)
        #expect(opened.phase == .armed)
        #expect(openWants)
    }

    @Test("V-C02-7 mode/option/busy/AC switch does not reset closed-session latch")
    func latchSurvivesModeSwitch() {
        let latched = LidSleepGuardState(
            phase: .blocked(.maxDuration(limitSeconds: 3 * 3600)),
            lidClosedSince: 0,
            maxDurationLatched: true
        )
        let (off, _, _) = run(previous: latched, input: input(settings: settings(enabled: false), lid: .closed))
        #expect(off.maxDurationLatched)
        #expect(off.lidClosedSince == 0)

        let (back, wants, _) = run(previous: off, input: input(lid: .closed, now: t0))
        #expect(back.maxDurationLatched)
        #expect(!wants)
        guard case .blocked(.maxDuration) = back.phase else {
            Issue.record("still latched blocked")
            return
        }

        // W0-10：獨立切 busy／mode／AC
        let (busy, _, _) = run(previous: latched, input: input(busy: false, lid: .closed))
        #expect(busy.maxDurationLatched)
        let (ac, _, _) = run(
            previous: latched,
            input: input(settings: settings(limitOnAC: false), lid: .closed, power: power(onBattery: false))
        )
        #expect(ac.maxDurationLatched)
        #expect(ac.phase == .blocked(.maxDuration(limitSeconds: 3 * 3600)) || {
            if case .blocked(.maxDuration) = ac.phase { return true }
            return false
        }())
    }

    @Test("Fi A3 / §14.2 noLid forbids arm")
    func noLidForbidsArm() {
        let (state, wants, _) = run(input: input(lid: .noLid))
        #expect(state.phase == .blocked(.noLid))
        #expect(!wants)
    }

    @Test("§14.2 unknown lid blocks and does not hold")
    func unknownLidBlocks() {
        let armed = LidSleepGuardState(phase: .armed)
        let (state, wants, events) = run(previous: armed, input: input(lid: .unknown))
        #expect(state.phase == .blocked(.lidUnknown))
        #expect(!wants)
        #expect(events.contains(.released(.lidUnknown)))
    }

    // MARK: Events

    @Test("events: idle→armed emits armed")
    func eventArmed() {
        let idle = LidSleepGuardState(phase: .idle)
        let (_, _, events) = run(previous: idle, input: input())
        #expect(events.contains(.armed))
    }

    @Test("events: holding→idle emits released(nil)")
    func eventReleasedNil() {
        let holding = LidSleepGuardState(phase: .holdingLidClosed(sinceUptime: 0), lidClosedSince: 0)
        let (_, _, events) = run(previous: holding, input: input(busy: false, lid: .closed))
        #expect(events.contains(.released(nil)))
    }

    @Test("events: holding→blocked(thermal) emits released(.thermal)")
    func eventReleasedThermal() {
        let holding = LidSleepGuardState(phase: .holdingLidClosed(sinceUptime: 0), lidClosedSince: 0)
        let (_, _, events) = run(previous: holding, input: input(lid: .closed, power: power(thermal: .serious)))
        #expect(events.contains(.released(.thermal)))
    }

    @Test("events: armed + closed → lidClosedWhileHolding")
    func eventLidClosedWhileHolding() {
        let armed = LidSleepGuardState(phase: .armed)
        let (_, _, events) = run(previous: armed, input: input(lid: .closed))
        #expect(events.contains(.lidClosedWhileHolding))
    }

    @Test("events: idle + closed → lidClosedWhileNotHolding")
    func eventLidClosedWhileNotHolding() {
        let idle = LidSleepGuardState(phase: .idle)
        let (_, _, events) = run(previous: idle, input: input(busy: false, lid: .closed))
        #expect(events.contains(.lidClosedWhileNotHolding))
    }

    // MARK: wantsSleepDisabled exhaustive

    @Test("V-C02-5 / W0-10 wantsSleepDisabled only for armed/holding across phases × inputs")
    func wantsExhaustive() {
        let previousPhases: [LidSleepGuardPhase] = [
            .off,
            .unavailable(.connecting),
            .idle,
            .armed,
            .holdingLidClosed(sinceUptime: 0),
            .blocked(.thermal),
            .blocked(.unknownPower),
            .blocked(.maxDuration(limitSeconds: 3 * 3600)),
        ]
        let inputs: [LidSleepGuardInput] = [
            input(settings: settings(enabled: false)),
            input(agent: false),
            input(helper: .notRegistered),
            input(busy: false),
            input(lid: .open),
            input(lid: .closed),
            input(lid: .noLid),
            input(lid: .unknown),
            input(power: power(thermal: .serious)),
            input(power: power(thermal: .critical)),
            input(power: power(onBattery: nil, percent: 100)),
            input(power: power(percent: 10)),
            input(power: power(onBattery: false, percent: 100)),
        ]
        for previousPhase in previousPhases {
            var previous = LidSleepGuardState(phase: previousPhase)
            if case .holdingLidClosed = previousPhase {
                previous.lidClosedSince = 0
            }
            if case .blocked(.maxDuration) = previousPhase {
                previous.maxDurationLatched = true
                previous.lidClosedSince = 0
            }
            for inp in inputs {
                let (state, wants, _) = run(previous: previous, input: inp)
                let holding: Bool = {
                    switch state.phase {
                    case .armed, .holdingLidClosed: return true
                    default: return false
                    }
                }()
                #expect(wants == holding)
            }
        }
    }

    @Test("W0-10 explicit predicate priority and continuous-clock wake-jump deadline")
    func predicatePriorityAndWakeJump() {
        // 優先序（§5.3／§14.2）：off／agent → pause → helper → busy → thermal → power → duration
        let paused = LidSleepGuardState(userPausedUntil: t0 + 100)
        let (pauseWins, pauseWants, _) = run(
            previous: paused,
            input: input(busy: false, helper: .notRegistered, power: power(percent: 5, thermal: .critical))
        )
        #expect(pauseWins.phase == .blocked(.userPaused(untilUptime: t0 + 100)))
        #expect(!pauseWants)

        let (helperWins, helperWants, _) = run(
            input: input(busy: false, helper: .requiresApproval, power: power(thermal: .critical))
        )
        #expect(helperWins.phase == .unavailable(.requiresApproval))
        #expect(!helperWants)

        let (busyWins, busyWants, _) = run(
            input: input(busy: false, power: power(percent: 5, thermal: .critical))
        )
        #expect(busyWins.phase == .idle)
        #expect(!busyWants)

        let (thermalWins, thermalWants, _) = run(
            input: input(
                lid: .closed,
                power: power(onBattery: nil, percent: nil, thermal: .serious),
                now: t0 + 10 * 3600
            )
        )
        #expect(thermalWins.phase == .blocked(.thermal))
        #expect(!thermalWants)

        let (powerWins, powerWants, _) = run(
            previous: .init(lidClosedSince: t0),
            input: input(
                lid: .closed,
                power: power(onBattery: nil, percent: 100),
                now: t0 + 10 * 3600
            )
        )
        #expect(powerWins.phase == .blocked(.unknownPower))
        #expect(!powerWants)

        // continuous-clock deadline：before / at / after 模擬 wake jump
        let limit = 3 * 3600.0
        let closedSince = t0
        let base = LidSleepGuardState(lidClosedSince: closedSince)

        let beforeNow = closedSince + limit - 1
        let (before, beforeWants, _) = run(
            previous: base,
            input: input(lid: .closed, now: beforeNow)
        )
        #expect(before.phase == .holdingLidClosed(sinceUptime: closedSince))
        #expect(beforeWants)

        let atNow = closedSince + limit
        let (atLimit, atWants, _) = run(
            previous: before,
            input: input(lid: .closed, now: atNow)
        )
        #expect(atLimit.maxDurationLatched)
        #expect(!atWants)
        guard case .blocked(.maxDuration) = atLimit.phase else {
            Issue.record("expected maxDuration at boundary")
            return
        }

        // wake jump：uptime 從 closedSince 附近跳到遠端；latch／since 由呼叫端注入持續
        let afterWake = closedSince + limit + 50_000
        let (after, afterWants, _) = run(
            previous: atLimit,
            input: input(lid: .closed, now: afterWake)
        )
        #expect(after.maxDurationLatched)
        #expect(after.lidClosedSince == closedSince)
        #expect(!afterWants)
        guard case .blocked(.maxDuration) = after.phase else {
            Issue.record("expected still latched after wake jump")
            return
        }
    }

    @Test("W0-10 true→unknown→true latch sequence preserves maxDuration")
    func trueUnknownTrueLatch() {
        let latched = LidSleepGuardState(
            phase: .blocked(.maxDuration(limitSeconds: 3 * 3600)),
            lidClosedSince: 0,
            maxDurationLatched: true
        )
        let (unknown, _, _) = run(previous: latched, input: input(lid: .unknown, now: 10))
        #expect(unknown.maxDurationLatched)
        let (closedAgain, wants, _) = run(previous: unknown, input: input(lid: .closed, now: 20))
        #expect(closedAgain.maxDurationLatched)
        #expect(!wants)
        guard case .blocked(.maxDuration) = closedAgain.phase else {
            Issue.record("expected still latched")
            return
        }
    }

    // MARK: normalized

    @Test("normalized: floor 20→30; 5h clamps to allowed hours")
    func normalized() {
        let raw = LidSleepSettings(
            batteryFloorPercent: 20,
            maxLidClosedSeconds: 5 * 3600
        ).normalized()
        #expect(raw.batteryFloorPercent == 30)
        #expect(LidSleepSettings.allowedMaxHours.contains(raw.maxLidClosedSeconds / 3600))

        let nan = LidSleepSettings(maxLidClosedSeconds: .nan).normalized()
        #expect(nan.maxLidClosedSeconds == 3 * 3600)

        let neg = LidSleepSettings(maxLidClosedSeconds: -1).normalized()
        #expect(neg.maxLidClosedSeconds == 3 * 3600)
    }

    @Test("W0-9 Int.min/Int.max floors and non-finite duration never trap")
    func normalizedExtremeValues() throws {
        let minFloor = LidSleepSettings(batteryFloorPercent: Int.min).normalized()
        #expect(LidSleepSettings.allowedBatteryFloors.contains(minFloor.batteryFloorPercent))
        #expect(minFloor.batteryFloorPercent >= 30)

        let maxFloor = LidSleepSettings(batteryFloorPercent: Int.max).normalized()
        #expect(LidSleepSettings.allowedBatteryFloors.contains(maxFloor.batteryFloorPercent))

        let inf = LidSleepSettings(maxLidClosedSeconds: .infinity).normalized()
        #expect(inf.maxLidClosedSeconds == 3 * 3600)
        let ninf = LidSleepSettings(maxLidClosedSeconds: -.infinity).normalized()
        #expect(ninf.maxLidClosedSeconds == 3 * 3600)

        // NaN 不能進預設 JSONEncoder；用有限非法秒數驗證 Codable 路徑
        let encoded = try JSONEncoder().encode(LidSleepSettings(batteryFloorPercent: Int.min, maxLidClosedSeconds: -1))
        let decoded = try JSONDecoder().decode(LidSleepSettings.self, from: encoded).normalized()
        #expect(decoded.batteryFloorPercent >= 30)
        #expect(LidSleepSettings.allowedMaxHours.contains(decoded.maxLidClosedSeconds / 3600))

        // policy 也不因極端設定陷阱
        let (state, wants, _) = run(input: input(settings: LidSleepSettings(
            enabled: true,
            batteryFloorPercent: Int.min,
            maxLidClosedSeconds: .infinity
        )))
        #expect(state.phase == .armed)
        #expect(wants)
    }

    // MARK: State diagram edges (V-C02-6)

    @Test("edge off→unavailable: enabled+agent+helper≠ready")
    func edgeOffToUnavailable() {
        let (s, _, _) = run(previous: .init(phase: .off), input: input(helper: .requiresApproval))
        #expect(s.phase == .unavailable(.requiresApproval))
    }

    @Test("edge off→idle: enabled+agent+ready+!busy")
    func edgeOffToIdle() {
        let (s, _, _) = run(previous: .init(phase: .off), input: input(busy: false))
        #expect(s.phase == .idle)
    }

    @Test("edge unavailable→idle: helper ready")
    func edgeUnavailableToIdle() {
        let prev = LidSleepGuardState(phase: .unavailable(.connecting))
        let (s, _, _) = run(previous: prev, input: input(busy: false))
        #expect(s.phase == .idle)
    }

    @Test("edge idle→armed: busy + floors OK + lid open")
    func edgeIdleToArmed() {
        let (s, wants, events) = run(previous: .init(phase: .idle), input: input())
        #expect(s.phase == .armed)
        #expect(wants)
        #expect(events.contains(.armed))
    }

    @Test("edge idle→blocked: busy + floor fail")
    func edgeIdleToBlocked() {
        let (s, _, _) = run(previous: .init(phase: .idle), input: input(power: power(percent: 10)))
        guard case .blocked(.lowBattery) = s.phase else {
            Issue.record("expected lowBattery")
            return
        }
    }

    @Test("edge armed→holdingLidClosed: lid closes")
    func edgeArmedToHolding() {
        let (s, _, events) = run(previous: .init(phase: .armed), input: input(lid: .closed))
        #expect(s.phase == .holdingLidClosed(sinceUptime: t0))
        #expect(events.contains(.lidClosedWhileHolding))
    }

    @Test("edge holdingLidClosed→armed: lid opens (clears latch)")
    func edgeHoldingToArmed() {
        let prev = LidSleepGuardState(
            phase: .holdingLidClosed(sinceUptime: 0),
            lidClosedSince: 0,
            maxDurationLatched: true
        )
        let (s, _, _) = run(previous: prev, input: input(lid: .open))
        #expect(s.phase == .armed)
        #expect(s.lidClosedSince == nil)
        #expect(!s.maxDurationLatched)
    }

    @Test("edge armed→idle: sources idle")
    func edgeArmedToIdle() {
        let (s, wants, events) = run(previous: .init(phase: .armed), input: input(busy: false))
        #expect(s.phase == .idle)
        #expect(!wants)
        #expect(events.contains(.released(nil)))
    }

    @Test("edge holding→idle: sources idle")
    func edgeHoldingToIdle() {
        let prev = LidSleepGuardState(phase: .holdingLidClosed(sinceUptime: 0), lidClosedSince: 0)
        let (s, _, events) = run(previous: prev, input: input(busy: false, lid: .closed))
        #expect(s.phase == .idle)
        #expect(events.contains(.released(nil)))
    }

    @Test("edge armed→blocked: battery/thermal/pause")
    func edgeArmedToBlocked() {
        let (s, _, events) = run(previous: .init(phase: .armed), input: input(power: power(thermal: .serious)))
        #expect(s.phase == .blocked(.thermal))
        #expect(events.contains(.released(.thermal)))
    }

    @Test("edge holding→blocked: duration")
    func edgeHoldingToBlockedDuration() {
        let prev = LidSleepGuardState(phase: .holdingLidClosed(sinceUptime: 0), lidClosedSince: 0)
        let (s, _, events) = run(previous: prev, input: input(lid: .closed, now: 0 + 3 * 3600))
        guard case .blocked(.maxDuration) = s.phase else {
            Issue.record("expected maxDuration")
            return
        }
        #expect(events.contains(.released(.maxDuration(limitSeconds: 3 * 3600))))
    }

    @Test("edge blocked→armed: condition recovers (duration needs open first)")
    func edgeBlockedToArmed() {
        // thermal recover
        let thermal = LidSleepGuardState(phase: .blocked(.thermal))
        let (s, wants, events) = run(previous: thermal, input: input(power: power(thermal: .fair)))
        #expect(s.phase == .armed)
        #expect(wants)
        #expect(events.contains(.armed))

        // duration latch needs open
        let dur = LidSleepGuardState(
            phase: .blocked(.maxDuration(limitSeconds: 3 * 3600)),
            lidClosedSince: 0,
            maxDurationLatched: true
        )
        let (still, wants2, _) = run(previous: dur, input: input(lid: .closed, now: t0))
        #expect(still.maxDurationLatched)
        #expect(!wants2)
    }

    @Test("edge blocked→idle: !busy")
    func edgeBlockedToIdle() {
        let (s, _, _) = run(previous: .init(phase: .blocked(.thermal)), input: input(busy: false))
        #expect(s.phase == .idle)
    }

    @Test("edge idle/armed/holding→off: disable option")
    func edgeToOff() {
        for phase: LidSleepGuardPhase in [.idle, .armed, .holdingLidClosed(sinceUptime: 0)] {
            let (s, wants, _) = run(previous: .init(phase: phase), input: input(settings: settings(enabled: false)))
            #expect(s.phase == .off)
            #expect(!wants)
        }
    }
}
