import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("WindowManager 多視窗排列", .serialized)
struct WindowManagerArrangeTests {
    @Test("全部視窗成功排列並建立群組")
    func allApplied() {
        let fixture = makeFixture()

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        let report = fixture.manager.lastReport
        #expect(report?.items.map(\.status) == [.applied, .applied, .applied])
        #expect(report?.groupID != nil)
        #expect(fixture.manager.canRestoreGroup)
        #expect(fixture.manager.lastOutcome == .applied)
    }

    @Test("批次中關閉視窗只讓該筆失敗")
    func windowClosedMidBatch() {
        let fixture = makeFixture()
        fixture.fake.onBeforeSetFrame = { token in
            if token == "w2" { fixture.fake.windows["w2"] = nil }
        }

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(fixture.manager.lastReport?.items[1].status == .failed(reason: "目標視窗已關閉"))
        #expect(fixture.manager.lastReport?.items[2].status == .applied)
        #expect(fixture.manager.lastReport?.items.map(\.token) == ["w1", "w2", "w3"])
        #expect(fixture.fake.forgottenTokens.contains("w2"))
        #expect(fixture.manager.canRestoreGroup)
    }

    @Test("批次中撤銷權限後略過剩餘視窗")
    func permissionRevokedMidBatch() {
        let fixture = makeFixture()
        fixture.fake.onBeforeSetFrame = { token in
            if token == "w2" { fixture.fake.permissionRevoked = true }
        }

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(fixture.manager.lastReport?.items[0].status == .applied)
        #expect(fixture.manager.lastReport?.items[1].status == .skipped(.permissionRevoked))
        #expect(fixture.manager.lastReport?.items[2].status == .skipped(.permissionRevoked))
        #expect(fixture.manager.lastOutcome == .permissionRequired)
        #expect(!fixture.manager.lastTrusted)
    }

    @Test("拓樸中途改變後不再寫入")
    func topologyChangedMidBatch() {
        let fixture = makeFixture()
        fixture.fake.onBeforeSetFrame = { token in
            if token == "w1" { fixture.manager.noteScreenParametersChanged() }
        }

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(fixture.manager.lastReport?.items[0].status == .applied)
        #expect(fixture.manager.lastReport?.items[1].status == .skipped(.topologyChanged))
        #expect(fixture.manager.lastReport?.items[2].status == .skipped(.topologyChanged))
        #expect(fixture.fake.setFrameLog.count == 1)
    }

    @Test("超過批次時間預算後略過後續視窗")
    func timeBudgetExceeded() {
        let clock = AdvancingClock(step: 0.5)
        let fixture = makeFixture(now: { clock.next() })

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(fixture.manager.lastReport?.items[0].status == .applied)
        #expect(fixture.manager.lastReport?.items[1].status == .applied)
        #expect(fixture.manager.lastReport?.items[2].status == .skipped(.timeBudget))
    }

    @Test("尺寸受限時記錄實際讀回位置")
    func constrainedRecordsReadBack() {
        let fixture = makeFixture()
        fixture.fake.windows["w2"]?.minSize = .init(width: 900, height: 0)

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(fixture.manager.lastReport?.constrainedCount == 1)
        #expect(fixture.manager.lastOutcome == .constrained)
        #expect(fixture.manager.lastReport?.items[1].after == fixture.fake.windows["w2"]?.frame)
        #expect(fixture.manager.lastReport?.items[1].after?.width == 900)
    }

    @Test("逾時只回復一次；回復失敗保留還原記錄")
    func revertOnce() {
        let reverted = makeFixture()
        reverted.fake.setFrameFailures["w2"] = [.timeout]
        reverted.manager.arrange(.threeColumns, source: .shortcut)

        #expect(reverted.manager.lastReport?.items[1].status == .reverted(reason: ArrangementReport.timeoutReason))
        reverted.fake.focusedToken = "w2"
        reverted.manager.restoreLast(source: .shortcut)
        #expect(reverted.manager.statusMessage == "沒有可還原的位置")

        let failed = makeFixture()
        failed.fake.setFrameFailures["w2"] = [.timeout, .timeout]
        failed.manager.arrange(.threeColumns, source: .shortcut)

        #expect(failed.manager.lastReport?.items[1].status == .revertFailed(reason: ArrangementReport.timeoutReason))
        failed.fake.focusedToken = "w2"
        failed.manager.restoreLast(source: .shortcut)
        #expect(failed.manager.lastOutcome == .restored)
    }

    @Test("視窗少於格數時報告留空")
    func fewerWindowsThanSlots() {
        let fixture = makeFixture(tokens: ["w1", "w2"])

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(fixture.manager.lastReport?.emptySlots == 1)
        #expect(fixture.manager.statusMessage?.contains("留空") == true)
    }

    @Test("切換版型保留第一次排列前的原位")
    func switchingLayoutsKeepsOriginal() {
        let fixture = makeFixture()
        let original = fixture.fake.windows["w1"]?.frame
        let expected = WindowArrangement.threeColumns.frames(visible: Self.visible, gap: 8)[0]

        fixture.manager.arrange(.leftRight, source: .shortcut)
        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(fixture.fake.windows["w1"]?.frame == expected)
        fixture.manager.restoreLast(source: .shortcut)
        #expect(fixture.fake.windows["w1"]?.frame == original)
    }

    @Test("相同 frame 對到同一視窗時依 token 去重")
    func duplicateFrameWindowsDeduped() {
        let fixture = makeFixture(tokens: ["w1", "w2"])
        fixture.fake.zOrder = ["w2", "w2"]

        fixture.manager.arrange(.threeColumns, source: .shortcut)

        #expect(Set(fixture.fake.setFrameLog.map(\.token)).count == fixture.fake.setFrameLog.count)
        #expect(fixture.manager.lastReport?.items.count == 2)
    }

    private func makeFixture(
        tokens: [String] = ["w1", "w2", "w3"],
        now: @escaping () -> TimeInterval = { 100 }
    ) -> Fixture {
        let appNames = ["Safari", "Finder", "Terminal"]
        var windows: [String: FakeWindowBackend.Window] = [:]
        for (index, token) in tokens.enumerated() {
            let ref = WindowRef(
                token: token,
                pid: pid_t(101 + index),
                bundleID: "com.example.\(token)",
                appName: appNames[index]
            )
            windows[token] = .init(
                ref: ref,
                frame: LayoutRect(x: 100 + Double(index * 40), y: 100, width: 700, height: 600)
            )
        }
        let fake = FakeWindowBackend(windows: windows, focusedToken: "w1", zOrder: Array(tokens.dropFirst()))
        let defaults = UserDefaults(suiteName: "window-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.windowArrangementEnabled = true
        settings.windowArrangementGap = 8
        let visible = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
        let manager = WindowManager(
            settings: settings,
            worker: fake,
            captureTopology: { generation in
                ScreenTopology(
                    generation: generation,
                    screens: [
                        .init(
                            displayUUID: "A",
                            displayID: 1,
                            name: "Main",
                            frame: visible,
                            visibleFrame: visible,
                            isLandscape: true
                        )
                    ],
                    primaryHeight: 900
                )
            },
            now: now
        )
        return Fixture(manager: manager, fake: fake)
    }

    private static let visible = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
}

@MainActor
private struct Fixture {
    let manager: WindowManager
    let fake: FakeWindowBackend
}

private final class AdvancingClock: @unchecked Sendable {
    private var value: TimeInterval = 0
    private let step: TimeInterval

    init(step: TimeInterval) {
        self.step = step
    }

    func next() -> TimeInterval {
        value += step
        return value
    }
}
