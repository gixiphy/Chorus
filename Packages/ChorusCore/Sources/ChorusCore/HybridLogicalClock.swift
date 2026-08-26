import Foundation

/// Hybrid Logical Clock 時間戳：wall time（微秒）+ 邏輯計數器 + peer ID tie-break。
/// 全序比較，用於 last-writer-wins 衝突解決 —— 純 wall clock 在多機間有 NTP 漂移，
/// 純 Lamport 無法表達「最近」，HLC 兼得兩者。
public struct HLCTimestamp: Codable, Sendable, Hashable, Comparable {
    public let wallMicros: Int64
    public let counter: UInt32
    public let peerID: String

    public init(wallMicros: Int64, counter: UInt32, peerID: String) {
        self.wallMicros = wallMicros
        self.counter = counter
        self.peerID = peerID
    }

    public static func < (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
        if lhs.wallMicros != rhs.wallMicros { return lhs.wallMicros < rhs.wallMicros }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.peerID < rhs.peerID
    }
}

/// 單一節點的 HLC 產生器（Kulkarni 演算法）。
/// 純邏輯：physical time 由呼叫端注入，可測試。
public struct HLCGenerator: Sendable {
    public let peerID: String
    private var lastWall: Int64 = 0
    private var counter: UInt32 = 0

    public init(peerID: String) {
        self.peerID = peerID
    }

    /// 本地事件（送出前）取得時間戳。
    public mutating func next(wallNowMicros: Int64) -> HLCTimestamp {
        if wallNowMicros > lastWall {
            lastWall = wallNowMicros
            counter = 0
        } else {
            counter += 1
        }
        return HLCTimestamp(wallMicros: lastWall, counter: counter, peerID: peerID)
    }

    /// 收到遠端時間戳時合併，確保本地時鐘不落後於已見過的事件。
    public mutating func observe(_ remote: HLCTimestamp, wallNowMicros: Int64) {
        let newWall = max(lastWall, max(remote.wallMicros, wallNowMicros))
        if newWall == lastWall, newWall == remote.wallMicros {
            counter = max(counter, remote.counter) + 1
        } else if newWall == lastWall {
            counter += 1
        } else if newWall == remote.wallMicros {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        lastWall = newWall
    }
}
