import Testing
@testable import ChorusCore

@Suite("虛擬輸出裝置的轉送目標")
struct VirtualOutputTargetTests {
    private func preferred(
        pinned: String? = nil,
        present: Set<String>,
        activeScreen: String? = nil,
        liveScreens: [String] = [],
        anyScreens: [String] = [],
        builtin: String? = "builtin"
    ) -> String? {
        VirtualOutputTarget.preferred(
            pinned: pinned,
            present: present,
            activeScreen: activeScreen,
            liveScreens: liveScreens,
            anyScreens: anyScreens,
            builtin: builtin
        )
    }

    @Test("指定的裝置優先")
    func pinnedWins() {
        #expect(preferred(
            pinned: "hdmi-b",
            present: ["hdmi-a", "hdmi-b", "builtin"],
            activeScreen: "hdmi-a"
        ) == "hdmi-b")
    }

    @Test("指定的裝置不在時往下退，不會讓聲音消失")
    func pinnedMissingFallsBack() {
        #expect(preferred(
            pinned: "hdmi-b",
            present: ["hdmi-a", "builtin"],
            activeScreen: "hdmi-a"
        ) == "hdmi-a")
    }

    @Test("自動模式跟著使用中的螢幕")
    func followsActiveScreen() {
        #expect(preferred(
            present: ["hdmi-a", "hdmi-b", "builtin"],
            activeScreen: "hdmi-b",
            liveScreens: ["hdmi-a", "hdmi-b"]
        ) == "hdmi-b")
    }

    @Test("使用中的螢幕沒有音訊端點 → 其他還亮著的螢幕")
    func fallsBackToOtherLiveScreen() {
        #expect(preferred(
            present: ["hdmi-a", "builtin"],
            activeScreen: nil,
            liveScreens: ["hdmi-a"]
        ) == "hdmi-a")
    }

    @Test("螢幕關掉／拔掉 → 回內建輸出，而不是靜音")
    func fallsBackToBuiltin() {
        #expect(preferred(present: ["builtin"], activeScreen: "hdmi-a", liveScreens: ["hdmi-a"]) == "builtin")
    }

    @Test("螢幕不在清單但音訊端點還在（未被辨識成 DDC 顯示器）")
    func unrecognizedScreenStillUsed() {
        #expect(preferred(
            present: ["hdmi-a", "builtin"],
            anyScreens: ["hdmi-a"]
        ) == "hdmi-a")
    }

    @Test("什麼都沒有就回 nil（呼叫端不寫設定）")
    func noCandidate() {
        #expect(preferred(present: [], builtin: nil) == nil)
    }
}
