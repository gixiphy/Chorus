import AppKit
import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("WindowManager 排列預覽", .serialized)
struct WindowManagerPreviewTests {
    @Test("快照依序填入格子，目標不重複且不足處留空")
    func previewSlotsFromSnapshot() {
        let fixture = makeFixture()
        fixture.fake.snapshot = [
            .init(pid: fixture.targetPID, bundleID: "com.example.safari", appName: "Safari", frame: Self.targetFrame),
            .init(pid: 202, bundleID: "com.example.finder", appName: "Finder", frame: Self.otherFrame),
        ]
        fixture.manager.captureMenuTarget()

        let preview = fixture.manager.previewArrangement(for: .arrangeThreeColumns)

        #expect(preview?.arrangement == .threeColumns)
        #expect(preview?.displayUUID == "A")
        #expect(preview?.slots.map(\.frame) == WindowArrangement.threeColumns.frames(visible: Self.visible, gap: 8))
        #expect(preview?.slots.map(\.appName) == ["Safari", "Finder", nil])
        #expect(preview?.slots.map(\.isPrimary) == [true, false, false])

        fixture.manager.showArrangementPreview(for: .arrangeThreeColumns)
        #expect(fixture.manager.arrangementPreview?.arrangement == preview?.arrangement)
        #expect(fixture.manager.arrangementPreview?.slots == preview?.slots)
        #expect(fixture.manager.arrangementPreview?.topologyGeneration == 3)
        fixture.manager.hideArrangementPreview()
        #expect(fixture.manager.arrangementPreview == nil)
    }

    @Test("預覽只讀 CG 快照，不列舉或讀取 AX 視窗")
    func previewIsCGOnly() {
        let fixture = makeFixture()
        fixture.fake.snapshot = [
            .init(pid: 202, bundleID: "com.example.finder", appName: "Finder", frame: Self.otherFrame),
        ]
        fixture.manager.captureMenuTarget()
        let frontToBackBefore = fixture.fake.frontToBackCalls
        let getFrameBefore = fixture.fake.getFrameCalls

        _ = fixture.manager.previewArrangement(for: .arrangeLeftRight)

        #expect(fixture.fake.frontToBackCalls == frontToBackBefore)
        #expect(fixture.fake.getFrameCalls == getFrameBefore)
    }

    @Test("預覽帶有建立時的拓樸世代")
    func previewCarriesGeneration() {
        let fixture = makeFixture()
        fixture.manager.captureMenuTarget()

        let preview = fixture.manager.previewArrangement(for: .arrangeLeftRight)

        #expect(preview?.topologyGeneration == 2)
    }

    @Test("沒有選單目標時不建立預覽")
    func noTargetNoPreview() {
        let fixture = makeFixture()

        #expect(fixture.manager.previewArrangement(for: .arrangeLeftRight) == nil)
        fixture.manager.showArrangementPreview(for: .arrangeLeftRight)
        #expect(fixture.manager.arrangementPreview == nil)
    }

    @Test("自動排列以其他視窗未知尺寸交給 planner 選版型")
    func autoPreviewUsesPlanner() {
        let fixture = makeFixture()
        fixture.fake.snapshot = [
            .init(pid: 202, bundleID: "com.example.finder", appName: "Finder", frame: Self.otherFrame),
        ]
        fixture.manager.captureMenuTarget()

        let preview = fixture.manager.previewArrangement(for: .arrangeAuto)

        #expect(preview?.arrangement == .leftRight)
        #expect(preview?.slots.map(\.appName) == ["Safari", "Finder"])
        #expect(fixture.fake.frontToBackCalls == 0)
    }

    private func makeFixture() -> PreviewFixture {
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? pid_t(101)
        let target = FakeWindowBackend.Window(
            ref: WindowRef(
                token: "w1",
                pid: targetPID,
                bundleID: "com.example.safari",
                appName: "Safari"
            ),
            frame: Self.targetFrame
        )
        let fake = FakeWindowBackend(windows: ["w1": target], focusedToken: "w1")
        let defaults = UserDefaults(suiteName: "window-preview-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.windowArrangementEnabled = true
        settings.windowArrangementGap = 8
        let visible = Self.visible
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
            now: { 100 }
        )
        return PreviewFixture(manager: manager, fake: fake, targetPID: targetPID)
    }

    private static let visible = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
    private static let targetFrame = LayoutRect(x: 100, y: 100, width: 700, height: 600)
    private static let otherFrame = LayoutRect(x: 850, y: 100, width: 650, height: 600)
}

@MainActor
private struct PreviewFixture {
    let manager: WindowManager
    let fake: FakeWindowBackend
    let targetPID: pid_t
}
