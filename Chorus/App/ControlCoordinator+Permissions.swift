import ChorusCore
import Foundation

extension ControlCoordinator {
    private static let permissionLog = ChorusLog(category: "permissions")

    /// 入站訊息的權限關卡。回傳 false ＝ 已處理（丟棄或回覆拒絕），呼叫端不要再往下。
    func admit(_ message: SyncMessage, from peerID: String) -> Bool {
        // 測試宿主可能沒接上配對儲存；正式路徑上 session 一定來自已配對裝置
        guard let pairedPeers else { return true }
        switch pairedPeers.policy(for: peerID).admission(for: message) {
        case .allow:
            return true
        case .drop:
            // debug 而非 notice：被擋的同步滑桿一秒可以來好幾筆
            Self.permissionLog.debug("依權限設定丟棄來自 \(peerID.prefix(8)) 的訊息")
            return false
        case let .rejectEndpointCommand(id):
            Self.permissionLog.notice("依權限設定拒絕來自 \(peerID.prefix(8)) 的裝置指令")
            let result = EndpointCommandResult(
                id: id,
                outcome: .denied,
                message: String(localized: "已被對方的權限設定拒絕")
            )
            sessionManager?.send(Envelope(msg: .endpointCommandResult(result)), to: peerID)
            return false
        }
    }
}
