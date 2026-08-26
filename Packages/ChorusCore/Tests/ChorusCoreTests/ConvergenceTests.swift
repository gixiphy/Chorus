import Testing
@testable import ChorusCore

/// 種子化的線性同餘 RNG，讓收斂測試可重現。
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("Mesh convergence")
struct ConvergenceTests {
    @Test("Three engines converge under concurrent updates, clock skew, reordering and duplicates")
    func threeEngineConvergence() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        var engines = [
            SyncEngineCore(localPeerID: "A"),
            SyncEngineCore(localPeerID: "B"),
            SyncEngineCore(localPeerID: "C"),
        ]
        // 各節點 wall clock 偏移（模擬 NTP 漂移）
        let clockSkews: [Int64] = [0, -50_000, 120_000]
        let keys: [ControlKey] = [
            .brightness(displayUUID: nil),
            .volume(deviceUID: nil),
            .mute(deviceUID: nil),
        ]

        var pendingDeliveries: [(target: Int, update: StateUpdate)] = []
        var allUpdates: [StateUpdate] = []
        var wallBase: Int64 = 1_000_000

        for _ in 0..<200 {
            wallBase += Int64.random(in: 100...5000, using: &rng)
            let origin = Int.random(in: 0..<3, using: &rng)
            let key = keys[Int.random(in: 0..<keys.count, using: &rng)]
            let value = Double(Int.random(in: 0...100, using: &rng)) / 100

            let update = engines[origin].localChange(
                key: key, value: value, wallNowMicros: wallBase + clockSkews[origin]
            )
            allUpdates.append(update)
            // origin 直發另外兩台；30% 機率重複投遞一次
            for target in 0..<3 where target != origin {
                pendingDeliveries.append((target, update))
                if Int.random(in: 0..<10, using: &rng) < 3 {
                    pendingDeliveries.append((target, update))
                }
            }
        }

        // 打亂投遞順序（模擬三條 TCP 連線間的交錯）
        pendingDeliveries.shuffle(using: &rng)
        wallBase += 10_000
        for delivery in pendingDeliveries {
            let skew = clockSkews[delivery.target]
            _ = engines[delivery.target].receive(delivery.update, wallNowMicros: wallBase + skew)
            wallBase += 10
        }

        // 全部引擎對每個 key 收斂到同一值，且等於該 key HLC 最大的更新值
        for key in keys {
            let winner = allUpdates.filter { $0.key == key }.max { $0.hlc < $1.hlc }
            let expected = winner?.value
            for (index, engine) in engines.enumerated() {
                #expect(
                    engine.currentValue(for: key) == expected,
                    "engine \(index) diverged on \(key)"
                )
            }
        }
    }

    @Test("Two engines exchange over InMemoryTransport and converge")
    func transportRoundTrip() async throws {
        let (transportA, transportB) = InMemoryTransport.pair()
        var engineA = SyncEngineCore(localPeerID: "A")
        var engineB = SyncEngineCore(localPeerID: "B")
        let key = ControlKey.brightness(displayUUID: nil)

        // A 發出三筆更新（經過真實 Envelope 編解碼）
        for (index, value) in [0.2, 0.5, 0.8].enumerated() {
            let update = engineA.localChange(key: key, value: value, wallNowMicros: Int64(index + 1) * 1000)
            try await transportA.send(Envelope(msg: .stateUpdate(update)))
        }
        transportA.close()

        for await envelope in transportB.incoming {
            if case let .stateUpdate(update) = envelope.msg {
                _ = engineB.receive(update, wallNowMicros: 10_000)
            }
        }
        #expect(engineB.currentValue(for: key) == 0.8)
    }
}
