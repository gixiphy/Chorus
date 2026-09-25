import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// 逐裝置遠端控制的接收端規則。
///
/// 這一組全部圍繞同一個驗收條件：**舊快照、晚到的回報或指令，都不可以讓
/// 已經拔掉的端點重新出現在操作介面上**。
@MainActor
@Suite("遠端裝置目錄")
struct RemoteDeviceStoreTests {
    private let peer = "peer-1"

    private func endpoint(_ id: String, value: Double? = nil) -> RemoteEndpoint {
        RemoteEndpoint(
            deviceID: id,
            kind: .display,
            name: "Display \(id)",
            capabilities: [.brightness],
            values: value.map { ["brightness": $0] } ?? [:]
        )
    }

    private func directory(
        session: UUID,
        version: UInt64,
        endpoints: [RemoteEndpoint]
    ) -> DeviceDirectory {
        DeviceDirectory(peerID: peer, sessionID: session, version: version, endpoints: endpoints)
    }

    private func endpointID(_ deviceID: String) -> RemoteEndpointID {
        RemoteEndpointID(peerID: peer, kind: .display, deviceID: deviceID)
    }

    // MARK: - 目錄替換

    @Test("目錄是完整替換：拔掉的裝置真的消失")
    func directoryReplacesWholesale() {
        let store = RemoteDeviceStore()
        let session = UUID()
        store.apply(directory(session: session, version: 1, endpoints: [endpoint("a"), endpoint("b")]), from: peer)
        #expect(store.endpoints(of: peer, kind: .display).count == 2)

        // b 被拔掉 → 新快照只有 a。逐 key 合併的話 b 會永遠留著。
        store.apply(directory(session: session, version: 2, endpoints: [endpoint("a")]), from: peer)
        #expect(store.endpoints(of: peer, kind: .display).map(\.deviceID) == ["a"])
    }

    @Test("晚到的舊快照不會讓已移除的端點復活")
    func staleDirectoryIsIgnored() {
        let store = RemoteDeviceStore()
        let session = UUID()
        store.apply(directory(session: session, version: 2, endpoints: [endpoint("a")]), from: peer)
        // 網路亂序：版本 1 的快照比版本 2 晚到
        let accepted = store.apply(
            directory(session: session, version: 1, endpoints: [endpoint("a"), endpoint("b")]),
            from: peer
        )
        #expect(!accepted)
        #expect(store.endpoints(of: peer, kind: .display).map(\.deviceID) == ["a"])
    }

    @Test("換了 session（重連）無條件接受，版本號低也一樣")
    func newSessionAlwaysAccepted() {
        let store = RemoteDeviceStore()
        store.apply(directory(session: UUID(), version: 9, endpoints: [endpoint("a")]), from: peer)
        // 對方重開 App：版本從 1 重新算起，但那是一份全新的事實
        let accepted = store.apply(
            directory(session: UUID(), version: 1, endpoints: [endpoint("c")]),
            from: peer
        )
        #expect(accepted)
        #expect(store.endpoints(of: peer, kind: .display).map(\.deviceID) == ["c"])
    }

    @Test("目錄的 peerID 與寄件人不符時整份丟掉")
    func mismatchedPeerRejected() {
        let store = RemoteDeviceStore()
        let foreign = DeviceDirectory(
            peerID: "somebody-else", sessionID: UUID(), version: 1, endpoints: [endpoint("a")]
        )
        #expect(!store.apply(foreign, from: peer))
        #expect(store.endpoints(of: peer, kind: .display).isEmpty)
    }

    // MARK: - 逐端點回報

    @Test("回報要 session 與版本都對得上才收")
    func stateUpdateRequiresMatchingVersion() {
        let store = RemoteDeviceStore()
        let session = UUID()
        store.apply(directory(session: session, version: 5, endpoints: [endpoint("a", value: 0.3)]), from: peer)

        func update(session: UUID, version: UInt64, value: Double) -> EndpointStateUpdate {
            EndpointStateUpdate(
                sessionID: session, version: version, deviceID: "a",
                kind: .display, capability: .brightness, value: value
            )
        }

        // 上一次連線的回報
        #expect(!store.apply(update(session: UUID(), version: 5, value: 0.9), from: peer))
        // 比手上的目錄舊
        #expect(!store.apply(update(session: session, version: 4, value: 0.8), from: peer))
        // 比手上的目錄新：那份目錄還沒到，等它到自己會帶著現值
        #expect(!store.apply(update(session: session, version: 6, value: 0.7), from: peer))
        #expect(store.displayValue(endpointID("a"), .brightness) == 0.3)

        // 完全對上才收
        #expect(store.apply(update(session: session, version: 5, value: 0.6), from: peer))
        #expect(store.displayValue(endpointID("a"), .brightness) == 0.6)
    }

    @Test("回報指向不存在的端點時丟掉，不會憑空長出一筆")
    func stateUpdateForUnknownEndpointIgnored() {
        let store = RemoteDeviceStore()
        let session = UUID()
        store.apply(directory(session: session, version: 1, endpoints: [endpoint("a")]), from: peer)
        let ghost = EndpointStateUpdate(
            sessionID: session, version: 1, deviceID: "ghost",
            kind: .display, capability: .brightness, value: 0.5
        )
        #expect(!store.apply(ghost, from: peer))
        #expect(store.endpoints(of: peer, kind: .display).count == 1)
    }

    // MARK: - 值的優先序

    @Test("沒有現值時是 nil，不是猜出來的 0.5")
    func unknownValueIsNil() {
        let store = RemoteDeviceStore()
        store.apply(directory(session: UUID(), version: 1, endpoints: [endpoint("a")]), from: peer)
        // UI 據此顯示「—」並停用滑桿。給一個猜測值會讓使用者第一次碰它
        // 就把對方的螢幕調到一個沒人要的亮度。
        #expect(store.displayValue(endpointID("a"), .brightness) == nil)
    }

    @Test("拖曳中顯示待套用值，確認後換成對方回報的值")
    func optimisticThenConfirmed() {
        let store = RemoteDeviceStore()
        store.apply(directory(session: UUID(), version: 1, endpoints: [endpoint("a", value: 0.3)]), from: peer)
        let id = UUID()
        store.commandSent(id: id, endpoint: endpointID("a"), capability: .brightness, value: 0.8) { _ in }
        #expect(store.displayValue(endpointID("a"), .brightness) == 0.8)

        // 硬體量化之後不是 0.8 而是 0.79——最終以對方回報為準
        store.commandCompleted(EndpointCommandResult(id: id, outcome: .applied, value: 0.79))
        #expect(store.displayValue(endpointID("a"), .brightness) == 0.79)
        #expect(store.failure(endpointID("a"), .brightness) == nil)
    }

    @Test("指令到達時端點已拔掉 → 回復已確認值並說明，不退回控制別台")
    func unavailableRevertsAndExplains() {
        let store = RemoteDeviceStore()
        store.apply(directory(session: UUID(), version: 1, endpoints: [endpoint("a", value: 0.3)]), from: peer)
        let id = UUID()
        store.commandSent(id: id, endpoint: endpointID("a"), capability: .brightness, value: 0.8) { _ in }
        store.commandCompleted(EndpointCommandResult(id: id, outcome: .unavailable))
        #expect(store.displayValue(endpointID("a"), .brightness) == 0.3)
        #expect(store.failure(endpointID("a"), .brightness)?.isUnavailable == true)
    }

    @Test("逾時回復已確認值並留下說明")
    func timeoutReverts() {
        let store = RemoteDeviceStore()
        store.apply(directory(session: UUID(), version: 1, endpoints: [endpoint("a", value: 0.3)]), from: peer)
        let id = UUID()
        store.commandSent(id: id, endpoint: endpointID("a"), capability: .brightness, value: 0.8) { _ in }
        store.commandTimedOut(id)
        #expect(store.displayValue(endpointID("a"), .brightness) == 0.3)
        #expect(store.failure(endpointID("a"), .brightness)?.isUnavailable == false)
    }

    @Test("不認得的指令結果不影響任何東西")
    func unknownResultIgnored() {
        let store = RemoteDeviceStore()
        #expect(!store.commandCompleted(EndpointCommandResult(id: UUID(), outcome: .applied, value: 1)))
    }

    // MARK: - 端到端

    /// 一次完整的來回：送出端把目錄與回報丟進佇列 → 編碼 → 解碼 → 接收端套用。
    ///
    /// 這個測試防的是這次改動最容易出現、而且**最難察覺**的失敗：接收端把
    /// 一筆合法的變化靜靜丟掉。前面幾個測試各自檢查一條規則，但規則之間
    /// （佇列的合併順序、線上編碼、版本守門）也可能互相打架，
    /// 只有真的跑一次才看得出來。
    @Test("目錄與回報經佇列與編碼往返後，值真的落進接收端")
    func endToEndValueLands() throws {
        let session = UUID()
        var outbox = PeerOutbox()

        func enqueue(_ message: SyncMessage) throws {
            let envelope = Envelope(msg: message)
            let size = try EnvelopeCoding.encode(envelope).count
            #expect(outbox.enqueue(envelope, size: size) != .overflow)
        }

        try enqueue(.deviceDirectory(directory(
            session: session, version: 1, endpoints: [endpoint("a", value: 0.3)]
        )))
        // 拖曳中的一連串中間值：佇列會併成最後一筆
        for value in [0.4, 0.5, 0.62] {
            try enqueue(.endpointState(EndpointStateUpdate(
                sessionID: session, version: 1, deviceID: "a",
                kind: .display, capability: .brightness, value: value
            )))
        }

        let store = RemoteDeviceStore()
        var delivered = 0
        while let envelope = outbox.dequeue() {
            let data = try EnvelopeCoding.encode(envelope)
            guard case let .success(decoded) = EnvelopeCoding.decode(data) else {
                Issue.record("解碼失敗")
                return
            }
            switch decoded.msg {
            case let .deviceDirectory(directory):
                #expect(store.apply(directory, from: peer))
            case let .endpointState(update):
                #expect(store.apply(update, from: peer))
            default:
                Issue.record("不該出現的訊息")
            }
            delivered += 1
        }
        // 目錄一則 ＋ 合併後的回報一則
        #expect(delivered == 2)
        #expect(store.displayValue(endpointID("a"), .brightness) == 0.62)
    }

    // MARK: - 斷線

    @Test("斷線後立刻從操作介面消失，待套用值與錯誤一併清掉")
    func disconnectClearsEverything() {
        let store = RemoteDeviceStore()
        store.apply(directory(session: UUID(), version: 1, endpoints: [endpoint("a", value: 0.3)]), from: peer)
        let id = UUID()
        store.commandSent(id: id, endpoint: endpointID("a"), capability: .brightness, value: 0.8) { _ in }

        store.clear(peerID: peer)
        #expect(store.endpoints(of: peer, kind: .display).isEmpty)
        #expect(store.displayValue(endpointID("a"), .brightness) == nil)
        #expect(store.failure(endpointID("a"), .brightness) == nil)
        // 斷線期間作廢的指令，結果回來時已經沒有人認得它
        #expect(!store.commandCompleted(EndpointCommandResult(id: id, outcome: .applied, value: 0.8)))
    }

    @Test("清掉一台不影響另一台")
    func clearIsScopedToOnePeer() {
        let store = RemoteDeviceStore()
        store.apply(directory(session: UUID(), version: 1, endpoints: [endpoint("a")]), from: peer)
        let other = DeviceDirectory(
            peerID: "peer-2", sessionID: UUID(), version: 1, endpoints: [endpoint("z")]
        )
        store.apply(other, from: "peer-2")

        store.clear(peerID: peer)
        #expect(store.endpoints(of: peer, kind: .display).isEmpty)
        #expect(store.endpoints(of: "peer-2", kind: .display).map(\.deviceID) == ["z"])
    }
}

@Suite("本機端點目錄")
struct LocalDeviceDirectoryTests {
    private func display(_ uuid: String, name: String, brightness: Double = 0.5) -> LocalDeviceDirectory.DisplayInput {
        .init(uuid: uuid, name: name, isBuiltin: false, brightness: brightness, offset: 0)
    }

    private func audio(
        _ uid: String,
        name: String,
        canControlVolume: Bool = true,
        canMute: Bool = true,
        linkedDisplayUUID: String? = nil
    ) -> LocalDeviceDirectory.AudioInput {
        .init(
            uid: uid, name: name, canControlVolume: canControlVolume, canMute: canMute,
            volume: 0.4, muted: false, linkedDisplayUUID: linkedDisplayUUID, isDefaultOutput: false
        )
    }

    @Test("螢幕帶亮度與差異值兩項能力，現值一併帶上")
    func displayEndpoints() {
        let endpoints = LocalDeviceDirectory.endpoints(
            displays: [display("u1", name: "Studio Display", brightness: 0.7)],
            audio: []
        )
        #expect(endpoints.count == 1)
        #expect(endpoints[0].supports(.brightness))
        #expect(endpoints[0].supports(.brightnessOffset))
        #expect(endpoints[0].value(.brightness) == 0.7)
        #expect(endpoints[0].value(.brightnessOffset) == 0)
    }

    @Test("不可控的裝置照樣列出，只是能力清單是空的")
    func uncontrollableStillListed() {
        let endpoints = LocalDeviceDirectory.endpoints(
            displays: [],
            audio: [audio("a1", name: "HDMI", canControlVolume: false, canMute: false)]
        )
        // 不列的話，遠端那頭會以為它被拔掉了——「在，但動不了」是不同的事
        #expect(endpoints.count == 1)
        #expect(endpoints[0].capabilities.isEmpty)
        #expect(endpoints[0].value(.volume) == nil)
    }

    @Test("同型號的兩台螢幕各自帶區別後綴，不撞名的不帶")
    func duplicateNamesGetDiscriminators() {
        let endpoints = LocalDeviceDirectory.endpoints(
            displays: [
                display("uuid-aaa111", name: "LG UltraFine"),
                display("uuid-bbb222", name: "LG UltraFine"),
                display("uuid-ccc333", name: "Studio Display"),
            ],
            audio: []
        )
        #expect(endpoints[0].discriminator == "uuid-a")
        #expect(endpoints[1].discriminator == "uuid-b")
        #expect(endpoints[2].discriminator == nil)
    }

    @Test("螢幕音訊帶得出所屬螢幕，好歸到「螢幕」分類")
    func audioCarriesLinkedDisplay() {
        let endpoints = LocalDeviceDirectory.endpoints(
            displays: [display("u1", name: "Studio Display")],
            audio: [
                audio("a1", name: "Studio Display 喇叭", linkedDisplayUUID: "u1"),
                audio("a2", name: "MacBook Pro 喇叭"),
            ]
        )
        let screen = endpoints.first { $0.deviceID == "a1" }
        let builtin = endpoints.first { $0.deviceID == "a2" }
        #expect(screen?.linkedDisplayUUID == "u1")
        #expect(builtin?.linkedDisplayUUID == nil)
        #expect(ControlGrouping.group(isScreenAudioEndpoint: screen?.linkedDisplayUUID != nil) == .screen)
        #expect(ControlGrouping.group(isScreenAudioEndpoint: builtin?.linkedDisplayUUID != nil) == .device)
    }

    @Test("顯示器與音訊的識別碼一樣時不會互相蓋掉")
    func sameIDDifferentKindsCoexist() {
        // 完整索引含類型，正是為了這件事
        let endpoints = LocalDeviceDirectory.endpoints(
            displays: [display("same", name: "螢幕")],
            audio: [audio("same", name: "喇叭")]
        )
        #expect(endpoints.count == 2)
        #expect(endpoints.filter { $0.kind == .display }.count == 1)
        #expect(endpoints.filter { $0.kind == .audioOutput }.count == 1)
    }
}
