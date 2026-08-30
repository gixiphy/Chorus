import Testing
@testable import ChorusCore

@Suite("音訊行程歸組")
struct AudioProcessGroupingTests {
    private let apps: Set<String> = [
        "com.vivaldi.Vivaldi", "com.apple.Music", "com.spotify.client",
    ]

    @Test("App 自己歸自己")
    func appIsItsOwnRoot() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.apple.Music", appBundleIDs: apps) == "com.apple.Music")
    }

    @Test("helper 依前綴歸主 App")
    func helperRollsUpToParent() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.vivaldi.Vivaldi.helper", appBundleIDs: apps) == "com.vivaldi.Vivaldi")
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.vivaldi.Vivaldi.helper.renderer", appBundleIDs: apps) == "com.vivaldi.Vivaldi")
    }

    @Test("多個候選取最長的（不會把 helper 歸到短前綴的別家 App）")
    func longestPrefixWins() {
        let nested: Set<String> = ["com.example", "com.example.app"]
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.example.app.helper", appBundleIDs: nested) == "com.example.app")
    }

    @Test("前綴必須落在分段邊界（com.vivaldi.VivaldiX 不是 helper）")
    func prefixMustEndAtComponentBoundary() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.vivaldi.VivaldiSnapshot", appBundleIDs: apps) == nil)
    }

    @Test("daemon 歸不進任何 App → nil")
    func daemonHasNoRoot() {
        #expect(AudioProcessGrouping.rootBundleID(
            for: "com.apple.audio.audiomxd", appBundleIDs: apps) == nil)
    }

    @Test("可列性：一般 App 列、Apple accessory 不列、第三方 accessory 列、其餘不列")
    func listability() {
        #expect(AudioProcessGrouping.isListable(kind: .regularApp, bundleID: "com.apple.Music"))
        #expect(!AudioProcessGrouping.isListable(kind: .accessoryApp, bundleID: "com.apple.controlcenter"))
        #expect(AudioProcessGrouping.isListable(kind: .accessoryApp, bundleID: "com.hegenberg.BetterTouchTool"))
        #expect(!AudioProcessGrouping.isListable(kind: .other, bundleID: "com.apple.audio.audiomxd"))
    }
}
