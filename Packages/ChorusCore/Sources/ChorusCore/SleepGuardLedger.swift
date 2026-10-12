import Foundation

/// Helper 帳本純邏輯（spec §6.3、§14.1；Fi A2 覆寫 E11）。
///
/// `Action` 是待執行意圖，不能先當成功。寫 0 確認前不清除 ownership
/// （呼叫 `acknowledgeWrite(false)` 之後才清）。
public struct SleepGuardLedger: Codable, Sendable, Equatable {
    public struct Holder: Codable, Sendable, Equatable {
        public var connectionID: UInt64
        public var uid: UInt32
        public var pid: Int32
        public var since: Double
        public var lastHeartbeat: Double

        public init(connectionID: UInt64, uid: UInt32, pid: Int32, since: Double, lastHeartbeat: Double) {
            self.connectionID = connectionID
            self.uid = uid
            self.pid = pid
            self.since = since
            self.lastHeartbeat = lastHeartbeat
        }
    }

    public var holders: [UInt64: Holder] = [:]
    public var priorValueWasDisabled: Bool?
    public var setByHelper = false
    /// 寫 0 意圖已發出、尚未讀回確認（§14.1 crash window）。
    public var pendingRestore = false

    public enum Action: Equatable, Sendable {
        case none
        case write(Bool)
    }

    public init() {}

    public init(
        holders: [UInt64: Holder] = [:],
        priorValueWasDisabled: Bool? = nil,
        setByHelper: Bool = false,
        pendingRestore: Bool = false
    ) {
        self.holders = holders
        self.priorValueWasDisabled = priorValueWasDisabled
        self.setByHelper = setByHelper
        self.pendingRestore = pendingRestore
    }

    /// 首次／續約。`currentSystemValue == nil` 時拒絕**新** acquire（§14.1）。
    public mutating func acquire(
        connectionID: UInt64,
        uid: UInt32,
        pid: Int32,
        now: Double,
        currentSystemValue: Bool?
    ) -> Action {
        let isRenewal = holders[connectionID] != nil

        if isRenewal {
            // Fi A2：持有期間系統被外部改成 0 → 釋放、不重寫競爭
            if currentSystemValue == false {
                return release(connectionID: connectionID, currentSystemValue: currentSystemValue)
            }
            // 心跳看到 1：更新 heartbeat，不可把 setByHelper 清成 false（§14.1）
            holders[connectionID]?.lastHeartbeat = now
            holders[connectionID]?.pid = pid
            return .none
        }

        // 新連線
        if currentSystemValue == nil {
            // 拒絕首次 acquire，保留 recovery 狀態
            return .none
        }

        if holders.isEmpty {
            if setByHelper {
                // 自己的殘留：prior=false，維持 setByHelper，讓釋放一定寫 0
                priorValueWasDisabled = false
            } else {
                priorValueWasDisabled = currentSystemValue
                if currentSystemValue == true {
                    // 外部已設 1：不寫、不擁有
                    setByHelper = false
                } else {
                    setByHelper = true
                    pendingRestore = false
                    addHolder(connectionID: connectionID, uid: uid, pid: pid, now: now)
                    return .write(true)
                }
            }
        }

        addHolder(connectionID: connectionID, uid: uid, pid: pid, now: now)

        // 系統已是 1：既有殘留 ownership 或外部值都不寫
        if currentSystemValue == true {
            return .none
        }
        // holders 原本非空、系統為 0（異常）：重申寫 1 僅在仍有其他 holder 且 setByHelper 時
        // 新 holder 加入非空表且系統 0：Fi A2 不競爭重寫；視為需要寫回若我們擁有
        if setByHelper {
            return .write(true)
        }
        return .none
    }

    public mutating func release(connectionID: UInt64, currentSystemValue: Bool?) -> Action {
        guard holders.removeValue(forKey: connectionID) != nil else {
            return .none
        }
        return finalizeIfEmpty(currentSystemValue: currentSystemValue)
    }

    public mutating func dropConnection(_ id: UInt64, currentSystemValue: Bool?) -> Action {
        release(connectionID: id, currentSystemValue: currentSystemValue)
    }

    public mutating func expire(
        now: Double,
        timeout: Double,
        currentSystemValue: Bool?
    ) -> (Action, expired: [UInt64]) {
        let expiredIDs = holders.values
            .filter { now - $0.lastHeartbeat > timeout }
            .map(\.connectionID)
        for id in expiredIDs {
            holders.removeValue(forKey: id)
        }
        let action = finalizeIfEmpty(currentSystemValue: currentSystemValue)
        return (action, expiredIDs.sorted())
    }

    /// 硬底線：清掉所有 holder；自己寫的才 write(false)，外部值不碰。
    public mutating func forceOff(currentSystemValue: Bool?) -> Action {
        holders.removeAll()
        if setByHelper {
            pendingRestore = true
            return .write(false)
        }
        return .none
    }

    /// 寫入成功確認後呼叫。寫 0 成功才清 ownership（§14.1）。
    public mutating func acknowledgeWrite(_ enabled: Bool) {
        if enabled {
            setByHelper = true
            pendingRestore = false
        } else {
            setByHelper = false
            priorValueWasDisabled = nil
            pendingRestore = false
        }
    }

    /// 寫入失敗：保留可重試狀態。
    public mutating func noteWriteFailure() {
        // ownership／pendingRestore 不變
    }

    public static func reconcileOnLaunch(
        persisted: SleepGuardLedger?,
        currentSystemValue: Bool?
    ) -> (SleepGuardLedger, Action) {
        var ledger = SleepGuardLedger()
        // holders 不跨行程
        if let persisted {
            ledger.setByHelper = persisted.setByHelper
            ledger.priorValueWasDisabled = persisted.priorValueWasDisabled
            ledger.pendingRestore = persisted.pendingRestore || persisted.setByHelper
        }

        if ledger.setByHelper, currentSystemValue == true {
            ledger.pendingRestore = true
            return (ledger, .write(false))
        }
        return (ledger, .none)
    }

    // MARK: - Private

    private mutating func addHolder(connectionID: UInt64, uid: UInt32, pid: Int32, now: Double) {
        holders[connectionID] = Holder(
            connectionID: connectionID,
            uid: uid,
            pid: pid,
            since: now,
            lastHeartbeat: now
        )
    }

    private mutating func finalizeIfEmpty(currentSystemValue: Bool?) -> Action {
        guard holders.isEmpty else { return .none }
        if setByHelper {
            pendingRestore = true
            // 不在此處清 setByHelper／prior —— 等 acknowledgeWrite(false)
            return .write(false)
        }
        // 外部值：不碰
        priorValueWasDisabled = nil
        return .none
    }
}
