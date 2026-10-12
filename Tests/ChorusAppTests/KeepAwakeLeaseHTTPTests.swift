import ChorusCore
import Foundation
import Testing
@testable import Chorus

@Suite("Keepawake HTTP routes (V-C09-1)")
struct KeepAwakeLeaseHTTPTests {
    private func makeLeaseHandlers(
        table: KeepAwakeLeaseTable = KeepAwakeLeaseTable(),
        now: Double = 1_000,
        assertionEffective: Bool = true,
        lidEffective: Bool = false,
        reason: String? = nil
    ) -> (AutomationHTTPTransport.Handlers, Box<KeepAwakeLeaseTable>) {
        let box = Box(table)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let handlers = AutomationHTTPTransport.Handlers(
            state: { .init(status: 200, json: #"{"ok":true}"#) },
            scenes: { .init(status: 200, json: "[]") },
            doctor: { .init(status: 200, json: #"{"ok":true}"#) },
            execute: { _, _ in .init(status: 200, json: #"{"ok":true}"#) },
            eventStreamsActive: { _ in },
            keepAwakeHold: { body in
                let request: KeepAwakeHoldRequest
                do {
                    request = try decoder.decode(KeepAwakeHoldRequest.self, from: body)
                } catch {
                    return .init(
                        status: 400,
                        json: AutomationHTTPTransport.errorJSON("badRequest", "無法解析 hold 請求")
                    )
                }
                let result = box.value.hold(id: request.id, ttl: request.ttl, now: now)
                switch result {
                case let .held(expiresAt, clampedTTL):
                    let response = KeepAwakeHoldResponse(
                        id: request.id,
                        expiresIn: expiresAt - now,
                        ttl: clampedTTL,
                        assertionEffective: assertionEffective,
                        lidEffective: lidEffective,
                        reason: reason
                    )
                    let data = (try? encoder.encode(response)) ?? Data("{}".utf8)
                    return .init(status: 200, json: String(decoding: data, as: UTF8.self))
                case .invalidID, .invalidTTL:
                    return .init(
                        status: 400,
                        json: AutomationHTTPTransport.errorJSON("badRequest", "id 或 ttl 不合法")
                    )
                case .tooMany:
                    return .init(
                        status: 429,
                        json: AutomationHTTPTransport.errorJSON("tooManyLeases", "租約數已達上限")
                    )
                }
            },
            keepAwakeRelease: { body in
                let request: KeepAwakeReleaseRequest
                do {
                    request = try decoder.decode(KeepAwakeReleaseRequest.self, from: body)
                } catch {
                    return .init(
                        status: 400,
                        json: AutomationHTTPTransport.errorJSON("badRequest", "無法解析 release 請求")
                    )
                }
                let released = box.value.release(id: request.id, now: now)
                let response = KeepAwakeReleaseResponse(id: request.id, released: released)
                let data = (try? encoder.encode(response)) ?? Data("{}".utf8)
                return .init(status: 200, json: String(decoding: data, as: UTF8.self))
            },
            keepAwakeStatus: {
                let leases = box.value.active(now: now).map {
                    KeepAwakeLeaseStatusDTO(id: $0.id, expiresIn: $0.expiresAt - now, ttl: $0.ttl)
                }
                let response = KeepAwakeStatusResponse(
                    mode: "agent",
                    isHolding: !leases.isEmpty,
                    lidPhase: "idle",
                    leases: leases,
                    assertionEffective: assertionEffective,
                    lidEffective: lidEffective
                )
                let data = (try? encoder.encode(response)) ?? Data("{}".utf8)
                return .init(status: 200, json: String(decoding: data, as: UTF8.self))
            }
        )
        return (handlers, box)
    }

    @Test("default handlers return 503")
    func defaultUnavailable() async {
        let handlers = AutomationHTTPTransport.Handlers(
            state: { .init(status: 200, json: "{}") },
            scenes: { .init(status: 200, json: "[]") },
            doctor: { .init(status: 200, json: "{}") },
            execute: { _, _ in .init(status: 200, json: "{}") },
            eventStreamsActive: { _ in }
        )
        let hold = await handlers.keepAwakeHold(Data())
        let release = await handlers.keepAwakeRelease(Data())
        let status = await handlers.keepAwakeStatus()
        #expect(hold.status == 503)
        #expect(release.status == 503)
        #expect(status.status == 503)
    }

    @Test("合法 hold 回 200，expiresIn 正確")
    func holdOK() async throws {
        let (handlers, _) = makeLeaseHandlers()
        let body = try JSONEncoder().encode(KeepAwakeHoldRequest(id: "build-bot", ttl: 600))
        let response = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: body, handlers: handlers
        ))
        #expect(response.status == 200)
        let decoded = try JSONDecoder().decode(KeepAwakeHoldResponse.self, from: Data(response.json.utf8))
        #expect(decoded.id == "build-bot")
        #expect(decoded.expiresIn == 600)
        #expect(decoded.ttl == 600)
        #expect(decoded.effective == true)
    }

    @Test("id 不合法回 400")
    func invalidID() async throws {
        let (handlers, _) = makeLeaseHandlers()
        let body = try JSONEncoder().encode(KeepAwakeHoldRequest(id: "bad id", ttl: 60))
        let response = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: body, handlers: handlers
        ))
        #expect(response.status == 400)
    }

    @Test("invalidTTL / NaN-like 回 400")
    func invalidTTL() async throws {
        let (handlers, _) = makeLeaseHandlers()
        let body = Data(#"{"id":"bot","ttl":"nope"}"#.utf8)
        let response = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: body, handlers: handlers
        ))
        #expect(response.status == 400)

        let nanBody = Data(#"{"id":"bot","ttl":null}"#.utf8) // null ttl = default, OK
        let nanResponse = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: nanBody, handlers: handlers
        ))
        #expect(nanResponse.status == 200)
    }

    @Test("第 33 個租約回 429")
    func tooMany() async throws {
        var table = KeepAwakeLeaseTable()
        for i in 0..<32 {
            _ = table.hold(id: "lease-\(i)", ttl: 600, now: 1_000)
        }
        let (handlers, _) = makeLeaseHandlers(table: table)
        let body = try JSONEncoder().encode(KeepAwakeHoldRequest(id: "lease-33", ttl: 600))
        let response = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: body, handlers: handlers
        ))
        #expect(response.status == 429)
    }

    @Test("release 與 status")
    func releaseAndStatus() async throws {
        let (handlers, box) = makeLeaseHandlers()
        let holdBody = try JSONEncoder().encode(KeepAwakeHoldRequest(id: "bot", ttl: 120))
        _ = await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: holdBody, handlers: handlers
        )
        #expect(box.value.active(now: 1_000).count == 1)

        let releaseBody = try JSONEncoder().encode(KeepAwakeReleaseRequest(id: "bot"))
        let release = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/release", body: releaseBody, handlers: handlers
        ))
        #expect(release.status == 200)

        let status = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "GET", path: "/v1/keepawake", body: Data(), handlers: handlers
        ))
        #expect(status.status == 200)
        let decoded = try JSONDecoder().decode(KeepAwakeStatusResponse.self, from: Data(status.json.utf8))
        #expect(decoded.leases.isEmpty)
    }

    @Test("Host / Bearer gates（無網路）")
    func authAndHostGates() {
        #expect(AutomationHTTPTransport.isLocalHostForTesting("127.0.0.1") == true)
        #expect(AutomationHTTPTransport.isLocalHostForTesting("localhost:55780") == true)
        #expect(AutomationHTTPTransport.isLocalHostForTesting("evil.example") == false)
        #expect(AutomationHTTPTransport.isLocalHostForTesting(nil) == false)
        #expect(AutomationHTTPTransport.bearerTokenForTesting(nil) == nil)
        #expect(AutomationHTTPTransport.bearerTokenForTesting("Bearer abc") == "abc")
        #expect(AutomationHTTPTransport.bearerTokenForTesting("Basic abc") == nil)
    }

    @Test("maxBodyBytes 上限仍為 256 KiB")
    func bodyLimitUnchanged() {
        #expect(AutomationHTTPTransport.maxBodyBytes == 256 * 1024)
    }

    @Test("V1-5／V1-6 stale authorization rejected; overload returns 503; reservation released")
    func keepAwakeAdmissionAndStaleAuth() async throws {
        var admission = AutomationAdmission(limits: .init(maxPendingCommands: 1))
        let body = try JSONEncoder().encode(KeepAwakeHoldRequest(id: "race", ttl: 60))
        var handled = 0

        let first = await AutomationHTTPTransport.executeKeepAwakeMutationForTesting(
            admission: &admission,
            requestGeneration: 0,
            currentGeneration: 0,
            body: body
        ) { _ in
            handled += 1
            return .init(status: 200, json: #"{"ok":true}"#)
        }
        #expect(first.status == 200)
        #expect(handled == 1)

        // Capacity full before release would 503 — reserve without completing via direct admit.
        #expect(admission.admitCommands(1) == nil)
        let overloaded = await AutomationHTTPTransport.executeKeepAwakeMutationForTesting(
            admission: &admission,
            requestGeneration: 0,
            currentGeneration: 0,
            body: body
        ) { _ in
            handled += 1
            return .init(status: 200, json: #"{"ok":true}"#)
        }
        #expect(overloaded.status == 503)
        #expect(handled == 1)
        admission.releaseCommands(1)

        let stale = await AutomationHTTPTransport.executeKeepAwakeMutationForTesting(
            admission: &admission,
            requestGeneration: 1,
            currentGeneration: 2,
            body: body
        ) { _ in
            handled += 1
            return .init(status: 200, json: #"{"ok":true}"#)
        }
        #expect(stale.status == 409)
        #expect(handled == 1)
        // Reservation released after stale reject — next admit succeeds.
        #expect(admission.admitCommands(1) == nil)
        admission.releaseCommands(1)
    }

    @Test("V1-11 status emits clamped TTL from hold/renew")
    func statusTTLMatchesHold() async throws {
        let (handlers, _) = makeLeaseHandlers(now: 2_000)
        let hold60 = try JSONEncoder().encode(KeepAwakeHoldRequest(id: "ttl-job", ttl: 60))
        _ = await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: hold60, handlers: handlers
        )
        var status = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "GET", path: "/v1/keepawake", body: Data(), handlers: handlers
        ))
        var decoded = try JSONDecoder().decode(KeepAwakeStatusResponse.self, from: Data(status.json.utf8))
        #expect(decoded.leases.first?.ttl == 60)

        let renew120 = try JSONEncoder().encode(KeepAwakeHoldRequest(id: "ttl-job", ttl: 120))
        _ = await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "POST", path: "/v1/keepawake/hold", body: renew120, handlers: handlers
        )
        status = try #require(await AutomationHTTPTransport.routeKeepAwakeForTesting(
            method: "GET", path: "/v1/keepawake", body: Data(), handlers: handlers
        ))
        decoded = try JSONDecoder().decode(KeepAwakeStatusResponse.self, from: Data(status.json.utf8))
        #expect(decoded.leases.first?.ttl == 120)
    }
}

@Suite("KeepAwake CLI parser (V-C09)")
struct KeepAwakeCLIParserTests {
    @Test("hold / release / status")
    func parseOK() {
        #expect(
            KeepAwakeCLIParser.parse(["hold", "--id", "bot", "--ttl", "120"])
                == .success(.hold(id: "bot", ttl: 120))
        )
        #expect(
            KeepAwakeCLIParser.parse(["hold", "--id", "bot"])
                == .success(.hold(id: "bot", ttl: nil))
        )
        #expect(
            KeepAwakeCLIParser.parse(["release", "--id", "bot"])
                == .success(.release(id: "bot"))
        )
        #expect(KeepAwakeCLIParser.parse(["status"]) == .success(.status))
    }

    @Test("--peer 拒絕")
    func peerRejected() {
        #expect(KeepAwakeCLIParser.parse(["hold", "--id", "bot", "--peer", "x"]) == .failure(.peerRejected))
    }

    @Test("用法錯誤")
    func usage() {
        guard case .failure(.usage) = KeepAwakeCLIParser.parse(["hold"]) else {
            Issue.record("expected usage")
            return
        }
        guard case .failure(.usage) = KeepAwakeCLIParser.parse([]) else {
            Issue.record("expected usage")
            return
        }
    }
}

/// Mutable box for lease table across @Sendable closures.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
