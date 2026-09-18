import Foundation

/// 可由選單與全域快捷鍵觸發的視窗指令。rawValue 是對外的 action ID（設定檔、未來 CLI 共用）。
public enum WindowCommand: String, Sendable, Codable, CaseIterable, Hashable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeft = "top-left-quarter"
    case topRight = "top-right-quarter"
    case bottomLeft = "bottom-left-quarter"
    case bottomRight = "bottom-right-quarter"
    case leftThird = "left-third"
    case centerThird = "center-third"
    case rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds"
    case centerTwoThirds = "center-two-thirds"
    case rightTwoThirds = "right-two-thirds"
    case nextDisplay = "next-display"
    case previousDisplay = "previous-display"
    case maximize
    case center
    case restore
    case arrangeLeftRight = "arrange-left-right"
    case arrangeMainLeft = "arrange-main-left"
    case arrangeMainRight = "arrange-main-right"
    case arrangeThreeColumns = "arrange-three-columns"
    case arrangeQuarters = "arrange-quarters"
    case selectZone = "select-zone"

    public enum Group: String, Sendable, CaseIterable, Hashable {
        case halves
        case quarters
        case thirds
        case twoThirds
        case displays
        case common
        /// 一次排多個視窗。
        case arrange
        case advanced
    }

    public var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .quarters
        case .leftThird, .centerThird, .rightThird: return .thirds
        case .leftTwoThirds, .centerTwoThirds, .rightTwoThirds: return .twoThirds
        case .nextDisplay, .previousDisplay: return .displays
        case .maximize, .center, .restore: return .common
        case .arrangeLeftRight, .arrangeMainLeft, .arrangeMainRight, .arrangeThreeColumns, .arrangeQuarters:
            return .arrange
        case .selectZone: return .advanced
        }
    }

    /// 純幾何的指令對應到 `LayoutAction`；跨螢幕、還原、選區由協調器另行處理。
    public var layoutAction: LayoutAction? {
        switch self {
        case .leftHalf: return .leftHalf
        case .rightHalf: return .rightHalf
        case .topHalf: return .topHalf
        case .bottomHalf: return .bottomHalf
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .leftThird: return .leftThird
        case .centerThird: return .centerThird
        case .rightThird: return .rightThird
        case .leftTwoThirds: return .leftTwoThirds
        case .centerTwoThirds: return .centerTwoThirds
        case .rightTwoThirds: return .rightTwoThirds
        case .maximize: return .maximize
        case .center: return .centerPreserveSize
        case .nextDisplay, .previousDisplay, .restore, .selectZone,
             .arrangeLeftRight, .arrangeMainLeft, .arrangeMainRight, .arrangeThreeColumns, .arrangeQuarters:
            return nil
        }
    }

    /// 多視窗排列指令對應的佈局。
    public var arrangement: WindowArrangement? {
        switch self {
        case .arrangeLeftRight: return .leftRight
        case .arrangeMainLeft: return .mainLeft
        case .arrangeMainRight: return .mainRight
        case .arrangeThreeColumns: return .threeColumns
        case .arrangeQuarters: return .quarters
        default: return nil
        }
    }

    /// 宣告順序；介面與差異清單依此排序。
    public var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    public static func commands(in group: Group) -> [WindowCommand] {
        allCases.filter { $0.group == group }
    }
}

/// 一組全域快捷鍵：硬體 keyCode＋修飾鍵。`keyLabel` 只供顯示（錄製當下的鍵帽字元），不參與比對。
public struct KeyChord: Sendable, Codable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Codable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(Int.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var keyLabel: String?

    public init(keyCode: UInt16, modifiers: Modifiers, keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public static func == (lhs: KeyChord, rhs: KeyChord) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    /// 只有 Shift 或沒有修飾鍵的組合會吃掉一般打字，不接受。
    public var isBindable: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? keyLabel ?? "#\(keyCode)")
    }

    /// ANSI 配置的鍵名。非 ANSI 鍵盤上字母位置可能不同，錄製時的 `keyLabel` 作為後備。
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// 指令 → 按鍵的對照。保證同一組按鍵最多綁一個指令。
public struct ShortcutBindings: Sendable, Equatable {
    public enum AssignResult: Sendable, Equatable {
        case assigned
        case conflict(with: WindowCommand)
        case invalid
    }

    public private(set) var chords: [WindowCommand: KeyChord]

    /// 預設：沿用 Magnet 的按鍵（使用者裁決，單一版本、不設方案）。
    public init() {
        chords = Self.defaultChords
    }

    private init(chords: [WindowCommand: KeyChord]) {
        self.chords = chords
    }

    /// 全部不綁；錄製期間暫停全域註冊時用。
    public static let empty = ShortcutBindings(chords: [:])

    public var isDefault: Bool { chords == Self.defaultChords }

    public static let defaultChords: [WindowCommand: KeyChord] = {
        let co: KeyChord.Modifiers = [.control, .option]
        let coc: KeyChord.Modifiers = [.control, .option, .command]
        func chord(_ keyCode: UInt16, _ modifiers: KeyChord.Modifiers = co) -> KeyChord {
            KeyChord(keyCode: keyCode, modifiers: modifiers)
        }
        return [
            .leftHalf: chord(123), .rightHalf: chord(124), .topHalf: chord(126), .bottomHalf: chord(125),
            .topLeft: chord(32), .topRight: chord(34), .bottomLeft: chord(38), .bottomRight: chord(40),
            .leftThird: chord(2), .centerThird: chord(3), .rightThird: chord(5),
            .leftTwoThirds: chord(14), .centerTwoThirds: chord(15), .rightTwoThirds: chord(17),
            .nextDisplay: chord(124, coc), .previousDisplay: chord(123, coc),
            .maximize: chord(36), .center: chord(8), .restore: chord(51),
        ]
    }()

    /// build 106 的「Chorus 基本」方案：四個方向鍵、填滿、置中、⌃⌥Z 還原。只供升級判斷。
    static let legacyBasic: ShortcutBindings = {
        let co: KeyChord.Modifiers = [.control, .option]
        return ShortcutBindings(chords: [
            .leftHalf: KeyChord(keyCode: 123, modifiers: co), .rightHalf: KeyChord(keyCode: 124, modifiers: co),
            .topHalf: KeyChord(keyCode: 126, modifiers: co), .bottomHalf: KeyChord(keyCode: 125, modifiers: co),
            .maximize: KeyChord(keyCode: 36, modifiers: co), .center: KeyChord(keyCode: 8, modifiers: co),
            .restore: KeyChord(keyCode: 6, modifiers: co),
        ])
    }()

    /// 存的若正好是舊「Chorus 基本」（＝沒自訂過），換成現在的預設；動過任何一項就原樣保留。
    public func migratedFromLegacy() -> ShortcutBindings {
        self == Self.legacyBasic ? ShortcutBindings() : self
    }

    public subscript(command: WindowCommand) -> KeyChord? {
        chords[command]
    }

    public func command(for chord: KeyChord) -> WindowCommand? {
        chords.first { $0.value == chord }?.key
    }

    @discardableResult
    public mutating func assign(
        _ chord: KeyChord,
        to command: WindowCommand,
        transferring: Bool = false
    ) -> AssignResult {
        guard chord.isBindable else { return .invalid }
        if let owner = self.command(for: chord), owner != command {
            guard transferring else { return .conflict(with: owner) }
            chords[owner] = nil
        }
        chords[command] = chord
        return .assigned
    }

    public mutating func clear(_ command: WindowCommand) {
        chords[command] = nil
    }
}

extension ShortcutBindings: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try [String: KeyChord](from: decoder)
        var result: [WindowCommand: KeyChord] = [:]
        // 依宣告順序灌入：檔案被手改成重複按鍵時，先宣告的指令留下
        for command in WindowCommand.allCases {
            guard let chord = raw[command.rawValue], chord.isBindable,
                  !result.values.contains(chord)
            else { continue }
            result[command] = chord
        }
        chords = result
    }

    public func encode(to encoder: any Encoder) throws {
        let raw = Dictionary(uniqueKeysWithValues: chords.map { ($0.key.rawValue, $0.value) })
        try raw.encode(to: encoder)
    }
}
