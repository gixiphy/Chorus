import Foundation
import Security
import Testing
@testable import ChorusCore

@Suite("PMSetOutputParser")
struct PowerHelperXPCTests {
    @Test("V-C03-1 SleepDisabled tab-1 → true; space-0 → false")
    func parseFlags() {
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "SleepDisabled\t\t1") == true)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "SleepDisabled 0") == false)
        // 精簡文法：全部列必須是合法已知設定；夾雜未知列 → nil
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "disksleep 10\nSleepDisabled\t\t1") == true)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "Foo 1\nSleepDisabled\t\t1\nBar 0") == nil)
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

    @Test("W0-6 truncation / malformed / contradictory → nil")
    func ambiguousRejected() {
        // 僅標頭：截斷
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "System-wide power settings:") == nil)
        // 部分／畸形列
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: """
        System-wide power settings:
         SleepDisabled
        """) == nil)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "SleepDisabled garbage 1") == nil)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "SleepDisabled 1 extra") == nil)
        // 衝突重複
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: """
        System-wide power settings:
         disksleep 10
         SleepDisabled 1
         SleepDisabled 0
        """) == nil)
        // 含關鍵字的垃圾（非整行標頭）
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "Currently on something SleepDisabled maybe") == nil)
        // 缺值／缺 SleepDisabled 結構列
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: """
        System-wide power settings:
        disksleep 10
        SleepDisabled
        """) == nil)
        // W0-6 精確回歸樣本（不得授權為 false）
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "System-wide power settings:\ndisksleep garbage") == nil)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "garbage Currently on blah\ndisksleep 10") == nil)
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: "disksleep 10\nsleep garbage") == nil)
        // 完整且無旗標仍為 false
        let completeAbsent = """
        System-wide power settings:
         Currently on Battery Power:
         disksleep         10
         displaysleep      2
         sleep             1
        """
        #expect(PMSetOutputParser.sleepDisabled(fromPMSetG: completeAbsent) == false)
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

    @Test("V-C03-7 / W0-10 ChorusPowerHelperXPC enumerates exactly two required methods")
    func protocolSurface() {
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
        #expect(Stub.conforms(to: ChorusPowerHelperXPC.self))
        _ = Stub()

        var methodCount: UInt32 = 0
        let required = protocol_copyMethodDescriptionList(
            ChorusPowerHelperXPC.self,
            true,  // isRequired
            true,  // isInstanceMethod
            &methodCount
        )
        defer { free(required) }
        #expect(methodCount == 2)

        var optionalCount: UInt32 = 0
        let optionalMethods = protocol_copyMethodDescriptionList(
            ChorusPowerHelperXPC.self,
            false,
            true,
            &optionalCount
        )
        defer { free(optionalMethods) }
        #expect(optionalCount == 0)

        var classRequired: UInt32 = 0
        let classMethods = protocol_copyMethodDescriptionList(
            ChorusPowerHelperXPC.self,
            true,
            false,
            &classRequired
        )
        defer { free(classMethods) }
        #expect(classRequired == 0)

        // W0-10：optional class methods 也必須為 0（避免漏列 class 選擇子）
        var optionalClassCount: UInt32 = 0
        let optionalClassMethods = protocol_copyMethodDescriptionList(
            ChorusPowerHelperXPC.self,
            false,
            false,
            &optionalClassCount
        )
        defer { free(optionalClassMethods) }
        #expect(optionalClassCount == 0)

        let names = (0..<Int(methodCount)).compactMap { idx -> String? in
            guard let list = required, let sel = list[idx].name else { return nil }
            return NSStringFromSelector(sel)
        }.sorted()
        #expect(names == [
            "setSleepDisabled:withReply:",
            "statusWithReply:",
        ])
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

    @Test("W0-5 Release/Debug requirement selection and SecRequirement syntax")
    func requirementsReleaseDebug() {
        #expect(PowerHelperConstants.machServiceName == "com.hermes.Chorus.PowerHelper")
        #expect(PowerHelperConstants.teamID == "2ENEDJHX95")
        #expect(PowerHelperConstants.clientRequirement == PowerHelperConstants.debugClientRequirement)
        #expect(PowerHelperConstants.helperRequirement == PowerHelperConstants.debugHelperRequirement)

        #expect(PowerHelperConstants.clientRequirement(forRelease: false) == PowerHelperConstants.debugClientRequirement)
        #expect(PowerHelperConstants.clientRequirement(forRelease: true) == PowerHelperConstants.releaseClientRequirement)
        #expect(PowerHelperConstants.helperRequirement(forRelease: true) == PowerHelperConstants.releaseHelperRequirement)

        #expect(PowerHelperConstants.validateRequirementSyntax(PowerHelperConstants.debugClientRequirement))
        #expect(PowerHelperConstants.validateRequirementSyntax(PowerHelperConstants.releaseClientRequirement))
        #expect(PowerHelperConstants.validateRequirementSyntax(PowerHelperConstants.releaseHelperRequirement))

        // Release 合約必須含 Developer ID OID 與排除 get-task-allow
        #expect(PowerHelperConstants.releaseClientRequirement.contains("1.2.840.113635.100.6.1.13"))
        #expect(PowerHelperConstants.releaseClientRequirement.contains("get-task-allow"))
        #expect(PowerHelperConstants.releaseClientRequirement.contains("!"))

        // Debug 不要求 Developer ID OID（允許 Apple Development）
        #expect(!PowerHelperConstants.debugClientRequirement.contains("1.2.840.113635.100.6.1.13"))
        #expect(!PowerHelperConstants.debugClientRequirement.contains("get-task-allow"))

        // Release requirement 字串合約（非簽章執行）
        let releaseAcceptsDeveloperID = PowerHelperConstants.releaseClientRequirement
        #expect(releaseAcceptsDeveloperID.contains("2ENEDJHX95"))
        #expect(releaseAcceptsDeveloperID.contains(#"identifier "com.hermes.Chorus""#))
    }

    @Test("W0-10 PENDING: signed-client matrix (no SecStaticCodeCheckValidity; no signing performed)")
    func signedClientMatrixPending() {
        // PENDING — 未執行任何 codesign／SecStaticCodeCheckValidity。
        // Developer ID 接受、Apple Development 拒絕、get-task-allow 拒絕仍 UNCONFIRMED。
        // 需核准的簽章 fixture 或 C05／V01 授權後才可升級為執行驗證；本測試只鎖定字串合約存在。
        #expect(!PowerHelperConstants.releaseClientRequirement.isEmpty)
        #expect(PowerHelperConstants.releaseClientRequirement.contains("1.2.840.113635.100.6.1.13"))
        #expect(PowerHelperConstants.releaseClientRequirement.contains("get-task-allow"))
        #expect(PowerHelperConstants.validateRequirementSyntax(PowerHelperConstants.releaseClientRequirement))
    }

    @Test("PowerHelperConstants requirements match spec Debug verbatim")
    func requirementsVerbatim() {
        #expect(
            PowerHelperConstants.debugClientRequirement
                == #"identifier "com.hermes.Chorus" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#
        )
        #expect(
            PowerHelperConstants.debugHelperRequirement
                == #"identifier "com.hermes.Chorus.PowerHelper" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#
        )
        #expect(PowerHelperConstants.protocolVersion == 1)
        #expect(PowerHelperConstants.heartbeatInterval == 20)
        #expect(PowerHelperConstants.watchdogTimeout == 60)
    }
}
