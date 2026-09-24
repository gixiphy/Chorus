import Foundation
import Testing
@testable import ChorusCore

@Suite("WindowShortcuts")
struct WindowShortcutsTests {
    private let ctrlOpt: KeyChord.Modifiers = [.control, .option]

    @Test("25 個單視窗排列動作（含 1/4、3/4）都有對應指令，ID 不重複")
    func commandCatalog() {
        let arrangement = WindowCommand.allCases.filter {
            $0.group != .advanced && $0.group != .arrange && $0 != .restoreGroup
        }
        #expect(arrangement.count == 25)
        #expect(Set(WindowCommand.allCases.map(\.rawValue)).count == WindowCommand.allCases.count)
        #expect(WindowCommand.centerTwoThirds.rawValue == "center-two-thirds")
        #expect(WindowCommand.centerTwoThirds.layoutAction == .centerTwoThirds)
        #expect(WindowCommand.restore.layoutAction == nil)
    }

    @Test("restore-group 屬於常用、預設不綁鍵、無對應動作")
    func restoreGroupCommand() {
        #expect(WindowCommand.restoreGroup.rawValue == "restore-group")
        #expect(WindowCommand.restoreGroup.group == .common)
        #expect(WindowCommand.restoreGroup.layoutAction == nil)
        #expect(WindowCommand.restoreGroup.arrangement == nil)
        #expect(WindowCommand.restoreGroup.order == WindowCommand.restore.order + 1)
        #expect(ShortcutBindings()[.restoreGroup] == nil)
    }

    @Test("arrange-auto 是排列群組第一項，沒有固定版型或預設快捷鍵")
    func autoCommand() {
        #expect(WindowCommand.arrangeAuto.rawValue == "arrange-auto")
        #expect(WindowCommand.arrangeAuto.group == .arrange)
        #expect(WindowCommand.arrangeAuto.layoutAction == nil)
        #expect(WindowCommand.arrangeAuto.arrangement == nil)
        #expect(WindowCommand.commands(in: .arrange).first == .arrangeAuto)
        #expect(ShortcutBindings()[.arrangeAuto] == nil)
    }

    @Test("升級補綁：只補新指令的預設鍵；自己綁過的、預設鍵被佔用的不動")
    func addingDefaults() {
        var saved = ShortcutBindings.empty
        saved.assign(KeyChord(keyCode: 123, modifiers: ctrlOpt), to: .leftHalf)
        saved.assign(KeyChord(keyCode: 18, modifiers: [.control, .option, .shift]), to: .zone1)
        // ⌃⌥2 已經給了別的指令 → 第 2 個四分之一不補
        saved.assign(KeyChord(keyCode: 19, modifiers: ctrlOpt), to: .center)
        let migrated = saved.addingDefaults(for: ShortcutBindings.addedInBuild113)
        #expect(migrated[.firstFourth] == KeyChord(keyCode: 18, modifiers: ctrlOpt))
        #expect(migrated[.secondFourth] == nil)
        #expect(migrated[.center] == KeyChord(keyCode: 19, modifiers: ctrlOpt))
        #expect(migrated[.rightThreeFourths]?.displayString == "⌃⌥6")
        #expect(migrated[.zone1] == KeyChord(keyCode: 18, modifiers: [.control, .option, .shift]))
        #expect(migrated[.zone2]?.displayString == "⌃⌥⇧2")
        #expect(migrated[.rightHalf] == nil)
    }

    @Test("預設按鍵：25 項排列全綁（⌃⌥1–4＝1/4、⌃⌥5–6＝3/4），放進第 N 區是 ⌃⌥⇧1–4，還原是 ⌃⌥⌫")
    func defaults() {
        let bindings = ShortcutBindings()
        #expect(bindings.chords.count == 29)
        #expect(bindings[.firstFourth] == KeyChord(keyCode: 18, modifiers: ctrlOpt))
        #expect(bindings[.lastFourth]?.displayString == "⌃⌥4")
        #expect(bindings[.leftThreeFourths]?.displayString == "⌃⌥5")
        #expect(bindings[.rightThreeFourths]?.displayString == "⌃⌥6")
        #expect(bindings[.zone1]?.displayString == "⌃⌥⇧1")
        #expect(bindings[.zone4] == KeyChord(keyCode: 21, modifiers: [.control, .option, .shift]))
        #expect(WindowCommand.allCases.compactMap(\.zoneIndex) == [0, 1, 2, 3])
        #expect(bindings[.leftHalf] == KeyChord(keyCode: 123, modifiers: ctrlOpt))
        #expect(bindings[.centerTwoThirds] == KeyChord(keyCode: 15, modifiers: ctrlOpt))
        #expect(bindings[.restore] == KeyChord(keyCode: 51, modifiers: ctrlOpt))
        #expect(bindings[.nextDisplay] == KeyChord(keyCode: 124, modifiers: [.control, .option, .command]))
        #expect(!bindings.chords.values.contains(KeyChord(keyCode: 6, modifiers: ctrlOpt)))
        #expect(Set(bindings.chords.values).count == 29)
        #expect(bindings[.selectZone] == nil)
        #expect(bindings.isDefault)
        #expect(ShortcutBindings.empty.chords.isEmpty)
        #expect(!ShortcutBindings.empty.isDefault)
    }

    @Test("舊版「Chorus 基本」那七項原封不動存著的，升級成預設；動過的不碰")
    func legacyBasicMigrates() {
        #expect(ShortcutBindings.legacyBasic.chords.count == 7)
        #expect(ShortcutBindings.legacyBasic.migratedFromLegacy().isDefault)
        var custom = ShortcutBindings.legacyBasic
        custom.clear(.center)
        #expect(custom.migratedFromLegacy() == custom)
    }

    @Test("同一組按鍵不能綁兩個動作：回報占用者，不改動")
    func conflictIsReported() {
        var bindings = ShortcutBindings()
        let chord = KeyChord(keyCode: 123, modifiers: ctrlOpt)
        let result = bindings.assign(chord, to: .leftThird)
        #expect(result == .conflict(with: .leftHalf))
        #expect(bindings[.leftThird] == KeyChord(keyCode: 2, modifiers: ctrlOpt))
        #expect(bindings[.leftHalf] == chord)
    }

    @Test("明確移轉：舊動作解除綁定，新動作接手")
    func transferMovesChord() {
        var bindings = ShortcutBindings()
        let chord = KeyChord(keyCode: 123, modifiers: ctrlOpt)
        let result = bindings.assign(chord, to: .leftThird, transferring: true)
        #expect(result == .assigned)
        #expect(bindings[.leftThird] == chord)
        #expect(bindings[.leftHalf] == nil)
        #expect(!bindings.isDefault)
    }

    @Test("重綁同一動作到原按鍵不算衝突")
    func reassignSameCommand() {
        var bindings = ShortcutBindings()
        let chord = KeyChord(keyCode: 123, modifiers: ctrlOpt)
        #expect(bindings.assign(chord, to: .leftHalf) == .assigned)
    }

    @Test("沒有 ⌃⌥⌘ 任一修飾鍵的按鍵不接受")
    func requiresPrimaryModifier() {
        var bindings = ShortcutBindings.empty
        #expect(bindings.assign(KeyChord(keyCode: 0, modifiers: [.shift]), to: .leftHalf) == .invalid)
        #expect(bindings.assign(KeyChord(keyCode: 0, modifiers: []), to: .leftHalf) == .invalid)
        #expect(bindings.chords.isEmpty)
    }

    @Test("清除後變成自訂")
    func clearMakesCustom() {
        var bindings = ShortcutBindings()
        bindings.clear(.center)
        #expect(bindings[.center] == nil)
        #expect(!bindings.isDefault)
    }

    @Test("Codable 往返；未知動作 ID 略過不失敗")
    func codableRoundTrip() throws {
        var bindings = ShortcutBindings()
        _ = bindings.assign(
            KeyChord(keyCode: 49, modifiers: [.control, .shift], keyLabel: "Space"),
            to: .selectZone
        )
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode(ShortcutBindings.self, from: data) == bindings)

        let legacy = #"{"left-half":{"keyCode":123,"modifiers":6},"gone-action":{"keyCode":1,"modifiers":6}}"#
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(legacy.utf8))
        #expect(decoded.chords.count == 1)
        #expect(decoded[.leftHalf] != nil)
    }

    @Test("顯示字串：修飾鍵依 ⌃⌥⇧⌘ 順序，特殊鍵用符號")
    func displayString() {
        #expect(KeyChord(keyCode: 123, modifiers: ctrlOpt).displayString == "⌃⌥←")
        #expect(KeyChord(keyCode: 36, modifiers: ctrlOpt).displayString == "⌃⌥↩")
        #expect(KeyChord(keyCode: 51, modifiers: ctrlOpt).displayString == "⌃⌥⌫")
        #expect(KeyChord(keyCode: 15, modifiers: ctrlOpt).displayString == "⌃⌥R")
        #expect(KeyChord(keyCode: 124, modifiers: [.command, .option, .control]).displayString == "⌃⌥⌘→")
        #expect(KeyChord(keyCode: 200, modifiers: ctrlOpt, keyLabel: "Ä").displayString == "⌃⌥Ä")
    }

    @Test("比對按鍵時忽略 keyLabel")
    func chordEqualityIgnoresLabel() {
        let a = KeyChord(keyCode: 15, modifiers: ctrlOpt, keyLabel: "R")
        let b = KeyChord(keyCode: 15, modifiers: ctrlOpt)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}
