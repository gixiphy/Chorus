import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// 桌面情境的純邏輯：指紋匹配（Jaccard＋切換規則）與模型序列化。
@Suite("Desk scenarios")
struct DeskScenarioTests {
    private let home = UUID()
    private let office = UUID()

    /// 家＝內建＋AG493；公司＝內建＋VS207。
    private var scenarios: [(id: UUID, signature: Set<String>)] {
        [(home, ["builtin", "ag493"]), (office, ["builtin", "vs207"])]
    }

    @Test("Jaccard 分數")
    func score() {
        #expect(DeskScenarioMatcher.score(["a", "b"], ["a", "b"]) == 1.0)
        #expect(DeskScenarioMatcher.score(["a", "b"], ["a", "c"]) == 1.0 / 3.0)
        #expect(DeskScenarioMatcher.score([], []) == 0)
        #expect(DeskScenarioMatcher.score(["a"], []) == 0)
    }

    @Test("接上家裡螢幕組合 → 從公司情境自動切到家")
    func switchesToExactMatch() {
        let target = DeskScenarioMatcher.autoSwitchTarget(
            current: ["builtin", "ag493"], activeID: office, scenarios: scenarios
        )
        #expect(target == home)
    }

    @Test("已在正確情境 → 不切換")
    func staysWhenActiveIsBest() {
        let target = DeskScenarioMatcher.autoSwitchTarget(
            current: ["builtin", "ag493"], activeID: home, scenarios: scenarios
        )
        #expect(target == nil)
    }

    @Test("只剩內建螢幕（拔掉外接）→ 兩情境並列，維持現狀不抖動")
    func tieKeepsCurrent() {
        let target = DeskScenarioMatcher.autoSwitchTarget(
            current: ["builtin"], activeID: home, scenarios: scenarios
        )
        #expect(target == nil)
    }

    @Test("完全陌生的螢幕組合（分數低於門檻）→ 不切換")
    func unknownSetupStays() {
        let target = DeskScenarioMatcher.autoSwitchTarget(
            current: ["someone-elses-tv"], activeID: home, scenarios: scenarios
        )
        #expect(target == nil)
    }

    @Test("無 active（剛刪除情境）→ 有夠好的匹配就切入")
    func adoptsMatchWhenNoActive() {
        let target = DeskScenarioMatcher.autoSwitchTarget(
            current: ["builtin", "vs207"], activeID: nil, scenarios: scenarios
        )
        #expect(target == office)
    }

    @Test("DeskScenario Codable 往返")
    func codableRoundTrip() throws {
        let scenario = DeskScenario(
            id: UUID(),
            name: "家",
            displayUUIDs: ["builtin", "ag493"],
            positions: ["display:builtin": [0.25, 0.75]],
            photoFilename: "abc.jpg",
            curve: AmbientCurve(),
            displayOffsets: ["builtin": -0.1],
            deviceOffset: 0.05,
            excludedDisplays: ["ag493"]
        )
        let data = try JSONEncoder().encode(scenario)
        let decoded = try JSONDecoder().decode(DeskScenario.self, from: data)
        #expect(decoded == scenario)
    }
}
