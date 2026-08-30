import Testing
@testable import ChorusCore

@Suite("音訊行程歸組")
struct AudioProcessGroupingTests {
    private let apps: [String: AudioProcessGrouping.Kind] = [
        "com.vivaldi.Vivaldi": .regularApp,
        "com.apple.Music": .regularApp,
        "com.spotify.client": .regularApp,
    ]

    @Test("App 自己歸自己")
    func appIsItsOwnRoot() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.apple.Music", appKinds: apps) == "com.apple.Music")
    }

    @Test("helper 依前綴歸主 App")
    func helperRollsUpToParent() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.vivaldi.Vivaldi.helper", appKinds: apps) == "com.vivaldi.Vivaldi")
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.vivaldi.Vivaldi.helper.renderer", appKinds: apps) == "com.vivaldi.Vivaldi")
    }

    @Test("helper 標了 LSUIElement 被系統當成 accessory App 也照樣歸主 App（先找爸媽再認自己）")
    func helperListedAsAppStillRollsUp() {
        var withHelper = apps
        withHelper["com.vivaldi.Vivaldi.helper"] = .accessoryApp
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.vivaldi.Vivaldi.helper", appKinds: withHelper) == "com.vivaldi.Vivaldi")
    }

    @Test("regular App 永遠是自己的 root（Safari 網頁 App 不因前綴被併進 Safari）")
    func regularAppIsNeverRolledUp() {
        let withWebApp: [String: AudioProcessGrouping.Kind] = [
            "com.apple.Safari": .regularApp,
            "com.apple.Safari.WebApp.YouTube": .regularApp,
        ]
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.apple.Safari.WebApp.YouTube", appKinds: withWebApp)
            == "com.apple.Safari.WebApp.YouTube")
    }

    @Test("多個候選取最長的（不會把 helper 歸到短前綴的別家 App）")
    func longestPrefixWins() {
        let nested: [String: AudioProcessGrouping.Kind] = [
            "com.example": .regularApp, "com.example.app": .regularApp,
        ]
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.example.app.helper", appKinds: nested) == "com.example.app")
    }

    @Test("前綴必須落在分段邊界（com.vivaldi.VivaldiX 不是 helper）")
    func prefixMustEndAtComponentBoundary() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.vivaldi.VivaldiSnapshot", appKinds: apps) == nil)
    }

    @Test("daemon 歸不進任何 App → nil")
    func daemonHasNoRoot() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.apple.audio.audiomxd", appKinds: apps) == nil)
    }

    @Test("可列性：一般 App 列、Apple accessory 不列、第三方 accessory 列、其餘不列")
    func listability() {
        #expect(AudioProcessGrouping.isListable(kind: .regularApp, bundleID: "com.apple.Music"))
        #expect(!AudioProcessGrouping.isListable(kind: .accessoryApp, bundleID: "com.apple.controlcenter"))
        #expect(AudioProcessGrouping.isListable(kind: .accessoryApp, bundleID: "com.hegenberg.BetterTouchTool"))
        #expect(!AudioProcessGrouping.isListable(kind: .other, bundleID: "com.apple.audio.audiomxd"))
    }
}
