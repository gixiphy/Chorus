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
        #expect(table.storageCount <= KeepAwakeLeaseTable.maxLeases * 2)
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
        return e
    }()

    private let decoder = JSONDecoder()

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

    @Test("V-C01-3 StatusResponse round-trip and fixed JSON")
    func statusResponse() throws {
        let value = KeepAwakeStatusResponse(
            mode: "whileAgentsWorking",
            isHolding: true,
            lidPhase: "armed",
            contributing: [
                KeepAwakeSourceReport(
                    id: "lease:build-bot",
                    kind: .lease,
                    displayName: "build-bot",
                    detail: "剩 10 分",
                    isWorkingNow: true,
                    lastWorkingAt: Date(timeIntervalSince1970: 1_700_000_000),
                    health: .ok
                )
            ],
            leases: [KeepAwakeLeaseStatusDTO(id: "build-bot", expiresIn: 600, ttl: 600)],
            helper: KeepAwakeHelperStatusDTO(
                availability: "ready",
                sleepDisabled: true,
                setByHelper: true,
                holderCount: 1,
                callerIsHolder: true
            ),
            assertionEffective: true,
            lidEffective: true
        )

        let data = try encoder.encode(value)
        let round = try decoder.decode(KeepAwakeStatusResponse.self, from: data)
        #expect(round == value)

        // 固定欄位存在，供 C09 對照（不鎖死整個 JSON 因 Date 編碼）。
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["mode"] as? String == "whileAgentsWorking")
        #expect(obj["assertionEffective"] as? Bool == true)
        #expect(obj["lidEffective"] as? Bool == true)
        #expect(obj["lidPhase"] as? String == "armed")
        #expect((obj["leases"] as? [[String: Any]])?.first?["id"] as? String == "build-bot")
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

    @Test("V-C01-3 old HoldResponse without new fields still decodes via defaults not required — encode includes them")
    func holdResponseHasFiFields() throws {
        // Fi A4: assertionEffective / lidEffective must be on the wire type.
        let mirror = Mirror(reflecting: KeepAwakeHoldResponse(
            id: "x", expiresIn: 1, ttl: 1,
            assertionEffective: false, lidEffective: false
        ))
        let labels = Set(mirror.children.compactMap(\.label))
        #expect(labels.contains("assertionEffective"))
        #expect(labels.contains("lidEffective"))
        #expect(labels.contains("effective"))
    }
}
