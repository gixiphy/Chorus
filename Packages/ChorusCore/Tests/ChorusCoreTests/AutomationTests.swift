import Foundation
import Testing
@testable import ChorusCore

@Suite("ControlTarget 解析")
struct ControlTargetTests {
    @Test("具名目標不分大小寫")
    func bareTargets() {
        #expect(ControlTarget.parse("allDisplays") == .allDisplays)
        #expect(ControlTarget.parse("ALLDISPLAYS") == .allDisplays)
        #expect(ControlTarget.parse(" system ") == .system)
        #expect(ControlTarget.parse("displayWithMouse") == .displayWithMouse)
    }

    @Test("帶引數的目標")
    func parameterised() {
        #expect(ControlTarget.parse("displayLike:DELL") == .displayLike("DELL"))
        #expect(ControlTarget.parse("deviceUID:abc-123") == .deviceUID("abc-123"))
    }

    @Test("只切第一個冒號——裝置名稱本身可能含冒號")
    func onlyFirstColon() {
        #expect(ControlTarget.parse("displayLike:Dell: U2720") == .displayLike("Dell: U2720"))
    }

    @Test("無法解析的目標回 nil")
    func rejects() {
        #expect(ControlTarget.parse("") == nil)
        #expect(ControlTarget.parse("nonsense") == nil)
        #expect(ControlTarget.parse("displayLike:") == nil)
        #expect(ControlTarget.parse("displayLike:   ") == nil)
    }

    @Test("字串往返")
    func roundTrip() {
        let targets: [ControlTarget] = [
            .display(name: "A"), .displayLike("B"), .displayUUID("C"),
            .displayWithMouse, .displayWithFocus, .builtinDisplay, .allDisplays,
            .device(name: "D"), .deviceLike("E"), .deviceUID("F"),
            .defaultOutput, .allDevices, .system,
            .app(bundleID: "com.x.y"), .appLike("Music"), .allApps,
        ]
        for target in targets {
            #expect(ControlTarget.parse(target.stringValue) == target)
        }
    }

    @Test("種類分類正確")
    func kinds() {
        #expect(ControlTarget.allDisplays.kind == .display)
        #expect(ControlTarget.defaultOutput.kind == .audioDevice)
        #expect(ControlTarget.system.kind == .system)
        #expect(ControlTarget.app(bundleID: "x").kind == .app)
    }
}

@Suite("ControlValue 收值規則")
struct ControlValueTests {
    @Test("0–1 的比例直接收")
    func fraction() throws {
        #expect(try ControlValue.parse("0.8", kind: .unitInterval) == .absolute(0.8))
        #expect(try ControlValue.parse("0", kind: .unitInterval) == .absolute(0))
    }

    @Test("百分比除以 100")
    func percent() throws {
        #expect(try ControlValue.parse("80%", kind: .unitInterval) == .absolute(0.8))
    }

    @Test("大於 1 的裸數字視為百分比——人與 LLM 打 80 的意思是 80%")
    func bareNumberAbove1() throws {
        #expect(try ControlValue.parse("80", kind: .unitInterval) == .absolute(0.8))
        // 1 是兩種讀法的重疊點，解成 100%，同值無歧義
        #expect(try ControlValue.parse("1", kind: .unitInterval) == .absolute(1))
    }

    @Test("超出範圍夾住")
    func clamps() throws {
        #expect(try ControlValue.parse("500%", kind: .unitInterval) == .absolute(1))
        #expect(try ControlValue.parse("0.0", kind: .unitInterval) == .absolute(0))
    }

    @Test("前導正負號＝相對增減")
    func relative() throws {
        #expect(try ControlValue.parse("+10%", kind: .unitInterval) == .offset(0.1))
        #expect(try ControlValue.parse("-0.1", kind: .unitInterval) == .offset(-0.1))
        #expect(try ControlValue.parse("+10", kind: .unitInterval) == .offset(0.1))
    }

    @Test("差異值屬性的正負號是絕對值的一部分，不是相對增減")
    func signedUnitIsAbsolute() throws {
        // ambientOffset -0.2 是合法的絕對差異值；若讀成 offset 就會變成「再減 0.2」
        #expect(try ControlValue.parse("-0.2", kind: .signedUnit) == .absolute(-0.2))
        #expect(try ControlValue.parse("+0.3", kind: .signedUnit) == .absolute(0.3))
        #expect(try ControlValue.parse("-20", kind: .signedUnit) == .absolute(-0.2))
        // 範圍夾在 ±0.5
        #expect(try ControlValue.parse("-90%", kind: .signedUnit) == .absolute(-0.5))
    }

    @Test("布林的各種寫法")
    func booleans() throws {
        for text in ["on", "true", "1", "yes", "ON"] {
            #expect(try ControlValue.parse(text, kind: .boolean) == .boolean(true))
        }
        for text in ["off", "false", "0", "no", "OFF"] {
            #expect(try ControlValue.parse(text, kind: .boolean) == .boolean(false))
        }
    }

    @Test("時長：關／秒／分／時／無限期")
    func durations() throws {
        #expect(try ControlValue.parse("off", kind: .duration) == .duration(0))
        #expect(try ControlValue.parse("30m", kind: .duration) == .duration(1800))
        #expect(try ControlValue.parse("1h", kind: .duration) == .duration(3600))
        #expect(try ControlValue.parse("90s", kind: .duration) == .duration(90))
        #expect(try ControlValue.parse("90", kind: .duration) == .duration(90))
        #expect(try ControlValue.parse("forever", kind: .duration) == .duration(-1))
    }

    @Test("時長編碼與 KeepAwakePlanner 相容")
    func durationMatchesKeepAwake() throws {
        guard case let .duration(seconds) = try ControlValue.parse("30m", kind: .duration) else {
            Issue.record("非 duration")
            return
        }
        #expect(KeepAwakePlanner.decode(seconds) == .duration(seconds: 1800))
        guard case let .duration(forever) = try ControlValue.parse("forever", kind: .duration) else {
            Issue.record("非 duration")
            return
        }
        #expect(KeepAwakePlanner.decode(forever) == .indefinite)
    }

    @Test("MCCS 代碼：十進位與十六進位")
    func rawCodes() throws {
        #expect(try ControlValue.parse("17", kind: .rawCode) == .rawCode(17))
        #expect(try ControlValue.parse("0x11", kind: .rawCode) == .rawCode(17))
    }

    @Test("壞值帶著可修正的 hint 拋出")
    func badValues() {
        for (text, kind) in [("abc", ControlValueKind.unitInterval),
                             ("maybe", .boolean),
                             ("soon", .duration),
                             ("", .unitInterval)] {
            #expect(throws: ControlError.self) {
                try ControlValue.parse(text, kind: kind)
            }
        }
    }
}

@Suite("ControlRequestValidator 相容性矩陣")
struct ControlRequestValidatorTests {
    @Test("set 亮度到顯示器：通過並解析出值")
    func happyPath() throws {
        let validated = try ControlRequestValidator.validate(ControlRequest(
            verb: .set, target: .allDisplays, property: .brightness, value: "80%"
        ))
        #expect(validated.value == .absolute(0.8))
        #expect(validated.property == .brightness)
    }

    @Test("屬性套錯目標種類即拒絕")
    func targetKindMismatch() {
        #expect(throws: ControlError.targetKindMismatch(property: .brightness, target: "defaultOutput")) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .set, target: .defaultOutput, property: .brightness, value: "80%"
            ))
        }
        #expect(throws: ControlError.targetKindMismatch(property: .volume, target: "allDisplays")) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .set, target: .allDisplays, property: .volume, value: "50%"
            ))
        }
    }

    @Test("輸入源不提供 get——讀回的值不可信（螢幕按鈕會改）")
    func inputIsWriteOnly() {
        #expect(throws: ControlError.verbNotAllowed(verb: .get, property: .input)) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .get, target: .allDisplays, property: .input
            ))
        }
    }

    @Test("非布林屬性不能 toggle")
    func toggleOnlyBooleans() {
        #expect(throws: ControlError.verbNotAllowed(verb: .toggle, property: .brightness)) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .toggle, target: .allDisplays, property: .brightness
            ))
        }
        // 布林屬性可以
        #expect(throws: Never.self) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .toggle, target: .defaultOutput, property: .mute
            ))
        }
    }

    @Test("set 少了值即拒絕，並提示該屬性的寫法")
    func setNeedsValue() {
        #expect(throws: ControlError.missingValue(.brightness)) {
            try ControlRequestValidator.validate(ControlRequest(
                verb: .set, target: .allDisplays, property: .brightness
            ))
        }
    }

    @Test("get 可以省略屬性——這是列舉入口")
    func getWithoutProperty() throws {
        let validated = try ControlRequestValidator.validate(ControlRequest(
            verb: .get, target: .allDisplays
        ))
        #expect(validated.property == nil)
    }

    @Test("perform 需要動作")
    func performNeedsAction() throws {
        #expect(throws: ControlError.missingAction) {
            try ControlRequestValidator.validate(ControlRequest(verb: .perform, target: .system))
        }
        let validated = try ControlRequestValidator.validate(ControlRequest(
            verb: .perform, target: .system, value: "電影", action: .runScene
        ))
        #expect(validated.action == .runScene)
        #expect(validated.actionArgument == "電影")
    }

    @Test("peer 原樣帶過——轉發由 executor 決定")
    func peerPassedThrough() throws {
        let validated = try ControlRequestValidator.validate(ControlRequest(
            verb: .set, target: .allDisplays, property: .brightness, value: "50%", peer: "客廳"
        ))
        #expect(validated.peer == "客廳")
    }

    @Test("每種錯誤都帶得出可修正的 hint")
    func errorsCarryHints() {
        let errors: [ControlError] = [
            .unknownVerb("x"), .unknownProperty("x"), .unknownTarget("x"), .unknownAction("x"),
            .targetNotFound("x", hint: "目前有 A"),
            .verbNotAllowed(verb: .toggle, property: .brightness),
            .targetKindMismatch(property: .volume, target: "allDisplays"),
            .badValue("x", hint: "請給 0–1"),
            .missingValue(.brightness), .missingProperty(.set), .missingAction,
            .peerNotFound("x", hint: "已配對：A"), .peerOffline("x"),
        ]
        for error in errors {
            #expect(!error.code.isEmpty)
            #expect(!error.message.isEmpty)
            #expect(error.hint != nil, "\(error.code) 少了 hint")
        }
    }
}

@Suite("ControlRequest 編碼")
struct ControlRequestCodingTests {
    @Test("JSON 往返")
    func roundTrip() throws {
        let request = ControlRequest(
            verb: .set, target: .displayLike("DELL"),
            property: .brightness, value: "80%", peer: "客廳"
        )
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
    }

    @Test("目標編成字串而非物件")
    func targetIsAString() throws {
        let data = try JSONEncoder().encode(ControlRequest(verb: .get, target: .allDisplays))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"target\":\"allDisplays\""))
    }

    @Test("壞目標的解碼錯誤帶語法提示")
    func badTargetDecoding() {
        let json = #"{"verb":"get","target":"nonsense"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        }
    }

    @Test("回應的成功與失敗形狀")
    func responses() throws {
        let ok = ControlResponse.success([
            ControlResult(target: "ASUS VS207", property: "brightness", value: .number(0.8)),
        ])
        let okJSON = String(decoding: try JSONEncoder().encode(ok), as: UTF8.self)
        #expect(okJSON.contains("\"ok\":true"))

        let failed = ControlResponse.failure(.targetNotFound("DELL", hint: "目前有 ASUS VS207"))
        let failedJSON = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
        #expect(failedJSON.contains("targetNotFound"))
        #expect(failedJSON.contains("ASUS VS207"))
    }
}


/// B6-6：逐 App 音訊在動詞層的形狀。
@Suite("Per-app 音訊的動詞層")
struct PerAppAutomationTests {
    @Test("app 定位解析得過，種類是 .app")
    func appTargetsParse() {
        #expect(ControlTarget.parse("app:com.apple.Music") == .app(bundleID: "com.apple.Music"))
        #expect(ControlTarget.parse("appLike:Music") == .appLike("Music"))
        #expect(ControlTarget.parse("allApps") == .allApps)
        #expect(ControlTarget.allApps.kind == .app)
        #expect(ControlTarget.allApps.isPlural)
        #expect(!ControlTarget.app(bundleID: "com.x").isPlural)
    }

    @Test("volume／mute 可以套在 app 上，brightness 不行")
    func compatibilityMatrix() throws {
        let volume = ControlRequest(
            verb: .set, target: .app(bundleID: "com.apple.Music"), property: .volume, value: "40%"
        )
        #expect(throws: Never.self) { try ControlRequestValidator.validate(volume) }

        let mute = ControlRequest(verb: .toggle, target: .appLike("Music"), property: .mute)
        #expect(throws: Never.self) { try ControlRequestValidator.validate(mute) }

        let brightness = ControlRequest(
            verb: .set, target: .app(bundleID: "com.apple.Music"), property: .brightness, value: "50%"
        )
        #expect(throws: ControlError.targetKindMismatch(property: .brightness, target: "app:com.apple.Music")) {
            try ControlRequestValidator.validate(brightness)
        }
    }

    @Test("音量收到 400%——per-app 可以 boost，值層不該提早砍成 100%")
    func gainAcceptsBoost() throws {
        let request = ControlRequest(
            verb: .set, target: .app(bundleID: "com.apple.Music"), property: .volume, value: "250%"
        )
        let validated = try ControlRequestValidator.validate(request)
        #expect(validated.value == .absolute(2.5))

        // 上限仍在：400% 是天花板
        let tooLoud = ControlRequest(
            verb: .set, target: .app(bundleID: "com.apple.Music"), property: .volume, value: "900%"
        )
        #expect(try ControlRequestValidator.validate(tooLoud).value == .absolute(4))
    }

    @Test("裝置音量的 0–1 由 executor 夾——值層只負責不要提早砍掉")
    func deviceVolumeStillParsesWide() throws {
        let request = ControlRequest(
            verb: .set, target: .defaultOutput, property: .volume, value: "250%"
        )
        #expect(try ControlRequestValidator.validate(request).value == .absolute(2.5))
    }

    @Test("per-app 遙控鍵編碼往返；不進 LWW 是 executor／coordinator 的事")
    func appKeysRoundTrip() throws {
        let keys: [ControlKey] = [
            .appVolume(bundleID: "com.apple.Music"),
            .appMute(bundleID: "com.spotify.client"),
        ]
        for key in keys {
            let data = try JSONEncoder().encode(key)
            #expect(try JSONDecoder().decode(ControlKey.self, from: data) == key)
        }
    }

    @Test("錯誤訊息裡的 app 目標不再寫「尚未啟用」")
    func hintMentionsPerAppAudio() {
        let hint = ControlError.targetKindMismatch(property: .volume, target: "allDisplays").hint ?? ""
        #expect(hint.contains("app"))
        #expect(!hint.contains("尚未啟用"))
        #expect(ControlTarget.syntaxHint.contains("app:<bundle id>"))
        #expect(ControlTarget.syntaxHint.contains("allApps"))
    }
}
