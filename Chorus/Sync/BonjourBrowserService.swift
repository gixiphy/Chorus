import ChorusCore
import Foundation
import Network

/// 探索到的 Chorus 服務。
struct DiscoveredPeer: Sendable {
    let peerID: String
    let name: String
    let endpoint: NWEndpoint
    let protocolVersion: Int
}

/// 瀏覽 `_chorus._tcp`，以 TXT 中的 peerID 去重並過濾自己。
final class BonjourBrowserService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hermes.Chorus.browser")
    private var browser: NWBrowser?

    let discoveries: AsyncStream<[DiscoveredPeer]>
    private let discoveriesContinuation: AsyncStream<[DiscoveredPeer]>.Continuation

    /// 最近一次 browser 狀態（診斷用；waiting 常見於 local network 權限被拒）。
    let states: AsyncStream<String>
    private let statesContinuation: AsyncStream<String>.Continuation

    init() {
        var continuation: AsyncStream<[DiscoveredPeer]>.Continuation!
        discoveries = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        discoveriesContinuation = continuation
        var stateContinuation: AsyncStream<String>.Continuation!
        states = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { stateContinuation = $0 }
        statesContinuation = stateContinuation
    }

    func start(myPeerID: String, serviceType: String = ChorusProtocol.serviceType) {
        queue.async { [self] in
            browser?.cancel()
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: nil)
            let newBrowser = NWBrowser(for: descriptor, using: ChorusTLS.plaintextParameters())
            newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                let peers = results.compactMap { result -> DiscoveredPeer? in
                    guard case let .bonjour(txt) = result.metadata,
                          let peerID = txt["pid"],
                          peerID != myPeerID,
                          let version = txt["v"].flatMap(Int.init)
                    else { return nil }
                    return DiscoveredPeer(
                        peerID: peerID,
                        name: txt["name"] ?? "",
                        endpoint: result.endpoint,
                        protocolVersion: version
                    )
                }
                self?.discoveriesContinuation.yield(peers)
            }
            newBrowser.stateUpdateHandler = { [weak self] state in
                self?.statesContinuation.yield("\(state)")
            }
            newBrowser.start(queue: queue)
            browser = newBrowser
        }
    }

    func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
        }
    }
}
