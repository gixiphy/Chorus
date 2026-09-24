import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("WindowManager 自動排列", .serialized)
struct WindowManagerAutoArrangeTests {
    @Test("兩個視窗自動選左右並排")
    func twoWindowsLeftRight() {
        let fixture = makeFixture(tokens: ["w1", "w2"])
        let expected = WindowArrangement.leftRight.frames(visible: Self.visible, gap: 8)

        fixture.manager.arrangeAuto(source: .shortcut)

        #expect(fixture.fake.setFrameLog.map(\.frame) == expected)
        #expect(fixture.manager.lastReport?.arrangement == .leftRight)
        #expect(fixture.manager.statusMessage?.hasPrefix("自動排列：左右並排。") == true)
    }

    @Test("受最小尺寸限制後，下次改選放得下的版型")
    func learnsFromConstrained() {
        let fixture = makeFixture(tokens: ["w1", "w2"])
        fixture.fake.windows["w1"]?.minSize = LayoutSize(width: 900, height: 0)

        fixture.manager.arrangeAuto(source: .shortcut)
        #expect(fixture.manager.lastReport?.arrangement == .leftRight)
        #expect(fixture.manager.lastReport?.items[0].status == .constrained)

        fixture.manager.arrangeAuto(source: .shortcut)
        #expect(fixture.manager.lastReport?.arrangement != .leftRight)
        #expect(fixture.manager.lastReport?.constrainedCount == 0)
    }

    @Test("單一視窗自動填滿且報告沒有固定版型")
    func singleWindowMaximizes() {
        let fixture = makeFixture(tokens: ["w1"])
        let expected = LayoutEngine().frame(
            for: .maximize,
            visible: Self.visible,
            gap: 8,
            current: fixture.fake.windows["w1"]!.frame
        )

        fixture.manager.arrangeAuto(source: .shortcut)

        #expect(fixture.fake.setFrameLog.map(\.frame) == [expected])
        #expect(fixture.manager.lastReport?.arrangement == nil)
        #expect(fixture.manager.lastReport?.items.count == 1)
    }

    @Test("五個視窗最多只排列四個")
    func fiveWindowsCapAtFour() {
        let fixture = makeFixture(tokens: ["w1", "w2", "w3", "w4", "w5"])

        fixture.manager.arrangeAuto(source: .shortcut)

        #expect(fixture.manager.lastReport?.arrangement == .quarters)
        #expect(fixture.manager.lastReport?.items.count == 4)
        #expect(fixture.fake.setFrameLog.map(\.token) == ["w1", "w2", "w3", "w4"])
    }

    @Test("目標消失會清掉尺寸提示，token 重用後不沿用舊下限")
    func forgetsHintsOnTargetGone() {
        let fixture = makeFixture(tokens: ["w1", "w2"])
        fixture.fake.windows["w1"]?.minSize = LayoutSize(width: 900, height: 0)
        fixture.manager.arrangeAuto(source: .shortcut)

        fixture.fake.onBeforeSetFrame = { token in
            if token == "w1" { fixture.fake.windows["w1"] = nil }
        }
        fixture.manager.arrangeAuto(source: .shortcut)
        #expect(fixture.fake.forgottenTokens.contains("w1"))

        fixture.fake.onBeforeSetFrame = nil
        fixture.fake.windows["w1"] = Self.window(token: "w1", index: 0)
        fixture.manager.arrangeAuto(source: .shortcut)

        #expect(fixture.manager.lastReport?.arrangement == .leftRight)
    }

    @Test("自動排列指令有專用呈現")
    func commandPresentation() {
        #expect(WindowCommand.arrangeAuto.title == "自動排列")
        #expect(WindowCommand.arrangeAuto.symbolName == "wand.and.stars")
        #expect(WindowCommand.arrangeAuto.previewBlocks.isEmpty)
    }

    private func makeFixture(tokens: [String]) -> AutoFixture {
        let windows = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { index, token in
            (token, Self.window(token: token, index: index))
        })
        let fake = FakeWindowBackend(
            windows: windows,
            focusedToken: "w1",
            zOrder: Array(tokens.dropFirst())
        )
        let defaults = UserDefaults(suiteName: "window-auto-\(UUID().uuidString)")!
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
        return AutoFixture(manager: manager, fake: fake)
    }

    private static func window(token: String, index: Int) -> FakeWindowBackend.Window {
        .init(
            ref: WindowRef(
                token: token,
                pid: pid_t(101 + index),
                bundleID: "com.example.\(token)",
                appName: ["Safari", "Finder", "Terminal", "Xcode", "Code"][index]
            ),
            frame: LayoutRect(x: 100 + Double(index * 40), y: 100, width: 700, height: 600)
        )
    }

    private static let visible = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
}

@MainActor
private struct AutoFixture {
    let manager: WindowManager
    let fake: FakeWindowBackend
}
