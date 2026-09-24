import Foundation

/// 一批排列的還原群組（有序；主窗第一）。
public struct RestoreGroup: Sendable, Equatable {
    public let id: UUID
    public var tokens: [String]
    public let displayUUID: String
    public let topologyGeneration: UInt64

    public init(id: UUID, tokens: [String], displayUUID: String, topologyGeneration: UInt64) {
        self.id = id
        self.tokens = tokens
        self.displayUUID = displayUUID
        self.topologyGeneration = topologyGeneration
    }
}

/// 每個可操作視窗的原始 frame 還原鏈（記憶體、非持久）。
public struct RestoreStore: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var original: LayoutRect
        public var displayUUID: String
        public var topologyGeneration: UInt64
        /// 最近一次成功寫入的讀回值；nil＝尚未成功。
        public var expectedFrame: LayoutRect?
        public var groupID: UUID?

        public init(
            original: LayoutRect,
            displayUUID: String,
            topologyGeneration: UInt64,
            expectedFrame: LayoutRect? = nil,
            groupID: UUID? = nil
        ) {
            self.original = original
            self.displayUUID = displayUUID
            self.topologyGeneration = topologyGeneration
            self.expectedFrame = expectedFrame
            self.groupID = groupID
        }
    }

    private var entries: [String: Entry]
    private var groups: [UUID: RestoreGroup]

    public init(entries: [String: Entry] = [:], groups: [UUID: RestoreGroup] = [:]) {
        self.entries = entries
        self.groups = groups
    }

    public func entry(for token: String) -> Entry? {
        entries[token]
    }

    public func group(id: UUID) -> RestoreGroup? {
        groups[id]
    }

    public func group(containing token: String) -> RestoreGroup? {
        guard let gid = entries[token]?.groupID ?? groups.first(where: { $0.value.tokens.contains(token) })?.key
        else { return nil }
        return groups[gid]
    }

    /// 第一次成功排列時保存；連續換版型不覆蓋 original。若帶 groupID 則更新所屬群組。
    public mutating func rememberOriginalIfNeeded(
        token: String,
        original: LayoutRect,
        displayUUID: String,
        topologyGeneration: UInt64
    ) {
        rememberOriginalIfNeeded(
            token: token,
            original: original,
            displayUUID: displayUUID,
            topologyGeneration: topologyGeneration,
            groupID: nil
        )
    }

    public mutating func rememberOriginalIfNeeded(
        token: String,
        original: LayoutRect,
        displayUUID: String,
        topologyGeneration: UInt64,
        groupID: UUID?
    ) {
        if var existing = entries[token] {
            if let groupID, existing.groupID != groupID {
                removeTokenFromItsGroup(token)
                existing.groupID = groupID
                entries[token] = existing
            }
            return
        }
        entries[token] = Entry(
            original: original,
            displayUUID: displayUUID,
            topologyGeneration: topologyGeneration,
            groupID: groupID
        )
    }

    /// 每次成功排列後更新預期位置（不動 original）。
    public mutating func noteApplied(token: String, after: LayoutRect) {
        entries[token]?.expectedFrame = after
    }

    public mutating func beginGroup(
        id: UUID,
        tokens: [String],
        displayUUID: String,
        topologyGeneration: UInt64
    ) {
        for token in tokens {
            if var entry = entries[token], entry.groupID != id {
                if let old = entry.groupID, old != id {
                    removeToken(token, fromGroup: old)
                }
                entry.groupID = id
                entries[token] = entry
            }
        }
        groups[id] = RestoreGroup(
            id: id,
            tokens: tokens,
            displayUUID: displayUUID,
            topologyGeneration: topologyGeneration
        )
    }

    /// 只刪群組，不刪各 token 的 Entry。
    public mutating func dropGroup(id: UUID) {
        guard let group = groups.removeValue(forKey: id) else { return }
        for token in group.tokens {
            if entries[token]?.groupID == id {
                entries[token]?.groupID = nil
            }
        }
    }

    /// 目前 frame 與預期位置差距超過容差＝使用者動過；沒有 expectedFrame 一律視為已移動。
    public func isUserMoved(token: String, current: LayoutRect, tolerance: Double = 2) -> Bool {
        guard let expected = entries[token]?.expectedFrame else { return true }
        return !framesMatch(expected, current, tolerance: tolerance)
    }

    /// 還原成功後清除。
    @discardableResult
    public mutating func consume(token: String) -> Entry? {
        removeTokenFromItsGroup(token)
        return entries.removeValue(forKey: token)
    }

    /// 使用者自行移動／縮放後失效。
    public mutating func invalidate(token: String) {
        removeTokenFromItsGroup(token)
        entries.removeValue(forKey: token)
    }

    public mutating func removeAll() {
        entries.removeAll()
        groups.removeAll()
    }

    private mutating func removeTokenFromItsGroup(_ token: String) {
        guard let gid = entries[token]?.groupID ?? groupID(containing: token) else { return }
        removeToken(token, fromGroup: gid)
    }

    private func groupID(containing token: String) -> UUID? {
        groups.first(where: { $0.value.tokens.contains(token) })?.key
    }

    private mutating func removeToken(_ token: String, fromGroup gid: UUID) {
        guard var group = groups[gid] else { return }
        group.tokens.removeAll { $0 == token }
        if group.tokens.isEmpty {
            groups.removeValue(forKey: gid)
        } else {
            groups[gid] = group
        }
        if entries[token]?.groupID == gid {
            entries[token]?.groupID = nil
        }
    }

    private func framesMatch(_ a: LayoutRect, _ b: LayoutRect, tolerance: Double) -> Bool {
        abs(a.x - b.x) <= tolerance
            && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}
