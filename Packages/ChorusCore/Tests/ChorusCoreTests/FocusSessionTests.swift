import Foundation
import Testing
@testable import ChorusCore

@MainActor
@Suite("限時場景（B7）")
struct FocusSessionTests {
    private func set(_ target: ControlTarget, _ property: ControlProperty, _ value: String) -> ControlRequest {
        ControlRequest(verb: .set, target: target, property: property, value: value)
    }

    private func session(
        snapshot: FocusSnapshot = FocusSnapshot(),
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        duration: TimeInterval = 1_500
    ) -> FocusSession {
        FocusSession(
            sceneName: "工作",
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(duration),
            snapshot: snapshot
        )
    }

    // MARK: - 倒數

    @Test("剩餘秒數：走到 deadline 為止，之後恆為 0 不變負數")
    func remaining() {
        let session = session()
        #expect(FocusPlanner.remainingSeconds(session: session, now: session.startedAt) == 1_500)
        #expect(FocusPlanner.remainingSeconds(
            session: session, now: session.startedAt.addingTimeInterval(900)
        ) == 600)
        #expect(FocusPlanner.remainingSeconds(
            session: session, now: session.deadline.addingTimeInterval(60)
        ) == 0)
    }

    @Test("到期判定含邊界：deadline 那一刻就算到期")
    func expiry() {
        let session = session()
        #expect(!FocusPlanner.isExpired(session: session, now: session.deadline.addingTimeInterval(-1)))
        #expect(FocusPlanner.isExpired(session: session, now: session.deadline))
    }

    // MARK: - 去重與反向

    @Test("同一實體同一屬性只留第一次——那才是套用前的原值")
    func deduplicateKeepsFirst() {
        let requests = [
            set(.displayUUID("A"), .brightness, "50.0000%"),
            set(.displayUUID("B"), .brightness, "60.0000%"),
            // 場景對同一台寫第二次（allDisplays 之後又點名調整），
            // 展開後撞在一起。留第二筆的話還原成的是「第一次套用之後」的值
            set(.displayUUID("A"), .brightness, "30.0000%"),
        ]
        let deduped = FocusPlanner.deduplicated(requests)
        #expect(deduped.count == 2)
        #expect(deduped[0].value == "50.0000%")
        #expect(deduped[1].target == .displayUUID("B"))
    }

    @Test("同一實體的不同屬性各留一筆")
    func deduplicateKeepsDistinctProperties() {
        let requests = [
            set(.deviceUID("X"), .volume, "50.0000%"),
            set(.deviceUID("X"), .mute, "off"),
        ]
        #expect(FocusPlanner.deduplicated(requests).count == 2)
    }

    @Test("還原請求反向執行——自動亮度必須在亮度放回去之後才開回來")
    func restoreIsReversed() {
        // 場景的典型形狀：先關自動亮度，再設固定亮度。
        // 快照順序跟著它，還原就必須是「先亮度、後自動亮度」，
        // 否則自動亮度一開就把剛放回去的亮度覆蓋掉（B4-5 的教訓）
        let snapshot = FocusSnapshot(requests: [
            set(.system, .autoBrightness, "on"),
            set(.displayUUID("A"), .brightness, "70.0000%"),
        ])
        let restore = FocusPlanner.restoreRequests(snapshot)
        #expect(restore.map(\.property) == [.brightness, .autoBrightness])
    }

    @Test("還原請求也會去重（快照沒去重時的第二道防線）")
    func restoreDeduplicates() {
        let snapshot = FocusSnapshot(requests: [
            set(.displayUUID("A"), .brightness, "70.0000%"),
            set(.displayUUID("A"), .brightness, "10.0000%"),
        ])
        let restore = FocusPlanner.restoreRequests(snapshot)
        #expect(restore.count == 1)
        #expect(restore[0].value == "70.0000%")
    }

    // MARK: - 快照的計數

    @Test("可還原項數含防睡眠那一條（它不走 request）")
    func restorableCount() {
        var snapshot = FocusSnapshot(requests: [set(.system, .autoBrightness, "on")])
        #expect(snapshot.restorableCount == 1)
        #expect(!snapshot.isEmpty)

        snapshot.keepAwake = .duration(seconds: 1_800)
        #expect(snapshot.restorableCount == 2)

        let onlyUnrestorable = FocusSnapshot(unrestorable: ["ASUS 的 input"])
        #expect(onlyUnrestorable.isEmpty)
        #expect(onlyUnrestorable.restorableCount == 0)
    }

    // MARK: - 持久化

    @Test("JSON 往返：快照、防睡眠模式與不可還原清單都留得住")
    func roundTrip() throws {
        let original = session(snapshot: FocusSnapshot(
            requests: [set(.deviceUID("X"), .volume, "42.5000%")],
            keepAwake: .whileDisplayConnected(uuid: "A"),
            keepAwakeRemainingSeconds: nil,
            unrestorable: ["ASUS VS207 的 input"]
        ))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FocusSession.self, from: data) == original)
    }

    @Test("舊檔缺 applied 欄位仍解得開——那不是損壞，是舊版寫的")
    func decodesFileMissingLaterFields() throws {
        // 手寫 JSON 而不是編碼一個舊型別：要守的正是「未來加欄位時，
        // 崩潰後接續那條路不會因為讀不懂自己的檔而斷掉」
        let json = """
        {
          "sceneName": "工作",
          "startedAt": 100.0,
          "deadline": 1600.0,
          "snapshot": { "requests": [], "unrestorable": [] }
        }
        """
        let decoded = try JSONDecoder().decode(FocusSession.self, from: Data(json.utf8))
        #expect(decoded.sceneName == "工作")
        #expect(decoded.applied.isEmpty)
        #expect(decoded.snapshot.keepAwake == nil)
    }

    // MARK: - 快照值的往返（收值規則的地雷）

    @Test("快照的值字串解回來與原值逐位元相同（三種值域都是）")
    func snapshotValuesSurviveParsing() throws {
        // 這一條守的是 `snapshotString` 為什麼要分兩條路。走錯路不會報錯，
        // 只會讓還原後的值悄悄不對——最難查的那種壞法
        func roundTrip(_ value: Double, _ kind: ControlValueKind) throws -> ControlValue {
            try ControlValue.parse(ControlValue.snapshotString(value), kind: kind)
        }

        // per-app 增益可以 > 1：寫成裸數字會被收值規則當成百分比讀回 0.02
        #expect(try roundTrip(2.0, .gain) == .absolute(2.0))
        #expect(try roundTrip(4.0, .gain) == .absolute(4.0))
        // 0–1 走小數，不付除以 100 的浮點誤差
        #expect(try roundTrip(0.437, .unitInterval) == .absolute(0.437))
        #expect(try roundTrip(0.437, .gain) == .absolute(0.437))
        // signedUnit 的前導負號是絕對值的一部分（allowsRelative: false），
        // 不會被讀成「再減一點」
        #expect(try roundTrip(-0.2, .signedUnit) == .absolute(-0.2))
        // 兩條路的交界：1 在兩種讀法下同值
        #expect(try roundTrip(1.0, .unitInterval) == .absolute(1.0))
        #expect(try roundTrip(0.0, .unitInterval) == .absolute(0.0))
    }
}

@Suite("限時場景的動詞層（B7-2）")
struct FocusVerbLayerTests {
    private func runScene(_ name: String, duration: String?) -> ControlRequest {
        ControlRequest(verb: .perform, target: .system, value: name,
                       action: .runScene, duration: duration)
    }

    @Test("時長解析成秒：25m／1h／90s／裸數字")
    func parsesDuration() throws {
        #expect(try ControlRequestValidator.validate(runScene("工作", duration: "25m"))
            .durationSeconds == 1_500)
        #expect(try ControlRequestValidator.validate(runScene("工作", duration: "1h"))
            .durationSeconds == 3_600)
        #expect(try ControlRequestValidator.validate(runScene("工作", duration: "90s"))
            .durationSeconds == 90)
        #expect(try ControlRequestValidator.validate(runScene("工作", duration: "600"))
            .durationSeconds == 600)
    }

    @Test("沒帶時長＝一般場景，套用後不會自動還原")
    func noDurationIsPlainScene() throws {
        #expect(try ControlRequestValidator.validate(runScene("工作", duration: nil))
            .durationSeconds == nil)
    }

    @Test("off／forever／0 都不是限時場景——要一個會到期的時刻")
    func rejectsNonExpiringDurations() {
        for raw in ["off", "forever", "0", "∞", "無限期"] {
            #expect(throws: ControlError.self) {
                try ControlRequestValidator.validate(runScene("工作", duration: raw))
            }
        }
    }

    @Test("看不懂的時長報錯，不當成沒帶")
    func rejectsGarbage() {
        #expect(throws: ControlError.self) {
            try ControlRequestValidator.validate(runScene("工作", duration: "下午"))
        }
    }

    @Test("時長只配 perform runScene——帶錯地方一律報錯而不是靜靜忽略")
    func durationOnlyOnRunScene() {
        // 使用者以為設了 25 分鐘、實際上沒有，是最糟的失敗形狀
        #expect(throws: ControlError.self) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .set, target: .allDisplays, property: .brightness,
                value: "50%", duration: "25m"
            ))
        }
        #expect(throws: ControlError.self) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .perform, target: .system, action: .restoreAllPower, duration: "25m"
            ))
        }
    }

    @Test("endScene 是合法動作，不需要引數")
    func endSceneValidates() throws {
        let validated = try ControlRequestValidator.validate(
            ControlRequest(verb: .perform, target: .system, action: .endScene)
        )
        #expect(validated.action == .endScene)
        #expect(validated.durationSeconds == nil)
    }

    @Test("JSON 往返含時長；舊 client 沒有這個欄位仍解得開（wire 相容）")
    func codableRoundTrip() throws {
        let original = runScene("工作", duration: "25m")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == original)

        let legacy = """
        {"verb":"perform","target":"system","action":"runScene","value":"工作"}
        """
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(legacy.utf8))
        #expect(decoded.duration == nil)
        #expect(try ControlRequestValidator.validate(decoded).durationSeconds == nil)
    }
}

@Suite("限時場景結束後要不要通知（B7-3）")
struct FocusNotificationRuleTests {
    @Test("只有「使用者可能不在看」的兩種值得通知")
    func onlyUnattendedEndsNotify() {
        #expect(FocusEndReason.elapsed.deservesNotification)
        #expect(FocusEndReason.relaunch.deservesNotification)
        // 手動與被取代是使用者當下的動作，選單上立刻看得到；
        // 結束 Chorus 更不必——App 正在關
        #expect(!FocusEndReason.manual.deservesNotification)
        #expect(!FocusEndReason.replaced.deservesNotification)
        #expect(!FocusEndReason.quit.deservesNotification)
    }
}
