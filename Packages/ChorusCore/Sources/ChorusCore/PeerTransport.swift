import Foundation

/// 同步核心與實際網路層（Network.framework）之間的接縫。
/// 測試用 InMemoryTransport，正式用 PeerConnection。
public protocol PeerTransport: Sendable {
    /// 送出一筆 envelope。連線已斷時丟錯。
    func send(_ envelope: Envelope) async throws
    /// 對方送來的 envelope 串流；連線關閉時結束。
    var incoming: AsyncStream<Envelope> { get }
    func close()
}

public enum PeerTransportError: Error {
    case closed
}
