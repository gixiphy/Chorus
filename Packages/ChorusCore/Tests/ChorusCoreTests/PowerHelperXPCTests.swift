import Foundation
import Testing
@testable import ChorusCore

@Suite("PMSetOutputParser")
struct PowerHelperXPCTests {
    @Test("V-C03-1 SleepDisabled tab-1 → true; space-0 → false")
    func parseFlags() {
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "SleepDisabled\t\t1") == true)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "SleepDisabled 0") == false)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "Foo 1\nSleepDisabled\t\t1\nBar 0") == true)
    }

    @Test("V-C03-1 missing SleepDisabled line in recognizable output → false")
    func missingLine() {
        let sample = """
        System-wide power settings:
         Currently on UPS Power:
         disksleep         10
         displaysleep      10
         sleep             1
        """
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: sample) == false)
    }

    @Test("V-C03-1 empty or garbage → nil")
    func emptyOrGarbage() {
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "") == nil)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "   ") == nil)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "lorem ipsum dolor") == nil)
    }

    @Test("V-C03-1 macOS-style pmset -g sample (research format until R01)")
    func macosSample() {
        // 依調研常見格式；R01／V01 提供實機樣本前使用此假設。
        let sample = """
        System-wide power settings:
         Currently on Battery Power:
         lidwake           1
         hibernatemode     3
         hibernatefile     /var/vm/sleepimage
         ttyskeepawake     1
         disksleep         10
         displaysleep      2
         sleep             1
         SleepDisabled     1
         powernap          1
        """
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: sample) == true)

        let off = sample.replacingOccurrences(of: "SleepDisabled     1", with: "SleepDisabled     0")
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: off) == false)
    }

    @Test("V-C03-7 ChorusPowerHelperXPC has exactly two required methods")
    func protocolSurface() {
        // 編譯期：若多加方法，下方 stub 必須一併更新；執行期用 selector 名稱核對。
        final class Stub: NSObject, ChorusPowerHelperXPC {
            func setSleepDisabled(
                _ enabled: Bool,
                withReply reply: @escaping (Data?, String?) -> Void
            ) {
                reply(nil, nil)
            }
            func status(withReply reply: @escaping (Data) -> Void) {
                reply(Data())
            }
        }
        let selectors = [
            #selector(ChorusPowerHelperXPC.setSleepDisabled(_:withReply:)),
            #selector(ChorusPowerHelperXPC.status(withReply:)),
        ]
        #expect(selectors.count == 2)
        #expect(Stub.conforms(to: ChorusPowerHelperXPC.self))
        _ = Stub()
    }

    @Test("PowerHelperStatus JSON round-trip")
    func statusRoundTrip() throws {
        let status = PowerHelperStatus(
            helperBuild: "136",
            sleepDisabled: true,
            setByHelper: true,
            priorValueWasDisabled: false,
            holderCount: 1,
            callerIsHolder: true,
            otherUsersHolding: false,
            lastForcedOffReason: "watchdog",
            lastChangeAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(PowerHelperStatus.self, from: data)
        #expect(decoded == status)
    }

    @Test("PowerHelperStatus decodes older JSON missing optional fields")
    func statusBackwardCompatible() throws {
        let old = """
        {"protocolVersion":1,"helperBuild":"100","setByHelper":false,"holderCount":0,"callerIsHolder":false,"otherUsersHolding":false,"watchdogSeconds":60}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PowerHelperStatus.self, from: old)
        #expect(decoded.helperBuild == "100")
        #expect(decoded.sleepDisabled == nil)
        #expect(decoded.lastForcedOffReason == nil)
        #expect(decoded.priorValueWasDisabled == nil)
    }

    @Test("PowerHelperConstants requirements match spec verbatim")
    func requirementsVerbatim() {
        #expect(PowerHelperConstants.machServiceName == "com.hermes.Chorus.PowerHelper")
        #expect(PowerHelperConstants.teamID == "2ENEDJHX95")
        #expect(
            PowerHelperConstants.clientRequirement
                == #"identifier "com.hermes.Chorus" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#
        )
        #expect(
            PowerHelperConstants.helperRequirement
                == #"identifier "com.hermes.Chorus.PowerHelper" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#
        )
        #expect(PowerHelperConstants.protocolVersion == 1)
        #expect(PowerHelperConstants.heartbeatInterval == 20)
        #expect(PowerHelperConstants.watchdogTimeout == 60)
    }
}
