import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("WindowManager 還原", .serialized)
struct WindowManagerRestoreTests {
    @Test("成功還原後才消耗記錄")
    func restoreConsumesAfterSuccess() {
        let original = LayoutRect(x: 240, y: 160, width: 800, height: 600)
        let fake = makeFake(frame: original)
        let manager = makeManager(fake: fake)

        manager.apply(.leftHalf, source: .shortcut)
        #expect(fake.windows["w1"]?.frame != original)

        manager.restoreLast(source: .shortcut)

        #expect(fake.windows["w1"]?.frame == original)
        #expect(manager.lastOutcome == .restored)
        #expect(!manager.canRestoreTarget)
    }

    @Test("還原失敗保留記錄供重試")
    func failedRestoreKeepsEntry() {
        let original = LayoutRect(x: 240, y: 160, width: 800, height: 600)
        let fake = makeFake(frame: original)
        let manager = makeManager(fake: fake)
        manager.apply(.leftHalf, source: .shortcut)
        fake.setFrameFailures["w1"] = [.timeout]

        manager.restoreLast(source: .shortcut)

        #expect(manager.statusMessage == "操作逾時")
        #expect(fake.windows["w1"]?.frame != original)

        manager.restoreLast(source: .shortcut)

        #expect(fake.windows["w1"]?.frame == original)
        #expect(manager.lastOutcome == .restored)
    }

    @Test("原螢幕移除時把還原位置夾進目前螢幕")
    func restoreClampsWhenScreenMissing() {
        let original = LayoutRect(x: 1_850, y: 650, width: 700, height: 500)
        let fake = makeFake(frame: original)
        let topology = TopologyBox(Self.dualScreenTopology())
        let manager = makeManager(fake: fake, topology: topology)
        manager.apply(.leftHalf, source: .shortcut)
        topology.value = Self.mainScreenTopology()

        manager.restoreLast(source: .shortcut)

        let expected = LayoutRect(x: 900, y: 400, width: 700, height: 500)
        #expect(fake.windows["w1"]?.frame == expected)
        #expect(manager.lastOutcome == .restored)
        #expect(manager.statusMessage == "原螢幕已移除，已放到目前螢幕")
    }

    @Test("整組還原所有成員並產出報告")
    func restoreGroupAll() {
        let (fake, originals) = makeGroupFake()
        let manager = makeManager(fake: fake)
        manager.arrange(.threeColumns, source: .shortcut)

        manager.restoreGroup(source: .shortcut)

        #expect(fake.windows["w1"]?.frame == originals["w1"])
        #expect(fake.windows["w2"]?.frame == originals["w2"])
        #expect(fake.windows["w3"]?.frame == originals["w3"])
        #expect(manager.lastReport?.arrangement == nil)
        #expect(manager.lastReport?.slotCount == 3)
        #expect(manager.lastReport?.items.map(\.status) == [.applied, .applied, .applied])
        #expect(manager.lastOutcome == .restored)
        #expect(!manager.canRestoreGroup)
    }

    @Test("使用者移動的群組成員略過並失效")
    func userMovedMemberSkipped() {
        let (fake, originals) = makeGroupFake()
        let manager = makeManager(fake: fake)
        manager.arrange(.threeColumns, source: .shortcut)
        fake.windows["w2"]?.frame.x += 30
        let moved = fake.windows["w2"]?.frame

        manager.restoreGroup(source: .shortcut)

        #expect(fake.windows["w1"]?.frame == originals["w1"])
        #expect(fake.windows["w2"]?.frame == moved)
        #expect(fake.windows["w3"]?.frame == originals["w3"])
        #expect(manager.lastReport?.items.first(where: { $0.token == "w2" })?.status
            == .failed(reason: "已被移動，略過"))
        #expect(manager.lastOutcome == .partial)
        #expect(manager.statusMessage?.contains("已還原") != true)

        fake.focusedToken = "w2"
        manager.restoreLast(source: .shortcut)
        #expect(manager.statusMessage == "沒有可還原的位置")
    }

    @Test("整組部分還原失敗時保留失敗成員")
    func partialGroupRestoreKeepsFailedEntry() {
        let (fake, originals) = makeGroupFake()
        let manager = makeManager(fake: fake)
        manager.arrange(.threeColumns, source: .shortcut)
        fake.setFrameFailures["w2"] = [.unsupported]

        manager.restoreGroup(source: .shortcut)

        #expect(manager.lastReport?.items.first(where: { $0.token == "w2" })?.status
            == .failed(reason: "unsupported"))
        #expect(manager.lastOutcome == .partial)
        #expect(manager.statusMessage?.contains("已還原") != true)

        fake.focusedToken = "w2"
        manager.restoreLast(source: .shortcut)
        #expect(fake.windows["w2"]?.frame == originals["w2"])
        #expect(manager.lastOutcome == .restored)
    }

    @Test("單窗還原後群組保留其餘成員")
    func singleRestoreLeavesGroup() {
        let (fake, originals) = makeGroupFake()
        let manager = makeManager(fake: fake)
        manager.arrange(.threeColumns, source: .shortcut)

        manager.restoreLast(source: .shortcut)

        #expect(fake.windows["w1"]?.frame == originals["w1"])
        #expect(manager.canRestoreGroup)
        fake.focusedToken = "w2"
        manager.restoreGroup(source: .shortcut)
        #expect(fake.windows["w2"]?.frame == originals["w2"])
        #expect(fake.windows["w3"]?.frame == originals["w3"])
    }

    @Test("已關閉成員從群組移除且不算還原失敗")
    func closedMemberDropped() {
        let (fake, originals) = makeGroupFake()
        let manager = makeManager(fake: fake)
        manager.arrange(.threeColumns, source: .shortcut)
        fake.windows["w2"] = nil

        manager.restoreGroup(source: .shortcut)

        #expect(fake.windows["w1"]?.frame == originals["w1"])
        #expect(fake.windows["w3"]?.frame == originals["w3"])
        #expect(fake.forgottenTokens.contains("w2"))
        #expect(manager.lastReport?.slotCount == 3)
        #expect(manager.lastReport?.items.map(\.token) == ["w1", "w3"])
        #expect(manager.lastOutcome == .restored)
    }

    @Test("重用舊 token 的新視窗絕不套用舊原位")
    func reusedTokenNeverRestored() {
        let (fake, _) = makeGroupFake()
        let manager = makeManager(fake: fake)
        manager.arrange(.threeColumns, source: .shortcut)
        let reusedFrame = LayoutRect(x: 900, y: 700, width: 500, height: 180)
        let ref = fake.windows["w2"]!.ref
        fake.windows["w2"] = .init(ref: ref, frame: reusedFrame)
        let writesBeforeRestore = fake.setFrameLog.filter { $0.token == "w2" }.count

        manager.restoreGroup(source: .shortcut)

        #expect(fake.windows["w2"]?.frame == reusedFrame)
        #expect(fake.setFrameLog.filter { $0.token == "w2" }.count == writesBeforeRestore)
        #expect(manager.lastReport?.items.first(where: { $0.token == "w2" })?.status
            == .failed(reason: "已被移動，略過"))
        fake.focusedToken = "w2"
        manager.restoreLast(source: .shortcut)
        #expect(manager.statusMessage == "沒有可還原的位置")
    }

    @Test("整組還原不會重複寫入相同 token")
    func restoreGroupNoDuplicateWrites() {
        let (fake, _) = makeGroupFake()
        fake.zOrder = ["w2", "w2"]
        let manager = makeManager(fake: fake)
        manager.arrange(.threeColumns, source: .shortcut)
        let writesBeforeRestore = fake.setFrameLog.count

        manager.restoreGroup(source: .shortcut)

        let restoredTokens = fake.setFrameLog.dropFirst(writesBeforeRestore).map(\.token)
        #expect(restoredTokens == ["w1", "w2"])
        #expect(Set(restoredTokens).count == restoredTokens.count)
    }

    private func makeFake(frame: LayoutRect) -> FakeWindowBackend {
        let ref = WindowRef(token: "w1", pid: 101, bundleID: "com.example.test", appName: "Test")
        return FakeWindowBackend(
            windows: ["w1": .init(ref: ref, frame: frame)],
            focusedToken: "w1",
            zOrder: ["w1"]
        )
    }

    private func makeGroupFake() -> (FakeWindowBackend, [String: LayoutRect]) {
        let originals = [
            "w1": LayoutRect(x: 100, y: 100, width: 700, height: 600),
            "w2": LayoutRect(x: 180, y: 140, width: 680, height: 560),
            "w3": LayoutRect(x: 260, y: 180, width: 660, height: 520),
        ]
        var windows: [String: FakeWindowBackend.Window] = [:]
        for (index, token) in ["w1", "w2", "w3"].enumerated() {
            windows[token] = .init(
                ref: WindowRef(
                    token: token,
                    pid: pid_t(101 + index),
                    bundleID: "com.example.\(token)",
                    appName: ["Safari", "Finder", "Terminal"][index]
                ),
                frame: originals[token]!
            )
        }
        return (
            FakeWindowBackend(windows: windows, focusedToken: "w1", zOrder: ["w2", "w3"]),
            originals
        )
    }

    private func makeManager(
        fake: FakeWindowBackend,
        topology: TopologyBox = TopologyBox(Self.mainScreenTopology())
    ) -> WindowManager {
        let defaults = UserDefaults(suiteName: "window-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.windowArrangementEnabled = true
        return WindowManager(
            settings: settings,
            worker: fake,
            captureTopology: { generation in
                var captured = topology.value
                captured.generation = generation
                return captured
            },
            now: { 100 }
        )
    }

    private static func mainScreenTopology() -> ScreenTopology {
        let frame = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
        return ScreenTopology(
            generation: 0,
            screens: [
                .init(
                    displayUUID: "A",
                    displayID: 1,
                    name: "Main",
                    frame: frame,
                    visibleFrame: frame,
                    isLandscape: true
                )
            ],
            primaryHeight: 900
        )
    }

    private static func dualScreenTopology() -> ScreenTopology {
        let main = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
        let secondary = LayoutRect(x: 1_600, y: 0, width: 1_200, height: 900)
        return ScreenTopology(
            generation: 0,
            screens: [
                .init(
                    displayUUID: "A",
                    displayID: 1,
                    name: "Main",
                    frame: main,
                    visibleFrame: main,
                    isLandscape: true
                ),
                .init(
                    displayUUID: "B",
                    displayID: 2,
                    name: "Secondary",
                    frame: secondary,
                    visibleFrame: secondary,
                    isLandscape: true
                )
            ],
            primaryHeight: 900
        )
    }
}

private final class TopologyBox: @unchecked Sendable {
    var value: ScreenTopology

    init(_ value: ScreenTopology) {
        self.value = value
    }
}
