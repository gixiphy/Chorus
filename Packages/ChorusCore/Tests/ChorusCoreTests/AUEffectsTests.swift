import Foundation
import Testing
@testable import ChorusCore

@Suite("AU 效果模型")
struct AUEffectsTests {
    private let delay = AUEffectComponent(
        type: 0x61756678, // 'aufx'
        subtype: 0x64656C79, // 'dely'
        manufacturer: 0x6170706C // 'appl'
    )

    @Test("元件 key 是穩定的十六進位（不靠 fourcc 可列印性）")
    func componentKeyIsStableHex() {
        #expect(delay.key == "61756678-64656c79-6170706c")
    }

    @Test("entry 編解碼往返（含 classInfo blob）")
    func entryRoundTripsThroughCodable() throws {
        let entry = AUEffectEntry(
            component: delay, name: "AUDelay", manufacturerName: "Apple",
            enabled: false, classInfo: Data([1, 2, 3])
        )
        let decoded = try JSONDecoder().decode(
            AUEffectEntry.self, from: JSONEncoder().encode(entry)
        )
        #expect(decoded == entry)
    }

    @Test("鏈以字典存檔（device UID → 有序清單）也能往返")
    func chainRoundTrips() throws {
        let chain = ["uid-a": [
            AUEffectEntry(component: delay, name: "AUDelay", manufacturerName: "Apple"),
            AUEffectEntry(component: delay, name: "AUDelay 2", manufacturerName: "Apple"),
        ]]
        let decoded = try JSONDecoder().decode(
            [String: [AUEffectEntry]].self, from: JSONEncoder().encode(chain)
        )
        #expect(decoded == chain)
        #expect(decoded["uid-a"]?.map(\.name) == ["AUDelay", "AUDelay 2"]) // 順序保留
    }

    @Test("per-app：存檔判準與建 tap 判準分開——關著的 EQ 保留設定但不建 tap")
    func storedButInactiveEQDoesNotNeedTap() throws {
        var disabledEQ = EQSettings.tenBandDefault()
        disabledEQ.bands[2].gainDB = 6
        disabledEQ.isEnabled = false

        let setting = AppAudioSetting(eq: disabledEQ)
        #expect(!setting.isNeutral) // 設定要保存（preset 不能蒸發）
        #expect(!setting.needsTap) // 但不值得為它接管音訊

        var enabled = setting
        enabled.eq?.isEnabled = true
        #expect(enabled.needsTap)

        var withEffect = AppAudioSetting()
        withEffect.effects = [AUEffectEntry(
            component: delay, name: "AUDelay", manufacturerName: "Apple", enabled: false
        )]
        #expect(!withEffect.isNeutral)
        #expect(!withEffect.needsTap) // 全停用的鏈同理
        withEffect.effects[0].enabled = true
        #expect(withEffect.needsTap)

        var settings = AppAudioSettings()
        settings["com.example.app"] = setting
        #expect(settings.adjustedBundleIDs == ["com.example.app"]) // UI 找得到
        #expect(settings.bundleIDsNeedingTap.isEmpty) // 引擎不建 tap
    }

    @Test("舊存檔（沒有 eq/effects 欄位）解碼成「沒有」，不是失敗")
    func legacyEntriesDecodeWithoutNewFields() throws {
        let legacy = #"{"gain":0.5,"muted":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppAudioSetting.self, from: legacy)
        #expect(decoded.gain == 0.5)
        #expect(decoded.eq == nil)
        #expect(decoded.effects.isEmpty)
        #expect(decoded.needsTap)
    }

    @Test("隔離閂：殘留的載入中 key 在啟動時被收養進隔離名單")
    func pendingLoadKeyIsAdoptedIntoQuarantine() {
        let adopted = EffectQuarantine.adopt(pendingLoadKey: delay.key, into: ["other"])
        #expect(adopted == ["other", delay.key])
        #expect(!EffectQuarantine.mayLoad(delay, quarantined: adopted))
    }

    @Test("沒有殘留就什麼都不變；空字串不算殘留")
    func noPendingKeyChangesNothing() {
        #expect(EffectQuarantine.adopt(pendingLoadKey: nil, into: []) == [])
        #expect(EffectQuarantine.adopt(pendingLoadKey: "", into: []) == [])
        #expect(EffectQuarantine.mayLoad(delay, quarantined: []))
    }
}
