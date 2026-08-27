import Foundation
import Testing
@testable import ChorusCore

@Suite("Ambient sync core")
struct AmbientSyncCoreTests {
    private func report(from origin: String, lux: Double, wallMicros: Int64, counter: UInt32 = 0) -> AmbientReport {
        AmbientReport(
            originID: origin,
            hlc: HLCTimestamp(wallMicros: wallMicros, counter: counter, peerID: origin),
            lux: lux
        )
    }

    @Test("Local sample makes self the baseline source")
    func localSampleIsSource() {
        var core = AmbientSyncCore(localPeerID: "A")
        core.hasLocalSensor = true
        let outgoing = core.localSample(lux: 400, wallNowMicros: 1_000_000)
        #expect(outgoing.originID == "A")
        #expect(outgoing.lux == 400)
        let baseline = core.currentBaseline()
        #expect(baseline?.lux == 400)
        #expect(baseline?.sourceID == "A")
    }

    @Test("Device with local sensor stores remote reports but never follows them")
    func localSensorWins() {
        var core = AmbientSyncCore(localPeerID: "A")
        core.hasLocalSensor = true
        _ = core.localSample(lux: 400, wallNowMicros: 1_000_000)
        let effects = core.receive(report(from: "B", lux: 900, wallMicros: 2_000_000), wallNowMicros: 2_000_000)
        #expect(effects.isEmpty)
        #expect(core.currentBaseline()?.sourceID == "A")
    }

    @Test("Sensor-less follower adopts the first reporter and stays sticky")
    func stickySource() {
        var core = AmbientSyncCore(localPeerID: "C")
        let first = core.receive(report(from: "A", lux: 300, wallMicros: 1_000_000), wallNowMicros: 1_000_000)
        #expect(first == [.followBaseline(lux: 300, sourceID: "A")])
        // 第二個來源出現 → 只存不跟
        let second = core.receive(report(from: "B", lux: 800, wallMicros: 2_000_000), wallNowMicros: 2_000_000)
        #expect(second.isEmpty)
        #expect(core.currentBaseline()?.sourceID == "A")
        // 目前來源的新回報照常跟隨
        let update = core.receive(report(from: "A", lux: 350, wallMicros: 3_000_000), wallNowMicros: 3_000_000)
        #expect(update == [.followBaseline(lux: 350, sourceID: "A")])
    }

    @Test("Stale or reordered reports from the same origin are dropped")
    func hlcDropsStale() {
        var core = AmbientSyncCore(localPeerID: "C")
        _ = core.receive(report(from: "A", lux: 300, wallMicros: 5_000_000), wallNowMicros: 5_000_000)
        let replay = core.receive(report(from: "A", lux: 999, wallMicros: 4_000_000), wallNowMicros: 5_100_000)
        #expect(replay.isEmpty)
        #expect(core.currentBaseline()?.lux == 300)
    }

    @Test("Own report echoed back is ignored")
    func ownEchoIgnored() {
        var core = AmbientSyncCore(localPeerID: "A")
        let effects = core.receive(report(from: "A", lux: 100, wallMicros: 1_000_000), wallNowMicros: 1_000_000)
        #expect(effects.isEmpty)
    }

    @Test("Tick fails over to the freshest other reporter after the source goes stale")
    func staleFailover() {
        var core = AmbientSyncCore(localPeerID: "C")
        _ = core.receive(report(from: "A", lux: 300, wallMicros: 0), wallNowMicros: 0)
        _ = core.receive(report(from: "B", lux: 800, wallMicros: 40_000_000), wallNowMicros: 40_000_000)
        // 50 秒時 A 已靜默 50 秒（> 45s）、B 才 10 秒 → 改跟 B
        let effects = core.tick(wallNowMicros: 50_000_000)
        #expect(effects == [.followBaseline(lux: 800, sourceID: "B")])
        #expect(core.currentBaseline()?.sourceID == "B")
    }

    @Test("Keepalive from the current source prevents failover")
    func keepaliveRefreshes() {
        var core = AmbientSyncCore(localPeerID: "C")
        _ = core.receive(report(from: "A", lux: 300, wallMicros: 0), wallNowMicros: 0)
        _ = core.receive(report(from: "B", lux: 800, wallMicros: 1_000_000), wallNowMicros: 1_000_000)
        // A 在 30 秒時 keepalive（lux 未變、hlc 前進）
        _ = core.receive(report(from: "A", lux: 300, wallMicros: 30_000_000), wallNowMicros: 30_000_000)
        let effects = core.tick(wallNowMicros: 50_000_000)
        #expect(effects.isEmpty)
        #expect(core.currentBaseline()?.sourceID == "A")
    }

    @Test("Tick with no live candidates clears the baseline")
    func staleWithoutCandidates() {
        var core = AmbientSyncCore(localPeerID: "C")
        _ = core.receive(report(from: "A", lux: 300, wallMicros: 0), wallNowMicros: 0)
        let effects = core.tick(wallNowMicros: 50_000_000)
        #expect(effects.isEmpty)
        #expect(core.currentBaseline() == nil)
    }

    @Test("Forgetting a disconnected source fails over immediately")
    func forgetOriginFailover() {
        var core = AmbientSyncCore(localPeerID: "C")
        _ = core.receive(report(from: "A", lux: 300, wallMicros: 0), wallNowMicros: 0)
        _ = core.receive(report(from: "B", lux: 800, wallMicros: 1_000_000), wallNowMicros: 1_000_000)
        let effects = core.forgetOrigin("A", wallNowMicros: 2_000_000)
        #expect(effects == [.followBaseline(lux: 800, sourceID: "B")])
        // 忘掉非目前來源 → 無效果
        var other = AmbientSyncCore(localPeerID: "C")
        _ = other.receive(report(from: "A", lux: 300, wallMicros: 0), wallNowMicros: 0)
        #expect(other.forgetOrigin("B", wallNowMicros: 1_000_000).isEmpty)
    }

    @Test("Two followers fed the same reports converge on the same source")
    func followersConverge() {
        var followerOne = AmbientSyncCore(localPeerID: "C")
        var followerTwo = AmbientSyncCore(localPeerID: "D")
        let reports = [
            report(from: "A", lux: 300, wallMicros: 1_000_000),
            report(from: "B", lux: 800, wallMicros: 2_000_000),
            report(from: "A", lux: 350, wallMicros: 3_000_000),
        ]
        for incoming in reports {
            _ = followerOne.receive(incoming, wallNowMicros: incoming.hlc.wallMicros)
            _ = followerTwo.receive(incoming, wallNowMicros: incoming.hlc.wallMicros)
        }
        #expect(followerOne.currentBaseline()?.sourceID == followerTwo.currentBaseline()?.sourceID)
        #expect(followerOne.currentBaseline()?.lux == 350)
    }
}
