import Foundation

/// 每個可操作視窗的原始 frame 還原鏈（記憶體、非持久）。
public struct RestoreStore: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var original: LayoutRect
        public var displayUUID: String
        public var topologyGeneration: UInt64
    }

    private var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public func entry(for token: String) -> Entry? {
        entries[token]
    }

    /// 第一次成功排列時保存；連續換版型不覆蓋。
    public mutating func rememberOriginalIfNeeded(
        token: String,
        original: LayoutRect,
        displayUUID: String,
        topologyGeneration: UInt64
    ) {
        if entries[token] != nil { return }
        entries[token] = Entry(
            original: original,
            displayUUID: displayUUID,
            topologyGeneration: topologyGeneration
        )
    }

    /// 還原成功後清除。
    @discardableResult
    public mutating func consume(token: String) -> Entry? {
        entries.removeValue(forKey: token)
    }

    /// 使用者自行移動／縮放後失效。
    public mutating func invalidate(token: String) {
        entries.removeValue(forKey: token)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
