import Foundation

/// 一次多視窗排列（或整組還原）的逐窗結果與摘要計數。
public struct ArrangementReport: Sendable, Equatable {
    /// Core 內部代碼，不是顯示字串；顯示由 App 端對照。
    public static let timeoutReason = "timeout"

    public enum Skip: Sendable, Equatable {
        case timeBudget
        case topologyChanged
        case permissionRevoked
    }

    public enum Status: Sendable, Equatable {
        case applied
        case constrained
        /// 寫入失敗後已回復 before frame（讀回符合）。
        case reverted(reason: String)
        /// 寫入失敗且回復也失敗；視窗停在 `after`。
        case revertFailed(reason: String)
        case failed(reason: String)
        case skipped(Skip)
    }

    public struct Item: Sendable, Equatable {
        public let token: String
        public let appName: String
        public let target: LayoutRect
        public let before: LayoutRect?
        public let after: LayoutRect?
        public let status: Status

        public init(
            token: String,
            appName: String,
            target: LayoutRect,
            before: LayoutRect?,
            after: LayoutRect?,
            status: Status
        ) {
            self.token = token
            self.appName = appName
            self.target = target
            self.before = before
            self.after = after
            self.status = status
        }
    }

    /// 自動排列退回填滿時為 nil；整組還原也為 nil。
    public let arrangement: WindowArrangement?
    public let slotCount: Int
    public let items: [Item]
    public let groupID: UUID?

    public init(
        arrangement: WindowArrangement?,
        slotCount: Int,
        items: [Item],
        groupID: UUID?
    ) {
        self.arrangement = arrangement
        self.slotCount = slotCount
        self.items = items
        self.groupID = groupID
    }

    /// applied + constrained
    public var appliedCount: Int {
        items.reduce(0) { count, item in
            switch item.status {
            case .applied, .constrained: return count + 1
            default: return count
            }
        }
    }

    public var constrainedCount: Int {
        items.reduce(0) { count, item in
            if case .constrained = item.status { return count + 1 }
            return count
        }
    }

    /// failed / reverted / revertFailed / skipped
    public var failedItems: [Item] {
        items.filter { item in
            switch item.status {
            case .failed, .reverted, .revertFailed, .skipped: return true
            case .applied, .constrained: return false
            }
        }
    }

    /// timeout 失敗與 timeBudget／topologyChanged skip 可重試。
    public var retryable: [Item] {
        items.filter { item in
            switch item.status {
            case .failed(let reason) where reason == Self.timeoutReason:
                return true
            case .skipped(.timeBudget), .skipped(.topologyChanged):
                return true
            default:
                return false
            }
        }
    }

    public var isComplete: Bool { failedItems.isEmpty }

    /// 任一 applied / constrained / revertFailed
    public var didMoveAnyWindow: Bool {
        items.contains { item in
            switch item.status {
            case .applied, .constrained, .revertFailed: return true
            default: return false
            }
        }
    }

    public var emptySlots: Int { max(0, slotCount - items.count) }
}
