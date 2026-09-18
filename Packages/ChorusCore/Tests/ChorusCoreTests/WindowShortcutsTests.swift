import Foundation
import Testing
@testable import ChorusCore

@Suite("WindowShortcuts")
struct WindowShortcutsTests {
    private let ctrlOpt: KeyChord.Modifiers = [.control, .option]

    @Test("截圖的 19 個排列動作都有對應指令，ID 不重複")
    func commandCatalog() {
        let arrangement = WindowCommand.allCases.filter { $0.group != .advanced }
        #expect(arrangement.count == 19)
        #expect(Set(WindowCommand.allCases.map(\.rawValue)).count == WindowCommand.allCases.count)
        #expect(WindowCommand.centerTwoThirds.rawValue == "center-two-thirds")
        #expect(WindowCommand.centerTwoThirds.layoutAction == .centerTwoThirds)
        #expect(WindowCommand.restore.layoutAction == nil)
    }

    @Test("Chorus 基本：四個方向鍵、填滿、置中、⌃⌥Z 還原")
    func chorusBasicScheme() {
        let bindings = ShortcutBindings(scheme: .chorusBasic)
        #expect(bindings.chords.count == 7)
        #expect(bindings[.leftHalf] == KeyChord(keyCode: 123, modifiers: ctrlOpt))
        #expect(bindings[.restore] == KeyChord(keyCode: 6, modifiers: ctrlOpt))
        #expect(bindings[.centerTwoThirds] == nil)
        #expect(bindings.matchingScheme == .chorusBasic)
    }

    @Test("Magnet 習慣：19 項全綁，還原改 ⌃⌥⌫，不留 Z")
    func magnetScheme() {
        let bindings = ShortcutBindings(scheme: .magnet)
        #expect(bindings.chords.count == 19)
        #expect(bindings[.centerTwoThirds] == KeyChord(keyCode: 15, modifiers: ctrlOpt))
        #expect(bindings[.restore] == KeyChord(keyCode: 51, modifiers: ctrlOpt))
        #expect(bindings[.nextDisplay] == KeyChord(keyCode: 124, modifiers: [.control, .option, .command]))
        #expect(!bindings.chords.values.contains(KeyChord(keyCode: 6, modifiers: ctrlOpt)))
        #expect(Set(bindings.chords.values).count == 19)
        #expect(bindings[.selectZone] == nil)
    }

    @Test("全部不綁定")
    func noneScheme() {
        let bindings = ShortcutBindings(scheme: .none)
        #expect(bindings.chords.isEmpty)
        #expect(bindings.matchingScheme == ShortcutScheme.none)
    }

    @Test("同一組按鍵不能綁兩個動作：回報占用者，不改動")
    func conflictIsReported() {
        var bindings = ShortcutBindings(scheme: .chorusBasic)
        let chord = KeyChord(keyCode: 123, modifiers: ctrlOpt)
        let result = bindings.assign(chord, to: .leftThird)
        #expect(result == .conflict(with: .leftHalf))
        #expect(bindings[.leftThird] == nil)
        #expect(bindings[.leftHalf] == chord)
    }

    @Test("明確移轉：舊動作解除綁定，新動作接手")
    func transferMovesChord() {
        var bindings = ShortcutBindings(scheme: .chorusBasic)
        let chord = KeyChord(keyCode: 123, modifiers: ctrlOpt)
        let result = bindings.assign(chord, to: .leftThird, transferring: true)
        #expect(result == .assigned)
        #expect(bindings[.leftThird] == chord)
        #expect(bindings[.leftHalf] == nil)
        #expect(bindings.matchingScheme == nil)
    }

    @Test("重綁同一動作到原按鍵不算衝突")
    func reassignSameCommand() {
        var bindings = ShortcutBindings(scheme: .chorusBasic)
        let chord = KeyChord(keyCode: 123, modifiers: ctrlOpt)
        #expect(bindings.assign(chord, to: .leftHalf) == .assigned)
    }

    @Test("沒有 ⌃⌥⌘ 任一修飾鍵的按鍵不接受")
    func requiresPrimaryModifier() {
        var bindings = ShortcutBindings(scheme: .none)
        #expect(bindings.assign(KeyChord(keyCode: 0, modifiers: [.shift]), to: .leftHalf) == .invalid)
        #expect(bindings.assign(KeyChord(keyCode: 0, modifiers: []), to: .leftHalf) == .invalid)
        #expect(bindings.chords.isEmpty)
    }

    @Test("清除後變成自訂")
    func clearMakesCustom() {
        var bindings = ShortcutBindings(scheme: .magnet)
        bindings.clear(.center)
        #expect(bindings[.center] == nil)
        #expect(bindings.matchingScheme == nil)
    }

    @Test("切換方案前列出受影響項目的舊值與新值")
    func schemeDiff() {
        let bindings = ShortcutBindings(scheme: .chorusBasic)
        let changes = bindings.changes(applying: .magnet)
        // 六項相同（四方向、填滿、置中）不列；還原 Z→⌫；其餘 12 項 無→新
        #expect(changes.count == 13)
        let restore = changes.first { $0.command == .restore }
        #expect(restore?.old == KeyChord(keyCode: 6, modifiers: ctrlOpt))
        #expect(restore?.new == KeyChord(keyCode: 51, modifiers: ctrlOpt))
        #expect(!changes.contains { $0.command == .leftHalf })
        #expect(changes.map(\.command) == changes.map(\.command).sorted { $0.order < $1.order })
    }

    @Test("Codable 往返；未知動作 ID 略過不失敗")
    func codableRoundTrip() throws {
        var bindings = ShortcutBindings(scheme: .magnet)
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
