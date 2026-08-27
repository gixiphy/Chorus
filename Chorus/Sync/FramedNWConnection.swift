import Foundation
import Network

/// NWConnection + 4-byte big-endian length prefix 的封裝：raw frame 進出。
/// 同步通道（TLS-PSK + Envelope JSON）與配對通道（明文 + PairingMessage JSON）共用。
final class FramedNWConnection: @unchecked Sendable {
    /// 單一 frame 上限；超過視為協定破壞，直接斷線。
    private static let maxFrameLength = 1 << 20

    let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation

    private let connection: NWConnection
    private let queue: DispatchQueue

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

    func send(_ payload: Data) async throws {
        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
        finish()
    }

    private func finish() {
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

/// CheckedContinuation 只允許 resume 一次；NW state handler 可能多次觸發。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, any Error>) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success: taken?.resume()
        case let .failure(error): taken?.resume(throwing: error)
        }
    }
}
