import Foundation

/// 環境光基準同步的純狀態機。與 SyncEngineCore 完全獨立：
/// 環境光狀態**不進** fullState（新 ControlKey case 會讓舊版 peer 整包解碼失敗），
/// 走自己的 AmbientReport 訊息，舊版 peer 逐則丟棄、連線不斷。
///
/// 選源規則：
/// - 本機有光感器（hasLocalSensor）→ 永遠用自己的讀值，遠端回報只存不用。
/// - 無感器 → sticky source：跟隨最先聽到的回報者；來源靜默逾時
///   （staleTimeoutMicros，回報端每 15 秒 keepalive）才 failover 到最近的其他來源，
///   避免在兩台有感器的 Mac 之間震盪。
/// - 同一 origin 依 HLC 丟棄過期／亂序回報。
public struct AmbientSyncCore: Sendable {
    public enum Effect: Equatable, Sendable {
        /// 以此 lux 為環境基準重算本機所有受管顯示器的亮度。
        case followBaseline(lux: Double, sourceID: String)
    }

    public let localPeerID: String
    /// 本機是否有可用的光感器（app 端探測後設定）。
    public var hasLocalSensor: Bool = false
    /// 來源靜默多久視為失聯（預設 45 秒 = 3 × keepalive 間隔）。
    public var staleTimeoutMicros: Int64 = 45_000_000

    private var hlc: HLCGenerator
    /// 每個 origin 最後一筆回報（含本機）。
    private var lastSeen: [String: (hlc: HLCTimestamp, lux: Double, receivedAtMicros: Int64)] = [:]
    private var currentSourceID: String?

    public init(localPeerID: String) {
        self.localPeerID = localPeerID
        hlc = HLCGenerator(peerID: localPeerID)
    }

    // MARK: - 本地感器

    /// 本機感器產出一筆 committed lux → 要廣播的回報。本機即為基準來源。
    public mutating func localSample(lux: Double, wallNowMicros: Int64) -> AmbientReport {
        let timestamp = hlc.next(wallNowMicros: wallNowMicros)
        lastSeen[localPeerID] = (timestamp, lux, wallNowMicros)
        currentSourceID = localPeerID
        return AmbientReport(originID: localPeerID, hlc: timestamp, lux: lux)
    }

    // MARK: - 遠端回報

    /// 收到遠端回報 → 記錄；只有「本機無感器且該 origin 是（或成為）目前來源」才產生效果。
    public mutating func receive(_ report: AmbientReport, wallNowMicros: Int64) -> [Effect] {
        guard report.originID != localPeerID else { return [] }
        // 同一 origin 的過期／亂序回報丟棄
        if let previous = lastSeen[report.originID], report.hlc <= previous.hlc { return [] }
        hlc.observe(report.hlc, wallNowMicros: wallNowMicros)
        lastSeen[report.originID] = (report.hlc, report.lux, wallNowMicros)

        guard !hasLocalSensor else { return [] }
        if currentSourceID == nil || currentSourceID == localPeerID {
            currentSourceID = report.originID
        }
        guard currentSourceID == report.originID else { return [] }
        return [.followBaseline(lux: report.lux, sourceID: report.originID)]
    }

    /// 週期檢查（app 端定時呼叫）：目前來源失聯 → failover 或清空基準。
    public mutating func tick(wallNowMicros: Int64) -> [Effect] {
        guard !hasLocalSensor,
              let source = currentSourceID, source != localPeerID
        else { return [] }
        guard let seen = lastSeen[source] else {
            currentSourceID = nil
            return []
        }
        guard wallNowMicros - seen.receivedAtMicros > staleTimeoutMicros else { return [] }
        lastSeen[source] = nil
        return failover(wallNowMicros: wallNowMicros)
    }

    /// 某 peer 斷線（app 端連線層通知）→ 立即移除，不等靜默逾時。
    public mutating func forgetOrigin(_ peerID: String, wallNowMicros: Int64) -> [Effect] {
        guard peerID != localPeerID, lastSeen[peerID] != nil else { return [] }
        lastSeen[peerID] = nil
        guard currentSourceID == peerID else { return [] }
        return failover(wallNowMicros: wallNowMicros)
    }

    /// 目前的環境基準（無來源時 nil；app 端據此顯示「跟隨 X」／「無光線感測器」）。
    public func currentBaseline() -> (lux: Double, sourceID: String)? {
        guard let source = currentSourceID, let seen = lastSeen[source] else { return nil }
        return (seen.lux, source)
    }

    // MARK: - 私有

    /// 改跟最近聽到且未逾時的其他來源；沒有就清空基準（維持目前亮度不再跟隨）。
    private mutating func failover(wallNowMicros: Int64) -> [Effect] {
        let candidates = lastSeen.filter { origin, state in
            origin != localPeerID && wallNowMicros - state.receivedAtMicros <= staleTimeoutMicros
        }
        guard let best = candidates.max(by: { $0.value.receivedAtMicros < $1.value.receivedAtMicros }) else {
            currentSourceID = nil
            return []
        }
        currentSourceID = best.key
        return [.followBaseline(lux: best.value.lux, sourceID: best.key)]
    }
}
