import Foundation

/// Test fixtures for `orca worktree ps --json` output parsing and activity planning.
/// Schema references: `docs/spec.md` §4.3, `docs/research/chorus-keepawake.md` §6.1,
/// and `docs/research/keepawake-open-questions.md` (R01 Q3-Q5).
enum OrcaFixtures {
    // source: measured - Mac mini actual output for `orca worktree ps --json` with only Desktop inactive worktree
    static let emptyInactive: String = """
    {
      "id": "req-1",
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-desktop",
            "repo": "desktop",
            "path": "/Users/test/Desktop",
            "displayName": "Desktop",
            "status": "inactive",
            "isActive": false,
            "liveTerminalCount": 0
          }
        ],
        "totalCount": 1,
        "truncated": false
      },
      "_meta": {
        "runtimeId": "rt-1"
      }
    }
    """

    // source: documented - spec §4.3 and runtime contract `status: "working"` representing active agent work
    static let oneWorking: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-feature",
            "repo": "repo-1",
            "path": "/Users/test/src/repo-1",
            "displayName": "feature-branch",
            "status": "working",
            "isActive": true,
            "liveTerminalCount": 1,
            "lastActivityAt": "2026-10-12T12:00:00.000Z"
          }
        ],
        "totalCount": 1,
        "truncated": false
      }
    }
    """

    // source: documented - spec §4.3 and runtime contract `status: "permission"` representing waiting on user permission
    static let onePermissionOnly: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-perm",
            "repo": "repo-2",
            "path": "/Users/test/src/repo-2",
            "displayName": "waiting-perm",
            "status": "permission",
            "isActive": true,
            "liveTerminalCount": 1,
            "lastActivityAt": "2026-10-12T12:05:00.000Z"
          }
        ],
        "totalCount": 1,
        "truncated": false
      }
    }
    """

    // source: documented - spec §4.3 and research §6.1 `status: "active"` (PTY alive but not working, must classify as idle)
    static let activeOnly: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-active",
            "repo": "repo-3",
            "path": "/Users/test/src/repo-3",
            "displayName": "shell-open",
            "status": "active",
            "isActive": true,
            "liveTerminalCount": 2,
            "lastActivityAt": "2026-10-12T12:10:00.000Z"
          }
        ],
        "totalCount": 1,
        "truncated": false
      }
    }
    """

    // source: documented - spec §4.3 and research Q5 covering all 5 runtime status values (active, working, permission, done, inactive)
    static let mixedAllStatuses: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-1",
            "displayName": "wt-active",
            "status": "active",
            "isActive": true
          },
          {
            "worktreeId": "wt-2",
            "displayName": "wt-working",
            "status": "working",
            "isActive": true
          },
          {
            "worktreeId": "wt-3",
            "displayName": "wt-permission",
            "status": "permission",
            "isActive": true
          },
          {
            "worktreeId": "wt-4",
            "displayName": "wt-done",
            "status": "done",
            "isActive": false
          },
          {
            "worktreeId": "wt-5",
            "displayName": "wt-inactive",
            "status": "inactive",
            "isActive": false
          }
        ],
        "totalCount": 5,
        "truncated": false
      }
    }
    """

    // source: assumed - forward compatibility test for future/unknown status value (e.g. "thinking")
    static let unknownStatus: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-thinking",
            "displayName": "wt-future",
            "status": "thinking",
            "isActive": true,
            "liveTerminalCount": 1
          }
        ],
        "totalCount": 1,
        "truncated": false
      }
    }
    """

    // source: documented - spec §4.3 and research Q5 `truncated: true` output
    static let truncated: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-trunc-1",
            "displayName": "wt-visible",
            "status": "working",
            "isActive": true
          }
        ],
        "totalCount": 42,
        "truncated": true
      }
    }
    """

    // source: assumed - spec §4.3 error contract when CLI daemon returns `{"ok": false, "error": {...}}`
    static let okFalse: String = """
    {
      "ok": false,
      "error": {
        "code": "RUNTIME_UNAVAILABLE",
        "message": "Orca runtime daemon is not responding"
      }
    }
    """

    // source: assumed - corrupted/truncated JSON output from CLI
    static let malformed: String = """
    {"ok": true, "result": {"worktrees": [{"worktreeId": "wt-bad", "statu
    """

    // source: documented - ISO 8601 timestamp format for `lastActivityAt`
    static let lastActivityISO8601: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-iso",
            "displayName": "wt-iso-timestamp",
            "status": "working",
            "lastActivityAt": "2026-10-12T14:30:00.000Z"
          }
        ],
        "totalCount": 1,
        "truncated": false
      }
    }
    """

    // source: assumed - Epoch milliseconds timestamp format for `lastActivityAt`
    static let lastActivityEpochMillis: String = """
    {
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "wt-epoch",
            "displayName": "wt-epoch-millis",
            "status": "working",
            "lastActivityAt": 1791815400000
          }
        ],
        "totalCount": 1,
        "truncated": false
      }
    }
    """
}
