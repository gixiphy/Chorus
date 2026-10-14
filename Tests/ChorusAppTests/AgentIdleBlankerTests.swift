import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("AgentIdleBlanker", .timeLimit(.minutes(1)))
struct AgentIdleBlankerTests {
    final class FakeDisplays: IdleBlankDisplayControlling {
        var blankCalls = 0
        var restoreCalls = 0
        var owned: Set<String> = ["A", "B"]
        var lastBlanked: Set<String> = []

        func blankForIdle() -> Set<String> {
            blankCalls += 1
            lastBlanked = owned
            return owned
        }

        func restoreIdleBlank() {
            restoreCalls += 1
        }
    }

    @Test("Blanks when armed and idle, restores on activity, and stops cleanly")
    func blankRestoreStop() {
        let displays = FakeDisplays()
        var idle = 0.0
        let blanker = AgentIdleBlanker(displays: displays, idleSeconds: { idle })
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        #expect(displays.blankCalls == 0)

        idle = 300
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        #expect(displays.blankCalls == 1)

        idle = 0.1
        blanker.evaluateForTesting()
        #expect(!blanker.isBlanked)
        #expect(displays.restoreCalls == 1)

        idle = 300
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        #expect(displays.blankCalls == 2)

        blanker.stop()
        #expect(!blanker.isBlanked)
        #expect(displays.restoreCalls == 2)
    }

    @Test("Leaving agent mode restores without waiting for input")
    func leaveAgentModeRestores() {
        let displays = FakeDisplays()
        let idle = 600.0
        let blanker = AgentIdleBlanker(displays: displays, idleSeconds: { idle })
        blanker.configure(enabled: true, minutes: .three)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)

        blanker.update(agentModeActive: false, holdingAssertion: false)
        #expect(!blanker.isBlanked)
        #expect(displays.restoreCalls == 1)
    }

    @Test("Foreground fullscreen / media protection blocks blank while idle past threshold")
    func fullscreenBlocksBlank() {
        let displays = FakeDisplays()
        let idle = 600.0
        var media: IdleBlankSignal = .active
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { media },
            remoteSession: { .inactive },
            foreignDisplayAssertion: { .inactive }
        )
        blanker.configure(enabled: true, minutes: .three)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(!blanker.isBlanked)
        #expect(displays.blankCalls == 0)

        media = .inactive
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        #expect(displays.blankCalls == 1)
    }

    @Test("Remote session protection blocks blank")
    func remoteSessionBlocksBlank() {
        let displays = FakeDisplays()
        let idle = 600.0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .inactive },
            remoteSession: { .active },
            foreignDisplayAssertion: { .inactive }
        )
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(!blanker.isBlanked)
        #expect(displays.blankCalls == 0)
    }

    @Test("Unknown protection source never blanks")
    func unknownProtectionNeverBlanks() {
        let displays = FakeDisplays()
        let idle = 600.0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .unknown },
            remoteSession: { .inactive },
            foreignDisplayAssertion: { .inactive }
        )
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(!blanker.isBlanked)
    }

    @Test("Restore only calls DisplayManager idle restore (ownership seam)")
    func restoreOnlyTouchesIdleOwnership() {
        let displays = FakeDisplays()
        var idle = 600.0
        let blanker = AgentIdleBlanker(displays: displays, idleSeconds: { idle })
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(displays.lastBlanked == ["A", "B"])

        idle = 0.0
        blanker.evaluateForTesting()
        #expect(displays.restoreCalls == 1)
        #expect(displays.blankCalls == 1)
    }

    @Test("Foreign assertion is queried near threshold, not every far-idle evaluate")
    func foreignAssertionQueriedNearThresholdOnly() {
        let displays = FakeDisplays()
        var idle = 10.0
        var foreignCalls = 0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .inactive },
            remoteSession: { .inactive },
            foreignDisplayAssertion: {
                foreignCalls += 1
                return .inactive
            }
        )
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)

        for _ in 0..<20 {
            blanker.evaluateForTesting()
        }
        #expect(foreignCalls == 0)

        idle = 250 // within 60s of 300s threshold
        blanker.evaluateForTesting()
        #expect(foreignCalls == 1)

        blanker.evaluateForTesting()
        blanker.evaluateForTesting()
        #expect(foreignCalls == 1) // cached until TTL / invalidate

        idle = 300
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        #expect(foreignCalls == 1)

        for _ in 0..<10 {
            blanker.evaluateForTesting()
        }
        #expect(foreignCalls == 1) // blanked ticks must not hammer powerd
    }

    @Test("Foreign assertion active near threshold blocks blank")
    func foreignAssertionBlocksBlank() {
        let displays = FakeDisplays()
        let idle = 300.0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .inactive },
            remoteSession: { .inactive },
            foreignDisplayAssertion: { .active }
        )
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(!blanker.isBlanked)
        #expect(displays.blankCalls == 0)
    }

    @Test("State change invalidates foreign assertion cache", .timeLimit(.minutes(1)))
    func stateChangeInvalidatesForeignCache() async throws {
        let displays = FakeDisplays()
        let idle = 280.0
        var foreignCalls = 0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .inactive },
            remoteSession: { .inactive },
            foreignDisplayAssertion: {
                foreignCalls += 1
                return .inactive
            }
        )
        // configure／update 各自 evaluate；接近門檻時每次 invalidate 後會查一次。
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        let afterArm = foreignCalls
        #expect(afterArm == 2)

        blanker.evaluateForTesting()
        blanker.update(agentModeActive: true, holdingAssertion: true) // no-op，不 invalidate
        blanker.evaluateForTesting()
        #expect(foreignCalls == afterArm)

        let deadline = ContinuousClock.now + .seconds(5)
        // 改成 3 分鐘：idle=280 仍在「接近門檻」窗內，invalidate 後會再查。
        blanker.configure(enabled: true, minutes: .three)
        #expect(foreignCalls == afterArm + 1)
        #expect(ContinuousClock.now < deadline)
    }
}

@MainActor
@Suite("DisplayManager idle blank ownership", .timeLimit(.minutes(1)))
struct DisplayManagerIdleBlankTests {
    @Test("Manual power-on removes a display from idle ownership")
    func manualOnDropsOwnership() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "idle-blank-\(UUID().uuidString)")!)
        let manager = DisplayManager(settings: settings)
        // 沒有真實螢幕時 blankForIdle 是空的；用 powered-off 登錄表驗證所有權 API。
        #expect(manager.blankForIdle().isEmpty)
        #expect(manager.idleBlankOwnedUUIDsForTesting.isEmpty)

        let before = manager.idleBlankGenerationForTesting
        manager.bumpIdleBlankGenerationForTesting()
        #expect(manager.idleBlankGenerationForTesting == before + 1)
        manager.restoreIdleBlank()
        #expect(manager.idleBlankOwnedUUIDsForTesting.isEmpty)
    }
}
