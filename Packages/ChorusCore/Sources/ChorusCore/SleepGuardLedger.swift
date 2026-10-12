import Foundation

/// Helper 帳本純邏輯（spec §6.3、§14.1；Fi A2／A8 覆寫 E11）。
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
    /// Fi A8：missing／corrupt ledger＋system 1（或無法證明 ownership）時阻擋新 acquire。
    public var recoveryBlocked = false

    public enum Action: Equatable, Sendable {
        case none
        case write(Bool)
        /// Fi A2：持有期間觀察到外部 SleepDisabled=0。holders 已清空。
        /// `shouldRestore` 時 C05 必須 write(false) 並通知 App；不可再 write(true)。
        case externalInterference(shouldRestore: Bool)
        /// Fi A8：未知 ownership／損毀帳本；拒絕新 acquire，直到核准的 recovery 路徑解除。
        case recoveryBlocked
        /// §14.1：`currentSystemValue == nil`，拒絕新 acquire。
        case systemValueUnknown
    }

    public init() {}

    public init(
        holders: [UInt64: Holder] = [:],
        priorValueWasDisabled: Bool? = nil,
        setByHelper: Bool = false,
        pendingRestore: Bool = false,
        recoveryBlocked: Bool = false
    ) {
        self.holders = holders
        self.priorValueWasDisabled = priorValueWasDisabled
        self.setByHelper = setByHelper
        self.pendingRestore = pendingRestore
        self.recoveryBlocked = recoveryBlocked
    }

    /// C05 在人工／核准 recovery 確認系統已安全後呼叫，解除 acquire 封鎖。
    public mutating func clearRecoveryBlock() {
        recoveryBlocked = false
    }

    /// 首次／續約。`currentSystemValue == nil` 時拒絕**新** acquire（§14.1）。
    public mutating func acquire(
        connectionID: UInt64,
        uid: UInt32,
        pid: Int32,
        now: Double,
        currentSystemValue: Bool?
    ) -> Action {
        if recoveryBlocked {
            return .recoveryBlocked
        }

        let isRenewal = holders[connectionID] != nil

        // Fi A2 / W0-1：任何既有 holding session（含 foreign／未 setByHelper）見外部 0
        // → 全域清空所有 holder 並回報干擾；foreign 的 shouldRestore=false，不寫任何值。
        if !holders.isEmpty, currentSystemValue == false {
            return invalidateForExternalInterference()
        }

        if isRenewal {
            // 心跳看到 1（或無法讀）：更新 heartbeat，不可把 setByHelper 清成 false（§14.1）
            holders[connectionID]?.lastHeartbeat = now
            holders[connectionID]?.pid = pid
            return .none
        }

        // 新連線
        if currentSystemValue == nil {
            return .systemValueUnknown
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
        // holders 原本非空且系統 0：不應走到這裡（已在上方干擾處理）；保守不寫 true
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

    /// - `persisted == nil`：missing／corrupt／version-invalid（由 C05 判定後傳入）。
    ///   若系統不是明確的 0，進入 `recoveryBlocked`，不猜 ownership（Fi A8／W0-4）。
    /// - 已知 foreign（`setByHelper == false`）維持原行為。
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
            ledger.recoveryBlocked = persisted.recoveryBlocked
        } else if currentSystemValue != false {
            // missing ledger + system 1 或 nil → 無法證明 ownership
            ledger.recoveryBlocked = true
            return (ledger, .recoveryBlocked)
        }

        if ledger.recoveryBlocked {
            return (ledger, .recoveryBlocked)
        }

        if ledger.setByHelper, currentSystemValue == true {
            ledger.pendingRestore = true
            return (ledger, .write(false))
        }
        return (ledger, .none)
    }

    // MARK: - Private

    private mutating func invalidateForExternalInterference() -> Action {
        holders.removeAll()
        // 只有自己寫過的才需要 restore；foreign session 只清 holder、不碰系統值。
        let shouldRestore = setByHelper
        if shouldRestore {
            pendingRestore = true
        }
        return .externalInterference(shouldRestore: shouldRestore)
    }

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
