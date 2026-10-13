import ChorusCore
import Foundation
import Testing
@testable import Chorus

@Suite("KeepAwakeWorkStatusFormatter")
struct KeepAwakeWorkStatusFormatterTests {
    private func sample(cpu: Double = 72) -> SystemLoadSample {
        SystemLoadSample(
            sampledAt: 1,
            cpu: .value(cpu),
            gpu: .unsupported,
            network: .value(0)
        )
    }

    private func evaluation(
        phase: SystemLoadPhase,
        shouldHold: Bool,
        signals: Set<SystemLoadSignal> = [.cpu],
        cooldown: Double? = nil
    ) -> SystemLoadEvaluation {
        SystemLoadEvaluation(
            phase: phase,
            shouldHold: shouldHold,
            qualifiedSignals: signals,
            cooldownRemaining: cooldown
        )
    }

    @Test("Agent-only active")
    func agentOnly() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: true,
            agentNames: ["Claude Code", "Orca"],
            load: evaluation(phase: .waiting, shouldHold: false, signals: []),
            sample: sample(),
            isHolding: true,
            idleBlanked: false
        )
        #expect(text == "Claude Code、Orca 工作中 — 螢幕與系統不待機")
    }

    @Test("Agent names are capped at two with 「等 N 個」")
    func agentNamesCapped() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: true,
            agentNames: ["Claude Code", "Orca", "Codex", "Grok"],
            load: evaluation(phase: .waiting, shouldHold: false, signals: []),
            sample: sample(),
            isHolding: true,
            idleBlanked: false
        )
        #expect(text == "Claude Code、Orca 等 2 個 工作中 — 螢幕與系統不待機")
        #expect(!text.contains("Codex"))
        #expect(!text.contains("Grok"))
    }

    @Test("Exactly two agent names are not truncated")
    func twoAgentNamesNotTruncated() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: true,
            agentNames: ["A", "B"],
            load: evaluation(phase: .waiting, shouldHold: false, signals: []),
            sample: sample(),
            isHolding: true,
            idleBlanked: false
        )
        #expect(!text.contains("等"))
    }

    @Test("Load-only active")
    func loadOnly() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: false,
            agentNames: [],
            load: evaluation(phase: .active, shouldHold: true),
            sample: sample(cpu: 72),
            isHolding: true,
            idleBlanked: false
        )
        #expect(text == "CPU 72% 高負載 — 螢幕與系統不待機")
    }

    @Test("Both agent and load active")
    func bothActive() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: true,
            agentNames: ["Claude Code"],
            load: evaluation(phase: .active, shouldHold: true),
            sample: sample(cpu: 72),
            isHolding: true,
            idleBlanked: false
        )
        #expect(text == "Claude Code 工作中＋CPU 72% — 螢幕與系統不待機")
    }

    @Test("Load cooling while agent idle")
    func loadCooling() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: false,
            agentNames: [],
            load: evaluation(phase: .coolingDown, shouldHold: true, signals: [], cooldown: 95),
            sample: sample(cpu: 10),
            isHolding: true,
            idleBlanked: false
        )
        #expect(text.contains("負載降低"))
        #expect(text.contains("95"))
    }

    @Test("Agent grace does not show countdown")
    func agentGraceNoCountdown() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: true,
            agentNames: ["租約"],
            load: evaluation(phase: .waiting, shouldHold: false, signals: []),
            sample: sample(),
            isHolding: true,
            idleBlanked: false
        )
        #expect(text.contains("租約"))
        #expect(!text.contains("秒後"))
    }

    @Test("Idle blank while holding")
    func idleBlank() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: true,
            agentNames: ["Orca"],
            load: evaluation(phase: .waiting, shouldHold: false, signals: []),
            sample: nil,
            isHolding: true,
            idleBlanked: true
        )
        #expect(text == String(localized: "工作中 — 閒置熄屏"))
    }

    @Test("Waiting with no triggers")
    func waiting() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: false,
            agentNames: [],
            load: evaluation(phase: .waiting, shouldHold: false, signals: []),
            sample: sample(),
            isHolding: false,
            idleBlanked: false
        )
        #expect(text.contains("監測中"))
        #expect(text.contains("負載未達門檻"))
    }

    @Test("Qualifying")
    func qualifying() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: false,
            agentNames: [],
            load: evaluation(phase: .qualifying, shouldHold: false),
            sample: sample(),
            isHolding: false,
            idleBlanked: false
        )
        #expect(text.contains("達門檻"))
        #expect(text.contains("確認中"))
    }

    @Test("Unavailable load")
    func unavailable() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: false,
            agentNames: [],
            load: evaluation(phase: .unavailable, shouldHold: false, signals: []),
            sample: SystemLoadSample(
                sampledAt: 1, cpu: .unavailable, gpu: .unsupported, network: .unavailable
            ),
            isHolding: false,
            idleBlanked: false
        )
        #expect(text.contains("負載監測無資料"))
    }

    @Test("GPU unsupported with other signals")
    func gpuUnsupported() {
        let text = KeepAwakeWorkStatusFormatter.caption(
            agentBusy: false,
            agentNames: [],
            load: evaluation(phase: .unavailable, shouldHold: false, signals: []),
            sample: SystemLoadSample(
                sampledAt: 1, cpu: .value(10), gpu: .unsupported, network: .value(0)
            ),
            isHolding: false,
            idleBlanked: false
        )
        #expect(text.contains("GPU 不支援"))
        #expect(text.contains("CPU／網路"))
    }
}
