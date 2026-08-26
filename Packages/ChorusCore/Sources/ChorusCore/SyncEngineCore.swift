import Foundation

/// 同步引擎的純狀態機：輸入「本地變更」或「遠端訊息」，輸出決策。
/// 不做任何 IO；wall time 由呼叫端注入。
///
/// 防迴圈三層中的兩層在此實作：
/// 1. (originID, seq) 去重
/// 2. 收到的更新**永不**產生 broadcast 決策（結構上不轉發）
/// （第三層 expectedValue echo 抑制在 app 端的 ControlCoordinator。）
public struct SyncEngineCore: Sendable {
    public enum Effect: Equatable, Sendable {
        /// 把值套用到本機硬體（UI 同步更新）。
        case applyToHardware(key: ControlKey, value: Double)
    }

    public let localPeerID: String
    private var hlc: HLCGenerator
    private var nextSeq: UInt64 = 0
    private var dedup = UpdateDeduplicator()
    /// LWW：每個 key 最後套用的時間戳與值。
    private var lastApplied: [ControlKey: (hlc: HLCTimestamp, value: Double)] = [:]

    public init(localPeerID: String) {
        self.localPeerID = localPeerID
        hlc = HLCGenerator(peerID: localPeerID)
    }

    // MARK: - 本地變更

    /// 本地變更（UI 拖曳或硬體事件）→ 產生要廣播的 StateUpdate。
    /// 硬體套用由呼叫端自行處理（它就是變更來源）。
    public mutating func localChange(key: ControlKey, value: Double, wallNowMicros: Int64) -> StateUpdate {
        nextSeq += 1
        let timestamp = hlc.next(wallNowMicros: wallNowMicros)
        lastApplied[key] = (timestamp, value)
        return StateUpdate(originID: localPeerID, seq: nextSeq, hlc: timestamp, key: key, value: value)
    }

    // MARK: - 遠端訊息

    /// 收到遠端 StateUpdate → 套用或丟棄。回傳的 effects 保證不含任何廣播。
    public mutating func receive(_ update: StateUpdate, wallNowMicros: Int64) -> [Effect] {
        // 自己發出的更新繞回來（不應發生，保險）
        guard update.originID != localPeerID else { return [] }
        // 重複投遞
        guard !dedup.isDuplicate(originID: update.originID, seq: update.seq) else { return [] }

        hlc.observe(update.hlc, wallNowMicros: wallNowMicros)

        // LWW：較舊的更新丟棄
        if let last = lastApplied[update.key], update.hlc <= last.hlc {
            return []
        }
        lastApplied[update.key] = (update.hlc, update.value)
        return [.applyToHardware(key: update.key, value: update.value)]
    }

    /// 收到完整快照（新 peer 連上／重連）→ 逐項 LWW 合併。
    public mutating func receiveFullState(_ full: FullState, wallNowMicros: Int64) -> [Effect] {
        var effects: [Effect] = []
        for entry in full.entries {
            hlc.observe(entry.hlc, wallNowMicros: wallNowMicros)
            if let last = lastApplied[entry.key], entry.hlc <= last.hlc {
                continue
            }
            lastApplied[entry.key] = (entry.hlc, entry.value)
            effects.append(.applyToHardware(key: entry.key, value: entry.value))
        }
        return effects
    }

    /// 給新 peer 的完整快照。
    public func fullStateSnapshot() -> FullState {
        FullState(entries: lastApplied.map { key, state in
            FullState.Entry(key: key, value: state.value, hlc: state.hlc)
        })
    }

    /// 目前某個 key 的已知值（測試與 UI 用）。
    public func currentValue(for key: ControlKey) -> Double? {
        lastApplied[key]?.value
    }
}
