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
        guard case let .working(rows) = result else {
            Issue.record("expected working, got \(result)")
            return
        }
        #expect(rows.count == 1)
        #expect(rows[0].status == .working)
        #expect(rows[0].id == "wt-feature")
        #expect(rows[0].name == "feature-branch")
        #expect(rows[0].lastActivityAt != nil)
    }

    @Test("V-C04-1 onePermissionOnly respects countPermissionAsWorking")
    func onePermissionOnly() {
        let counted = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.onePermissionOnly,
            countPermissionAsWorking: true
        )
        guard case let .working(rows) = counted else {
            Issue.record("expected working when permission counts, got \(counted)")
            return
        }
        #expect(rows.count == 1)
        #expect(rows[0].status == .permission)

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
        guard case let .working(rows) = withPerm else {
            Issue.record("expected working, got \(withPerm)")
            return
        }
        #expect(Set(rows.map(\.status)) == [.working, .permission])

        let withoutPerm = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.mixedAllStatuses,
            countPermissionAsWorking: false
        )
        guard case let .working(onlyWorking) = withoutPerm else {
            Issue.record("expected working without permission, got \(withoutPerm)")
            return
        }
        #expect(onlyWorking.map(\.status) == [.working])
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
        #expect(reason.contains("unknown"))
    }

    @Test("V-C04-1 truncated with working → working")
    func truncatedWithWorking() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.truncated,
            countPermissionAsWorking: true
        )
        guard case let .working(rows) = result else {
            Issue.record("expected working, got \(result)")
            return
        }
        #expect(rows.count == 1)
        #expect(rows[0].status == .working)
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

    @Test("V-C04-1 okFalse → failed")
    func okFalse() {
        let result = OrcaActivityPlanner.classifyJSON(
            OrcaFixtures.okFalse,
            countPermissionAsWorking: true
        )
        guard case let .failed(reason) = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
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
        guard case .working = result else {
            Issue.record("expected working, got \(result)")
            return
        }
    }

    @Test("R01 constants: bundle id and CLI candidates")
    func knownConstants() {
        #expect(OrcaWorktreeStatus.knownBundleIDs.contains("com.stablyai.orca"))
        #expect(OrcaWorktreeStatus.teamID == "6CX3WHS9HZ")
        #expect(OrcaWorktreeStatus.defaultCLICandidates.first == "/opt/homebrew/bin/orca")
    }
}
