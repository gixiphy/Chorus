import Foundation
import Testing
@testable import ChorusCore

@Suite("DoctorFailure")
struct DoctorFailureTests {
    static let all: [DoctorFailure] = [
        .notConfigured("找不到 token"),
        .unauthorized("token 不正確"),
        .unreachable(port: 55780),
        .timedOut(port: 55780),
        .mainThreadStalled(health: #"{"ok":true}"#),
        .mainThreadStalled(health: nil),
        .unsupportedApp,
        .unreadableReport("keyNotFound"),
        .http(status: 500, body: "boom"),
    ]

    @Test("Exit codes follow the documented contract")
    func exitCodes() {
        #expect(DoctorFailure.notConfigured("x").exitCode == 3)
        #expect(DoctorFailure.unauthorized("x").exitCode == 3)
        #expect(DoctorFailure.unreachable(port: 1).exitCode == 4)
        #expect(DoctorFailure.timedOut(port: 1).exitCode == 4)
        #expect(DoctorFailure.mainThreadStalled(health: nil).exitCode == 1)
        #expect(DoctorFailure.unsupportedApp.exitCode == 1)
        #expect(DoctorFailure.unreadableReport("x").exitCode == 1)
        #expect(DoctorFailure.http(status: 500, body: "").exitCode == 1)
    }

    @Test("JSON output is a single valid object for every failure", arguments: DoctorFailureTests.all)
    func jsonIsValidForEveryFailure(_ failure: DoctorFailure) throws {
        let object = try JSONSerialization.jsonObject(with: Data(failure.render(json: true).utf8)) as? [String: Any]
        #expect(object?["ok"] as? Bool == false)
        #expect(object?["exitCode"] as? Int == Int(failure.exitCode))
        let error = object?["error"] as? [String: Any]
        #expect(error?["kind"] is String)
        #expect(error?["remedy"] is String)
    }

    @Test("A JSON health snapshot is embedded as an object, other text as a string")
    func healthEmbedsAsObject() throws {
        let embedded = try JSONSerialization.jsonObject(
            with: Data(DoctorFailure.mainThreadStalled(health: #"{"ok":true}"#).render(json: true).utf8)
        ) as? [String: Any]
        #expect(((embedded?["error"] as? [String: Any])?["health"] as? [String: Any])?["ok"] as? Bool == true)
        let plain = try JSONSerialization.jsonObject(
            with: Data(DoctorFailure.mainThreadStalled(health: "not json").render(json: true).utf8)
        ) as? [String: Any]
        #expect((plain?["error"] as? [String: Any])?["health"] as? String == "not json")
    }

    @Test("Text output names the problem and the next step")
    func text() {
        let text = DoctorFailure.unreachable(port: 55780).render(json: false)
        #expect(text.contains("✗ 連線 — 連不上 127.0.0.1:55780"))
        #expect(text.contains("→ "))
        #expect(text.contains("自動化介面」已開啟"))
        #expect(DoctorFailure.unreadableReport("keyNotFound").render(json: false).contains("無法解讀"))
    }
}
