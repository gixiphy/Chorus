import Testing
@testable import ChorusCore

@Suite("ChromiumThrottlePolicy")
struct ChromiumThrottleTests {
    @Test("Recognizes Chrome / Chromium mains and rejects helpers")
    func browserMain() {
        #expect(ChromiumThrottlePolicy.isBrowserMain(arguments: [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]))
        #expect(ChromiumThrottlePolicy.isBrowserMain(arguments: [
            "/Applications/Chromium.app/Contents/MacOS/Chromium", "--foo",
        ]))
        #expect(!ChromiumThrottlePolicy.isBrowserMain(arguments: [
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        ]))
        #expect(!ChromiumThrottlePolicy.isBrowserMain(arguments: []))
    }

    @Test("Requires both anti-throttle flags")
    func bothFlags() {
        let exe = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        #expect(!ChromiumThrottlePolicy.hasAntiThrottleFlags(arguments: [exe]))
        #expect(!ChromiumThrottlePolicy.hasAntiThrottleFlags(arguments: [
            exe, "--disable-backgrounding-occluded-windows",
        ]))
        #expect(ChromiumThrottlePolicy.hasAntiThrottleFlags(arguments: [
            exe,
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
        ]))
    }

    @Test("Warns only when a main is running without a protected instance")
    func shouldWarn() {
        let exe = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let helper = "/…/Google Chrome Helper"
        #expect(!ChromiumThrottlePolicy.shouldWarn(processArgumentLists: []))
        #expect(!ChromiumThrottlePolicy.shouldWarn(processArgumentLists: [[helper]]))
        #expect(ChromiumThrottlePolicy.shouldWarn(processArgumentLists: [[exe]]))
        #expect(!ChromiumThrottlePolicy.shouldWarn(processArgumentLists: [[
            exe,
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
        ]]))
        // 有一台帶齊 flag 就不警告
        #expect(!ChromiumThrottlePolicy.shouldWarn(processArgumentLists: [
            [exe],
            [exe, "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"],
        ]))
    }

    @Test("p_comm filter matches the 16-char Chrome name and not helpers")
    func commFilter() {
        #expect(ChromiumThrottlePolicy.isPossibleBrowserComm("Google Chrome"))
        #expect(ChromiumThrottlePolicy.isPossibleBrowserComm("Chromium"))
        #expect(!ChromiumThrottlePolicy.isPossibleBrowserComm("Google Chrome He"))
        #expect(!ChromiumThrottlePolicy.isPossibleBrowserComm("Safari"))
    }
}
