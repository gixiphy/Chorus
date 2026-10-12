import Foundation
import Testing
@testable import ChorusCore

@Suite("OrcaWorktreeStatus")
struct OrcaWorktreeStatusTests {
    // MARK: - V-C04-1 fixtures

    @Test("V-C04-1 emptyInactive → idle")
    func emptyInactive() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.emptyInactive,
            countPermissionAsWorking: true
        )
        #expect(result == .idle)
    }

    @Test("V-C04-1 oneWorking → working")
    func oneWorking() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.oneWorking,
            countPermissionAsWorking: true
        )
        guard case let .working(rows, warning) = result else {
            Issue.record("expected working, got \(result)")
            return
        }
        #expect(rows.count == 1)
        #expect(rows[0].status == .working)
        #expect(rows[0].id == "wt-feature")
        #expect(rows[0].name == "feature-branch")
        #expect(rows[0].lastActivityAt != nil)
        #expect(warning == nil)
    }

    @Test("V-C04-1 onePermissionOnly respects countPermissionAsWorking")
    func onePermissionOnly() {
        let counted = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.onePermissionOnly,
            countPermissionAsWorking: true
        )
        guard case let .working(rows, warning) = counted else {
            Issue.record("expected working when permission counts, got \(counted)")
            return
        }
        #expect(rows.count == 1)
        #expect(rows[0].status == .permission)
        #expect(warning == nil)

        let ignored = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.onePermissionOnly,
            countPermissionAsWorking: false
        )
        #expect(ignored == .idle)
    }

    @Test("V-C04-1 activeOnly MUST be idle")
    func activeOnlyIsIdle() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.activeOnly,
            countPermissionAsWorking: true
        )
        #expect(result == .idle)
    }

    @Test("V-C04-1 mixedAllStatuses → working (working + permission)")
    func mixedAllStatuses() {
        let withPerm = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.mixedAllStatuses,
            countPermissionAsWorking: true
        )
        guard case let .working(rows, warning) = withPerm else {
            Issue.record("expected working, got \(withPerm)")
            return
        }
        #expect(Set(rows.map(\.status)) == [.working, .permission])
        #expect(warning == nil)

        let withoutPerm = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.mixedAllStatuses,
            countPermissionAsWorking: false
        )
        guard case let .working(onlyWorking, withoutWarning) = withoutPerm else {
            Issue.record("expected working without permission, got \(withoutPerm)")
            return
        }
        #expect(onlyWorking.map(\.status) == [.working])
        #expect(withoutWarning == nil)
    }

    @Test("V-C04-1 / V-C07-6 unknownStatus → incomplete, not idle")
    func unknownStatusIncomplete() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.unknownStatus,
            countPermissionAsWorking: true
        )
        guard case let .incomplete(reason) = result else {
            Issue.record("expected incomplete, got \(result)")
            return
        }
        #expect(reason == OrcaActivityPlanner.unknownStatusWarning)
    }

    @Test("V-C04-1 C4-1 active+unknown → incomplete, not idle")
    func activePlusUnknownIncomplete() {
        let json = mixedJSON(statuses: ["active", "thinking"])
        let result = OrcaActivityPlanner.classifyJSON(json, countPermissionAsWorking: true)
        guard case let .incomplete(reason) = result else {
            Issue.record("expected incomplete, got \(result)")
            return
        }
        #expect(reason == OrcaActivityPlanner.unknownStatusWarning)
    }

    @Test("V-C04-1 C4-1 inactive+unknown → incomplete, not idle")
    func inactivePlusUnknownIncomplete() {
        let json = mixedJSON(statuses: ["inactive", "thinking"])
        let result = OrcaActivityPlanner.classifyJSON(json, countPermissionAsWorking: true)
        guard case let .incomplete(reason) = result else {
            Issue.record("expected incomplete, got \(result)")
            return
        }
        #expect(reason == OrcaActivityPlanner.unknownStatusWarning)
    }

    @Test("V-C04-1 C4-1 permission+unknown with permission counting disabled → incomplete")
    func permissionPlusUnknownWhenPermissionIgnored() {
        let json = mixedJSON(statuses: ["permission", "thinking"])
        let result = OrcaActivityPlanner.classifyJSON(json, countPermissionAsWorking: false)
        guard case let .incomplete(reason) = result else {
            Issue.record("expected incomplete, got \(result)")
            return
        }
        #expect(reason == OrcaActivityPlanner.unknownStatusWarning)
    }

    @Test("V-C04-1 C4-1 working+unknown → working with quality warning")
    func workingPlusUnknownKeepsWorkingWithWarning() {
        let json = mixedJSON(statuses: ["working", "thinking"])
        let result = OrcaActivityPlanner.classifyJSON(json, countPermissionAsWorking: true)
        guard case let .working(rows, warning) = result else {
            Issue.record("expected working with warning, got \(result)")
            return
        }
        #expect(rows.map(\.status) == [.working])
        #expect(warning == OrcaActivityPlanner.unknownStatusWarning)
    }

    @Test("V-C04-1 truncated with working → working")
    func truncatedWithWorking() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.truncated,
            countPermissionAsWorking: true
        )
        guard case let .working(rows, warning) = result else {
            Issue.record("expected working, got \(result)")
            return
        }
        #expect(rows.count == 1)
        #expect(rows[0].status == .working)
        #expect(warning == nil)
    }

    @Test("V-C07-6 truncated without working → incomplete, not idle")
    func truncatedWithoutWorkingIsIncomplete() {
        let json = """
        {
          "ok": true,
          "result": {
            "worktrees": [
              {
                "worktreeId": "wt-trunc-idle",
                "displayName": "idle-visible",
                "status": "inactive",
                "isActive": false
              }
            ],
            "totalCount": 99,
            "truncated": true
          }
        }
        """
        let result = OrcaActivityPlanner.classifyJSON(json, countPermissionAsWorking: true)
        guard case let .incomplete(reason) = result else {
            Issue.record("expected incomplete, got \(result)")
            return
        }
        #expect(reason.contains("truncated"))
    }

    @Test("V-C04-1 okFalse → failed with allowlisted sanitized reason")
    func okFalse() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.okFalse,
            countPermissionAsWorking: true
        )
        guard case let .failed(reason) = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
        #expect(reason == "orca:RUNTIME_UNAVAILABLE")
        #expect(!reason.contains("daemon"))
    }

    @Test("V-C04-1 C4-2 ok:false reason strips path/control/long payload")
    func okFalseSanitizedReason() {
        let sentinelPath = "/Users/private/secret-worktree"
        let longPayload = String(repeating: "X", count: 4_096)
        let json = """
        {
          "ok": false,
          "error": {
            "code": "LEAKED\\nCODE\\u0001\(sentinelPath)",
            "message": "failed at \(sentinelPath)\\n\(longPayload)"
          }
        }
        """
        let result = OrcaActivityPlanner.classifyJSON(json, countPermissionAsWorking: true)
        guard case let .failed(reason) = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
        #expect(reason == "orca error")
        #expect(!reason.contains(sentinelPath))
        #expect(!reason.contains("\n"))
        #expect(!reason.contains("\u{0001}"))
        #expect(!reason.contains("XXXX"))
        #expect(reason.count <= 64)
    }

    @Test("V-C04-1 malformed → failed")
    func malformed() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.malformed,
            countPermissionAsWorking: true
        )
        guard case .failed = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
    }

    @Test("V-C04-1 lastActivityAt ISO8601")
    func lastActivityISO8601() {
        let response = OrcaActivityPlanner.decodeResponse(from: OrcaFixtures.lastActivityISO8601)
        #expect(response != nil)
        let date = response?.result?.worktrees.first?.lastActivityAt
        #expect(date != nil)
        // 2026-10-12T14:30:00.000Z
        #expect(date?.timeIntervalSince1970 == 1_791_815_400)
    }

    @Test("V-C04-1 lastActivityAt epoch millis")
    func lastActivityEpochMillis() {
        let response = OrcaActivityPlanner.decodeResponse(from: OrcaFixtures.lastActivityEpochMillis)
        #expect(response != nil)
        let date = response?.result?.worktrees.first?.lastActivityAt
        #expect(date != nil)
        #expect(date?.timeIntervalSince1970 == 1_791_815_400)
    }

    @Test("V-C04-1 C4-4 numeric epoch milliseconds always divide by 1000", arguments: [
        (0.0, 0.0),
        (1_000.0, 1.0),
        (946_684_800_000.0, 946_684_800.0),
    ])
    func epochMillisAlwaysMilliseconds(millis: Double, expectedSeconds: Double) {
        let json = """
        {
          "ok": true,
          "result": {
            "worktrees": [
              {
                "worktreeId": "wt-epoch-edge",
                "status": "working",
                "lastActivityAt": \(millis)
              }
            ]
          }
        }
        """
        let response = OrcaActivityPlanner.decodeResponse(from: json)
        let date = response?.result?.worktrees.first?.lastActivityAt
        #expect(date?.timeIntervalSince1970 == expectedSeconds)
    }

    @Test("unknown fields are ignored; decode still succeeds")
    func ignoresUnknownFields() {
        let json = """
        {
          "ok": true,
          "extraTop": 1,
          "result": {
            "worktrees": [
              {
                "worktreeId": "wt-x",
                "status": "working",
                "futureField": {"nested": true}
              }
            ],
            "truncated": false,
            "hostScope": {"hostIds": []}
          }
        }
        """
        let result = OrcaActivityPlanner.classifyJSON(json, countPermissionAsWorking: true)
        guard case let .working(_, warning) = result else {
            Issue.record("expected working, got \(result)")
            return
        }
        #expect(warning == nil)
    }

    @Test("R01 constants: bundle id and CLI candidates")
    func knownConstants() {
        #expect(OrcaWorktreeStatus.knownBundleIDs.contains("com.stablyai.orca"))
        #expect(OrcaWorktreeStatus.teamID == "6CX3WHS9HZ")
        #expect(OrcaWorktreeStatus.defaultCLICandidates.first == "/opt/homebrew/bin/orca")
    }

    // MARK: - Helpers

    private func mixedJSON(statuses: [String]) -> String {
        let rows = statuses.enumerated().map { index, status in
            """
            {
              "worktreeId": "wt-\(index)",
              "displayName": "row-\(index)",
              "status": "\(status)"
            }
            """
        }.joined(separator: ",")
        return """
        {
          "ok": true,
          "result": {
            "worktrees": [\(rows)],
            "totalCount": \(statuses.count),
            "truncated": false
          }
        }
        """
    }
}
