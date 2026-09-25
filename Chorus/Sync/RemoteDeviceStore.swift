import ChorusCore
import Foundation
import Observation

/// 各已連線 Mac 回報的端點目錄與逐端點現值。
///
/// 三個介面共用這一份（主選單的遠端分類、同步設定的裝置管理、配置圖），
/// 所以清單解析與可用性判斷不散落在各個 SwiftUI view 裡。
///
/// 收到的內容**純屬資訊**：只更新顯示，不套用到本機硬體、不進 LWW。
/// 對方的裝置狀態不是我們要收斂的狀態。
@MainActor
@Observable
final class RemoteDeviceStore {
    /// 送出後還沒收到結果的指令。滑桿在這段期間顯示待套用值。
    struct PendingCommand: Sendable {
        let endpoint: RemoteEndpointID
        let capability: RemoteEndpointCapability
        let value: Double
    }

    /// 指令失敗後留在該控制項旁的簡短說明。
    struct ControlFailure: Sendable, Equatable {
        let message: String
        /// 端點已不存在（拔掉了）——與「寫入失敗」在 UI 上講法不同。
        let isUnavailable: Bool
    }

    /// peerID → 最新目錄。**整份替換**，不逐 key 合併。
    private(set) var directories: [String: DeviceDirectory] = [:]

    /// 指令 id → 內容。
    @ObservationIgnored private var pendingCommands: [UUID: PendingCommand] = [:]
    /// 指令 id → 逾時任務。
    @ObservationIgnored private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// 待套用值（`controlKey` → 值）。收到結果或逾時就清掉。
    private(set) var optimisticValues: [String: Double] = [:]
    /// 失敗說明（`controlKey` → 原因）。下一次成功時清掉。
    private(set) var failures: [String: ControlFailure] = [:]

    /// 指令沒有回音多久算逾時。遠端只是同一個區網的另一台 Mac，
    /// 正常往返是毫秒級；五秒還沒回來就是真的出事了。
    static let commandTimeout: Duration = .seconds(5)

    /// 待套用值與失敗說明的鍵。
    static func controlKey(_ endpoint: RemoteEndpointID, _ capability: RemoteEndpointCapability) -> String {
        "\(endpoint.storageKey)#\(capability.rawValue)"
    }

    // MARK: - 收到的資料

    /// 收到一份完整目錄。
    ///
    /// 舊的快照一律丟掉：晚到的舊清單會讓已拔除的裝置重新出現在選單上。
    /// 換了 session（重連）則無條件接受——那是一份全新的事實。
    @discardableResult
    func apply(_ directory: DeviceDirectory, from peerID: String) -> Bool {
        guard directory.peerID == peerID else { return false }
        if let existing = directories[peerID],
           existing.sessionID == directory.sessionID,
           directory.version <= existing.version {
            return false
        }
        directories[peerID] = directory
        // 目錄換了以後，指向已不存在端點的待套用值沒有意義
        pruneTransientState(for: peerID)
        return true
    }

    /// 收到單一端點的現值變化。
    ///
    /// 要求 session 與版本都對得上：上一次連線的回報、以及比手上目錄更舊
    /// 或更新的版本都不收。更新的版本代表我們還沒拿到那份目錄——等它到，
    /// 它自己就帶著現值。
    @discardableResult
    func apply(_ update: EndpointStateUpdate, from peerID: String) -> Bool {
        guard var directory = directories[peerID],
              directory.sessionID == update.sessionID,
              directory.version == update.version,
              let index = directory.endpoints.firstIndex(where: {
                  $0.kind == update.kind && $0.deviceID == update.deviceID
              })
        else { return false }
        directory.endpoints[index].values[update.capability.rawValue] = update.value
        directories[peerID] = directory
        return true
    }

    /// 斷線：立刻從操作介面移除。管理設定另外靠持久化的名稱保留離線記錄。
    func clear(peerID: String) {
        directories.removeValue(forKey: peerID)
        pruneTransientState(for: peerID)
    }

    // MARK: - 指令生命週期

    /// 記下一筆送出的指令，並排程逾時。
    func commandSent(
        id: UUID,
        endpoint: RemoteEndpointID,
        capability: RemoteEndpointCapability,
        value: Double,
        timedOut: @escaping @MainActor (UUID) -> Void
    ) {
        pendingCommands[id] = PendingCommand(endpoint: endpoint, capability: capability, value: value)
        let key = Self.controlKey(endpoint, capability)
        optimisticValues[key] = value
        failures.removeValue(forKey: key)
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.commandTimeout)
            guard !Task.isCancelled, self != nil else { return }
            timedOut(id)
        }
    }

    /// 收到指令結果。回傳 true 表示這是我們認得的指令。
    @discardableResult
    func commandCompleted(_ result: EndpointCommandResult) -> Bool {
        guard let pending = pendingCommands.removeValue(forKey: result.id) else { return false }
        timeoutTasks.removeValue(forKey: result.id)?.cancel()
        let key = Self.controlKey(pending.endpoint, pending.capability)
        optimisticValues.removeValue(forKey: key)

        switch result.outcome {
        case .applied:
            failures.removeValue(forKey: key)
            // 最終以對方回報為準：硬體量化、clamp 之後未必等於我們送的值
            if let value = result.value {
                applyConfirmedValue(value, endpoint: pending.endpoint, capability: pending.capability)
            }
        case .unavailable:
            failures[key] = ControlFailure(
                message: result.message ?? String(localized: "這個裝置已經不在了"),
                isUnavailable: true
            )
        default:
            failures[key] = ControlFailure(
                message: result.message ?? String(localized: "套用失敗"),
                isUnavailable: false
            )
        }
        return true
    }

    /// 逾時：回復已確認值並留下說明。**不重排隊**——斷線期間累積的滑桿
    /// 中間值等重連再一起重播，只會讓對方的螢幕演一遍我們剛剛的拖曳過程。
    func commandTimedOut(_ id: UUID) {
        guard let pending = pendingCommands.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        let key = Self.controlKey(pending.endpoint, pending.capability)
        optimisticValues.removeValue(forKey: key)
        failures[key] = ControlFailure(message: String(localized: "沒有回應"), isUnavailable: false)
    }

    /// 連線斷掉時作廢所有在飛的指令（對那台機器而言）。
    func cancelPendingCommands(for peerID: String) {
        for (id, pending) in pendingCommands where pending.endpoint.peerID == peerID {
            pendingCommands.removeValue(forKey: id)
            timeoutTasks.removeValue(forKey: id)?.cancel()
        }
    }

    private func applyConfirmedValue(
        _ value: Double,
        endpoint: RemoteEndpointID,
        capability: RemoteEndpointCapability
    ) {
        guard var directory = directories[endpoint.peerID],
              let index = directory.endpoints.firstIndex(where: {
                  $0.kind == endpoint.kind && $0.deviceID == endpoint.deviceID
              })
        else {
            // 指令送出之後、結果回來之前，那個端點被拔掉或目錄整份換過了。
            // 滑桿會退回「沒有現值」，這是對的；記一行是為了兩台機器實測時
            // 分得出「指令沒送到」與「送到了但端點已經不在」。
            ChorusLog.devices.notice("指令結果無處可放（端點已不在目錄裡）\(endpoint.storageKey)")
            return
        }
        directory.endpoints[index].values[capability.rawValue] = value
        directories[endpoint.peerID] = directory
    }

    private func pruneTransientState(for peerID: String) {
        cancelPendingCommands(for: peerID)
        let prefix = peerID + "|"
        optimisticValues = optimisticValues.filter { !$0.key.hasPrefix(prefix) }
        failures = failures.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - 查詢

    /// 這台 Mac 目前回報的端點（已連線且已取得清單時才有內容）。
    func endpoints(of peerID: String, kind: RemoteEndpointKind) -> [RemoteEndpoint] {
        (directories[peerID]?.endpoints ?? []).filter { $0.kind == kind }
    }

    func endpoint(_ id: RemoteEndpointID) -> RemoteEndpoint? {
        directories[id.peerID]?.endpoint(kind: id.kind, deviceID: id.deviceID)
    }

    /// 滑桿要顯示的值：待套用值優先（拖曳中），否則是對方確認的現值。
    /// 兩者都沒有時回 nil——UI 顯示「—」並停用，不以猜測值初始化。
    func displayValue(_ id: RemoteEndpointID, _ capability: RemoteEndpointCapability) -> Double? {
        if let optimistic = optimisticValues[Self.controlKey(id, capability)] { return optimistic }
        return endpoint(id)?.value(capability)
    }

    func failure(_ id: RemoteEndpointID, _ capability: RemoteEndpointCapability) -> ControlFailure? {
        failures[Self.controlKey(id, capability)]
    }

    /// 這個端點現在可以操作嗎：清單裡還在、而且宣告了這個能力。
    /// （「已配對／已連線／使用者已啟用」由呼叫端另外把關。）
    func isControllable(_ id: RemoteEndpointID, _ capability: RemoteEndpointCapability) -> Bool {
        endpoint(id)?.supports(capability) ?? false
    }
}
