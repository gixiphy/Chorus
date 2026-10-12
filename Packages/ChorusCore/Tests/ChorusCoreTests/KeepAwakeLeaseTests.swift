import Foundation
import Testing
@testable import ChorusCore

@Suite("KeepAwakeLeaseTable")
struct KeepAwakeLeaseTests {
    @Test(
        "V-C01-2 id validation",
        arguments: [
            ("build-bot", true),
            ("A.z_0-9", true),
            ("a", true),
            (String(repeating: "x", count: 64), true),
            ("", false),
            (String(repeating: "x", count: 65), false),
            ("has space", false),
            ("has/slash", false),
            ("中文", false),
            ("bad!", false),
        ] as [(String, Bool)]
    )
    func idValidation(id: String, expected: Bool) {
        #expect(KeepAwakeLeaseTable.isValidID(id) == expected)
    }

    @Test("V-C01-2 TTL default 600; 10 clamps to 30; 99999 clamps to 3600")
    func ttlClamp() {
        var table = KeepAwakeLeaseTable()
        let now = 1000.0

        if case let .held(_, ttl) = table.hold(id: "a", ttl: nil, now: now) {
            #expect(ttl == 600)
        } else {
            Issue.record("expected held")
        }

        if case let .held(_, ttl) = table.hold(id: "b", ttl: 10, now: now) {
            #expect(ttl == 30)
        } else {
            Issue.record("expected held")
        }

        if case let .held(_, ttl) = table.hold(id: "c", ttl: 99_999, now: now) {
            #expect(ttl == 3600)
        } else {
            Issue.record("expected held")
        }
    }

    @Test("V-C01-2 non-finite TTL rejected")
    func invalidTTL() {
        var table = KeepAwakeLeaseTable()
        let nan = table.hold(id: "a", ttl: .nan, now: 0)
        #expect(nan == .invalidTTL)
        let inf = table.hold(id: "a", ttl: .infinity, now: 0)
        #expect(inf == .invalidTTL)
    }

    @Test("V-C01-2 33rd lease returns tooMany; renew at cap still ok")
    func maxLeases() {
        var table = KeepAwakeLeaseTable()
        let now = 0.0
        for i in 0..<32 {
            let result = table.hold(id: "id-\(i)", ttl: 60, now: now)
            guard case .held = result else {
                Issue.record("lease \(i) should hold")
                return
            }
        }
        let tooMany = table.hold(id: "id-33", ttl: 60, now: now)
        #expect(tooMany == .tooMany)
        // 同 id 續約在上限時仍可成功
        guard case let .held(expires, _) = table.hold(id: "id-0", ttl: 120, now: now + 10) else {
            Issue.record("renewal should succeed")
            return
        }
        #expect(expires == now + 10 + 120)
    }

    @Test("V-C01-2 same id renew extends expiry")
    func renewExtends() {
        var table = KeepAwakeLeaseTable()
        _ = table.hold(id: "bot", ttl: 60, now: 100)
        guard case let .held(expires, _) = table.hold(id: "bot", ttl: 60, now: 150) else {
            Issue.record("expected held")
            return
        }
        #expect(expires == 210)
        #expect(table.active(now: 150).count == 1)
        #expect(table.active(now: 150).first?.firstHeldAt == 100)
    }

    @Test("V-C01-2 release missing id returns false; does not create tombstone")
    func releaseMissing() {
        var table = KeepAwakeLeaseTable()
        let first = table.release(id: "nope", now: 10)
        #expect(!first)
        #expect(table.tombstones.isEmpty)
        let second = table.release(id: "nope", now: 20)
        #expect(!second)
        #expect(table.tombstones.isEmpty)
    }

    @Test("V-C01-2 / V-C01-4 release creates tombstone; duplicate release does not extend grace")
    func releaseTombstone() {
        var table = KeepAwakeLeaseTable()
        _ = table.hold(id: "bot", ttl: 100, now: 0)
        let released = table.release(id: "bot", now: 40)
        #expect(released)
        #expect(table.tombstones["bot"]?.lastWorkingAt == 40)
        let again = table.release(id: "bot", now: 50)
        #expect(!again)
        #expect(table.tombstones["bot"]?.lastWorkingAt == 40)
    }

    @Test("V-C01-2 purgeExpired only removes expired; keeps grace tombstones")
    func purgeExpired() {
        var table = KeepAwakeLeaseTable()
        _ = table.hold(id: "alive", ttl: 100, now: 0)
        _ = table.hold(id: "dead", ttl: 50, now: 0)

        let purged = table.purgeExpired(now: 60, graceSeconds: 300)
        #expect(purged.contains("dead"))
        #expect(table.active(now: 60).map(\.id) == ["alive"])
        #expect(table.tombstones["dead"]?.lastWorkingAt == 50)

        // grace 未到：tombstone 仍在
        _ = table.purgeExpired(now: 50 + 299, graceSeconds: 300)
        #expect(table.tombstones["dead"] != nil)

        // grace 到期後移除
        _ = table.purgeExpired(now: 50 + 300, graceSeconds: 300)
        #expect(table.tombstones["dead"] == nil)
    }

    @Test("V-C01-4 storage stays bounded after many release/renew cycles")
    func storageBounded() {
        var table = KeepAwakeLeaseTable()
        for i in 0..<32 {
            _ = table.hold(id: "a-\(i)", ttl: 30, now: 0)
        }
        for i in 0..<200 {
            _ = table.release(id: "a-\(i % 32)", now: Double(i + 1))
            _ = table.hold(id: "a-\(i % 32)", ttl: 30, now: Double(i + 2))
            _ = table.purgeExpired(now: Double(i + 2), graceSeconds: 300)
        }
        #expect(table.storageCount <= KeepAwakeLeaseTable.maxLeases * 2 + 1)
    }

    @Test("W0-7 thousands of distinct IDs stay bounded; grace evidence survives")
    func distinctIDChurnBoundedWithGrace() {
        var table = KeepAwakeLeaseTable()
        let grace = 300.0
        var latestRelease: Double = 0
        for i in 0..<1000 {
            let id = "uniq-\(i)"
            let t = Double(i)
            let held = table.hold(id: id, ttl: 60, now: t)
            #expect(held == .held(expiresAt: t + 60, clampedTTL: 60))
            let released = table.release(id: id, now: t + 1)
            #expect(released)
            latestRelease = t + 1
            #expect(table.storageCount <= KeepAwakeLeaseTable.maxLeases + 1)
        }
        // 未 purge：個別 tombstone ≤ 32，其餘在 aggregate；最新證據仍在 grace 內
        #expect(table.tombstones.count <= KeepAwakeLeaseTable.maxLeases)
        #expect(table.aggregateGrace != nil)
        let evidence = table.graceEvidenceTimes(now: latestRelease, graceSeconds: grace)
        #expect(!evidence.isEmpty)
        #expect(evidence.max() == latestRelease)

        // purge 不得提早刪仍在 grace 的證據
        _ = table.purgeExpired(now: latestRelease + 1, graceSeconds: grace)
        #expect(table.graceEvidenceTimes(now: latestRelease + 1, graceSeconds: grace).max() == latestRelease)

        // 32 live → 全 release → 32 tombstone；再 churn 摺入 aggregate，grace 證據仍在
        var live = KeepAwakeLeaseTable()
        for i in 0..<32 {
            _ = live.hold(id: "live-\(i)", ttl: 600, now: 0)
        }
        for i in 0..<32 {
            _ = live.release(id: "live-\(i)", now: 10)
        }
        #expect(live.tombstones.count == 32)
        #expect(live.storageCount == 32)
        for i in 0..<10 {
            let id = "more-\(i)"
            _ = live.hold(id: id, ttl: 60, now: 20)
            _ = live.release(id: id, now: 21)
        }
        #expect(live.storageCount <= KeepAwakeLeaseTable.maxLeases + 1)
        #expect(live.aggregateGrace?.lastWorkingAt == 21)
        _ = live.purgeExpired(now: 21 + 299, graceSeconds: grace)
        #expect(live.graceEvidenceTimes(now: 21 + 299, graceSeconds: grace).max() == 21)
    }

    @Test("V-C01-2 invalid id on hold")
    func holdInvalidID() {
        var table = KeepAwakeLeaseTable()
        let empty = table.hold(id: "", ttl: 60, now: 0)
        #expect(empty == .invalidID)
        let slash = table.hold(id: "bad/id", ttl: 60, now: 0)
        #expect(slash == .invalidID)
    }
}

@Suite("KeepAwakeLease Codable wire")
struct KeepAwakeLeaseCodableTests {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    @Test("V-C01-3 HoldRequest round-trip and fixed JSON")
    func holdRequest() throws {
        let value = KeepAwakeHoldRequest(id: "build-bot", ttl: 600)
        let data = try encoder.encode(value)
        #expect(String(data: data, encoding: .utf8) == #"{"id":"build-bot","ttl":600}"#)
        #expect(try decoder.decode(KeepAwakeHoldRequest.self, from: data) == value)

        let omitTTL = #"{"id":"x"}"#.data(using: .utf8)!
        let decoded = try decoder.decode(KeepAwakeHoldRequest.self, from: omitTTL)
        #expect(decoded.id == "x")
        #expect(decoded.ttl == nil)
    }

    @Test("V-C01-3 HoldResponse round-trip and fixed JSON")
    func holdResponse() throws {
        let value = KeepAwakeHoldResponse(
            id: "build-bot",
            expiresIn: 600,
            ttl: 600,
            assertionEffective: true,
            lidEffective: false,
            reason: "lidGuardOff"
        )
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == #"{"assertionEffective":true,"effective":true,"expiresIn":600,"id":"build-bot","lidEffective":false,"reason":"lidGuardOff","ttl":600}"#)
        #expect(try decoder.decode(KeepAwakeHoldResponse.self, from: data) == value)
    }

    @Test("V-C01-3 ReleaseRequest/Response round-trip and fixed JSON")
    func releaseRoundTrip() throws {
        let req = KeepAwakeReleaseRequest(id: "build-bot")
        let reqData = try encoder.encode(req)
        #expect(String(data: reqData, encoding: .utf8) == #"{"id":"build-bot"}"#)

        let res = KeepAwakeReleaseResponse(id: "build-bot", released: true)
        let resData = try encoder.encode(res)
        #expect(String(data: resData, encoding: .utf8) == #"{"id":"build-bot","released":true}"#)
        #expect(try decoder.decode(KeepAwakeReleaseResponse.self, from: resData) == res)
    }

    @Test("V-C01-3 / W0-10 StatusResponse full canonical JSON round-trip")
    func statusResponse() throws {
        // 獨立固定 fixture（secondsSince1970）；含 source kind/name/working/timestamp/health
        // 與 optional 欄位出現／缺席鎖定。
        let fixture = """
        {"assertionEffective":true,"contributing":[{"detail":"剩 10 分","displayName":"build-bot","health":{"kind":"ok"},"id":"lease:build-bot","isWorkingNow":true,"kind":"lease","lastWorkingAt":1700000000}],"helper":{"availability":"ready","callerIsHolder":true,"holderCount":1,"otherUsersHolding":false,"setByHelper":true,"sleepDisabled":true},"isHolding":true,"leases":[{"expiresIn":600,"id":"build-bot","ttl":600}],"lidEffective":true,"lidPhase":"armed","mode":"whileAgentsWorking"}
        """.data(using: .utf8)!

        let decoded = try decoder.decode(KeepAwakeStatusResponse.self, from: fixture)
        #expect(decoded.mode == "whileAgentsWorking")
        #expect(decoded.isHolding)
        #expect(decoded.lidPhase == "armed")
        #expect(decoded.assertionEffective)
        #expect(decoded.lidEffective)
        #expect(decoded.leases == [KeepAwakeLeaseStatusDTO(id: "build-bot", expiresIn: 600, ttl: 600)])
        #expect(decoded.helper?.availability == "ready")
        #expect(decoded.helper?.sleepDisabled == true)
        #expect(decoded.helper?.setByHelper == true)
        #expect(decoded.helper?.holderCount == 1)
        #expect(decoded.helper?.callerIsHolder == true)
        #expect(decoded.helper?.otherUsersHolding == false)
        #expect(decoded.helper?.lastForcedOffReason == nil)

        #expect(decoded.contributing.count == 1)
        let source = decoded.contributing[0]
        #expect(source.id == "lease:build-bot")
        #expect(source.kind == .lease)
        #expect(source.displayName == "build-bot")
        #expect(source.detail == "剩 10 分")
        #expect(source.isWorkingNow)
        #expect(source.lastWorkingAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(source.health == .ok)

        let encoded = try encoder.encode(decoded)
        #expect(encoded == fixture)

        // optional 缺席：無 lidPhase／helper／detail／lastWorkingAt
        let sparseFixture = """
        {"assertionEffective":false,"contributing":[{"displayName":"agents","health":{"kind":"ok"},"id":"agents","isWorkingNow":false,"kind":"agentActivity"},{"displayName":"orca","health":{"kind":"degraded","reason":"timeout"},"id":"orca","isWorkingNow":false,"kind":"orca"}],"isHolding":false,"leases":[],"lidEffective":false,"mode":"off"}
        """.data(using: .utf8)!
        let sparse = try decoder.decode(KeepAwakeStatusResponse.self, from: sparseFixture)
        #expect(sparse.lidPhase == nil)
        #expect(sparse.helper == nil)
        #expect(sparse.contributing[0].detail == nil)
        #expect(sparse.contributing[0].lastWorkingAt == nil)
        #expect(sparse.contributing[1].health == .degraded(reason: "timeout"))
        #expect(try encoder.encode(sparse) == sparseFixture)
    }

    @Test("W0-10 ReleaseRequest round-trip is explicit")
    func releaseRequestRoundTrip() throws {
        let req = KeepAwakeReleaseRequest(id: "build-bot")
        let data = try encoder.encode(req)
        #expect(String(data: data, encoding: .utf8) == #"{"id":"build-bot"}"#)
        #expect(try decoder.decode(KeepAwakeReleaseRequest.self, from: data) == req)
    }

    @Test("V-C01-3 KeepAwakeSourceHealth Codable round-trip")
    func healthCodable() throws {
        let cases: [KeepAwakeSourceHealth] = [
            .ok,
            .degraded(reason: "CLI failed"),
            .unavailable(reason: "missing"),
        ]
        for value in cases {
            let data = try encoder.encode(value)
            #expect(try decoder.decode(KeepAwakeSourceHealth.self, from: data) == value)
        }
    }

    @Test("W0-10 HoldResponse wire requires Fi A4 fields; old JSON without them fails")
    func holdResponseWireContract() throws {
        // Fi A4：assertionEffective／lidEffective 為必填 wire 欄位；不支援舊版缺欄解碼。
        let mirror = Mirror(reflecting: KeepAwakeHoldResponse(
            id: "x", expiresIn: 1, ttl: 1,
            assertionEffective: false, lidEffective: false
        ))
        let labels = Set(mirror.children.compactMap(\.label))
        #expect(labels.contains("assertionEffective"))
        #expect(labels.contains("lidEffective"))
        #expect(labels.contains("effective"))

        let legacy = """
        {"id":"build-bot","expiresIn":600,"ttl":600,"effective":true}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try decoder.decode(KeepAwakeHoldResponse.self, from: legacy)
        }
    }
}
