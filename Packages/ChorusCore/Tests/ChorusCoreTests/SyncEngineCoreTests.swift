import Testing
@testable import ChorusCore

@Suite("SyncEngineCore")
struct SyncEngineCoreTests {
    let key = ControlKey.brightness(displayUUID: nil)

    @Test("Local change produces broadcast with increasing seq")
    func localChangeSeq() {
        var engine = SyncEngineCore(localPeerID: "A")
        let first = engine.localChange(key: key, value: 0.4, wallNowMicros: 1000)
        let second = engine.localChange(key: key, value: 0.5, wallNowMicros: 2000)
        #expect(first.originID == "A")
        #expect(second.seq > first.seq)
        #expect(second.hlc > first.hlc)
    }

    @Test("Remote update is applied and never re-broadcast")
    func receiveApplies() {
        var a = SyncEngineCore(localPeerID: "A")
        var b = SyncEngineCore(localPeerID: "B")
        let update = a.localChange(key: key, value: 0.7, wallNowMicros: 1000)
        let effects = b.receive(update, wallNowMicros: 1100)
        #expect(effects == [.applyToHardware(key: key, value: 0.7)])
        #expect(b.currentValue(for: key) == 0.7)
    }

    @Test("Duplicate delivery is dropped")
    func duplicateDropped() {
        var a = SyncEngineCore(localPeerID: "A")
        var b = SyncEngineCore(localPeerID: "B")
        let update = a.localChange(key: key, value: 0.7, wallNowMicros: 1000)
        _ = b.receive(update, wallNowMicros: 1100)
        #expect(b.receive(update, wallNowMicros: 1200).isEmpty)
    }

    @Test("Own-origin update bounced back is dropped")
    func ownOriginDropped() {
        var a = SyncEngineCore(localPeerID: "A")
        let update = a.localChange(key: key, value: 0.7, wallNowMicros: 1000)
        #expect(a.receive(update, wallNowMicros: 1100).isEmpty)
    }

    @Test("Older HLC loses to newer local value (LWW)")
    func olderRemoteLoses() {
        var a = SyncEngineCore(localPeerID: "A")
        var b = SyncEngineCore(localPeerID: "B")
        let oldUpdate = a.localChange(key: key, value: 0.2, wallNowMicros: 1000)
        // B 在更晚的 wall time 做了本地變更
        _ = b.localChange(key: key, value: 0.9, wallNowMicros: 500_000)
        #expect(b.receive(oldUpdate, wallNowMicros: 500_100).isEmpty)
        #expect(b.currentValue(for: key) == 0.9)
    }

    @Test("Full state merge applies only newer entries")
    func fullStateMerge() {
        var a = SyncEngineCore(localPeerID: "A")
        var b = SyncEngineCore(localPeerID: "B")
        _ = a.localChange(key: key, value: 0.3, wallNowMicros: 1000)
        _ = b.localChange(key: key, value: 0.8, wallNowMicros: 900_000)
        let volumeKey = ControlKey.volume(deviceUID: nil)
        _ = a.localChange(key: volumeKey, value: 0.6, wallNowMicros: 2000)

        // B 收到 A 的快照：brightness 較舊被丟棄、volume 是新 key 被套用
        let effects = b.receiveFullState(a.fullStateSnapshot(), wallNowMicros: 900_100)
        #expect(effects == [.applyToHardware(key: volumeKey, value: 0.6)])
        #expect(b.currentValue(for: key) == 0.8)
        #expect(b.currentValue(for: volumeKey) == 0.6)
    }

    @Test("Receive effects never contain a broadcast (structural no-relay invariant)")
    func neverRebroadcast() {
        // Effect enum 本身只有 applyToHardware —— 這個測試鎖住這個結構性事實：
        // 任何未來把 broadcast 加進 receive 路徑的改動都必須先來改這裡。
        var a = SyncEngineCore(localPeerID: "A")
        var b = SyncEngineCore(localPeerID: "B")
        for step in 0..<50 {
            let update = a.localChange(key: key, value: Double(step) / 50, wallNowMicros: Int64(step) * 1000)
            for effect in b.receive(update, wallNowMicros: Int64(step) * 1000 + 500) {
                guard case .applyToHardware = effect else {
                    Issue.record("unexpected non-apply effect: \(effect)")
                    return
                }
            }
        }
    }
}
