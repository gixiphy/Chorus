import Foundation
import Network
import Synchronization

enum FramedConnectionError: Error, Equatable {
    /// 連線已關閉，不再接受送出。
    case closed
    /// 送出沒有在期限內被網路層收下；連線已隨之關閉。
    case sendTimedOut
    /// payload 超過單一 frame 上限（對方也會因此斷線，不送）。
    case payloadTooLarge
}

/// NWConnection + 4-byte big-endian length prefix 的封裝：raw frame 進出。
/// 同步通道（TLS-PSK + Envelope JSON）與配對通道（明文 + PairingMessage JSON）共用。
///
/// 收尾規則：`finish`（stream 結束＋`onClose`）**只發生一次**，不論是本機 close、
/// 對方斷線還是送出逾時先到；關閉之後的 send 立刻丟錯。
final class FramedNWConnection: @unchecked Sendable {
    /// 單一 frame 上限；超過視為協定破壞，直接斷線。
    static let maxFrameLength = 1 << 20
    /// 送出期限：`contentProcessed` 只代表本機網路層收下了，不代表對方已經套用。
    static let sendTimeout: Duration = .seconds(5)

    let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let finished = Atomic(false)

    /// 連線關閉（任何原因）時觸發一次。
    private let onClose: @Sendable () -> Void

    init(connection: NWConnection, label: String, onClose: @escaping @Sendable () -> Void = {}) {
        self.connection = connection
        queue = DispatchQueue(label: "com.hermes.Chorus.conn.\(label)")
        self.onClose = onClose
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        incomingContinuation = continuation
    }

    var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    var isClosed: Bool { finished.load(ordering: .sequentiallyConsistent) }

    /// 對方的 host 字串（記錄手動端點用）。
    var remoteHostString: String? {
        guard case let .hostPort(host, _) = remoteEndpoint else { return nil }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address): return "\(address)"
        case let .name(name, _): return name
        @unknown default: return nil
        }
    }

    /// 啟動並等待 ready。TLS 握手失敗、被拒或逾時都會丟錯。
    ///
    /// `.waiting` 一律視為立即失敗：loopback 連線被拒、local network 權限被拒
    /// 都會停在 waiting 且沒有「網路路徑變化」可觸發自動恢復——失敗後交給
    /// 上層的重撥退避。逾時用 watchdog cancel 連線（cancel 保證 state handler
    /// resume，continuation 不會懸掛）。
    func start(timeout: Duration = .seconds(10)) async throws {
        let connection = connection
        let queue = queue
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled {
                connection.cancel()
            }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let box = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(.success(()))
                case let .failed(error):
                    box.resume(.failure(error))
                case .cancelled:
                    box.resume(.failure(NWError.posix(.ECANCELED)))
                case let .waiting(error):
                    box.resume(.failure(error))
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        // ready 之後改為監聽斷線
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        receiveNextFrame()
    }

    /// 送出一個 frame。期限內網路層沒收下就關閉連線並丟 `sendTimedOut`——
    /// 送不出去的連線留著只會讓後面的訊息越堆越多。
    func send(_ payload: Data, timeout: Duration = sendTimeout) async throws {
        guard !isClosed else { throw FramedConnectionError.closed }
        guard payload.count <= Self.maxFrameLength else { throw FramedConnectionError.payloadTooLarge }
        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let connection = connection
        let queue = queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let box = ResumeOnce(continuation)
            // DispatchWorkItem 的 cancel 是執行緒安全的；完成回呼只拿它來取消計時
            nonisolated(unsafe) let deadline = DispatchWorkItem { [weak self] in
                if box.resume(.failure(FramedConnectionError.sendTimedOut)) {
                    self?.close()
                }
            }
            connection.send(content: frame, completion: .contentProcessed { error in
                deadline.cancel()
                box.resume(error.map { .failure($0) } ?? .success(()))
            })
            queue.asyncAfter(deadline: .now() + timeout.millis / 1_000, execute: deadline)
        }
    }

    func close() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard finished.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
        else { return }
        incomingContinuation.finish()
        onClose()
    }

    private func receiveNextFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let header, header.count == 4 else {
                self.finish()
                return
            }
            let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard length > 0, length <= Self.maxFrameLength else {
                self.close()
                return
            }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] payload, _, _, error in
                guard let self else { return }
                guard error == nil, let payload, payload.count == length else {
                    self.finish()
                    return
                }
                self.incomingContinuation.yield(payload)
                self.receiveNextFrame()
            }
            _ = isComplete
        }
    }
}

/// CheckedContinuation 只允許 resume 一次；NW state handler 與逾時可能都會觸發。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    /// 回傳這一次是不是真的 resume 了（false ＝ 另一條路先到）。
    @discardableResult
    func resume(_ result: Result<Void, any Error>) -> Bool {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success: taken?.resume()
        case let .failure(error): taken?.resume(throwing: error)
        }
        return taken != nil
    }
}
