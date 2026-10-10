import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("AgentIdleBlanker")
struct AgentIdleBlankerTests {
    final class FakeDisplays: IdleBlankDisplayControlling {
        var blankCalls = 0
        var restoreCalls = 0
        var owned: Set<String> = ["A", "B"]

        func blankForIdle() -> Set<String> {
            blankCalls += 1
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
        var idle = 600.0
        let blanker = AgentIdleBlanker(displays: displays, idleSeconds: { idle })
        blanker.configure(enabled: true, minutes: .three)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)

        blanker.update(agentModeActive: false, holdingAssertion: false)
        #expect(!blanker.isBlanked)
        #expect(displays.restoreCalls == 1)
    }
}

@MainActor
@Suite("DisplayManager idle blank ownership")
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
