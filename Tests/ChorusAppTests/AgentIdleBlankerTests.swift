import ChorusCore
import CoreGraphics
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

    @Test("Idle past threshold blanks when all supported protections are inactive")
    func supportedProtectionsInactiveBlank() {
        let displays = FakeDisplays()
        let idle = 600.0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .inactive },
            foreignDisplayAssertion: { .inactive }
        )
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        #expect(displays.blankCalls == 1)
    }

    @Test("Universal Control and viewer process presence are not protection inputs")
    func remoteProcessPresenceIsNotAProtectionInput() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionFiles = [
            "Chorus/Display/AgentIdleBlanker.swift",
            "Chorus/Display/IdleBlankProtectionReaders.swift",
            "Packages/ChorusCore/Sources/ChorusCore/AgentIdleBlank.swift",
        ]
        let forbiddenTokens = [
            "com.apple.universalcontrol",
            "com.apple.ScreenSharing",
            "ContinuityCapture",
            "CGSessionCopyCurrentDictionary",
            "kCGSessionOnConsoleKey",
        ]

        for relativePath in productionFiles {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for token in forbiddenTokens {
                #expect(
                    !source.contains(token),
                    "Unexpected remote process/session protection token \(token) in \(relativePath)"
                )
            }
        }
    }

    @Test("Unknown protection source never blanks")
    func unknownProtectionNeverBlanks() {
        let displays = FakeDisplays()
        let idle = 600.0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .unknown },
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
        #expect(foreignCalls == 2) // blank transition performs one final fresh check

        for _ in 0..<10 {
            blanker.evaluateForTesting()
        }
        #expect(foreignCalls == 2) // blanked ticks must not hammer powerd
    }

    @Test("Foreign assertion active near threshold blocks blank")
    func foreignAssertionBlocksBlank() {
        let displays = FakeDisplays()
        let idle = 300.0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .inactive },
            foreignDisplayAssertion: { .active }
        )
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        blanker.evaluateForTesting()
        #expect(!blanker.isBlanked)
        #expect(displays.blankCalls == 0)
    }

    @Test(
        "Full review F2: blank candidate rechecks a fresh foreign assertion",
        arguments: [IdleBlankSignal.active, .unknown]
    )
    func blankCandidateRechecksForeignAssertion(signalBeforeBlank: IdleBlankSignal) {
        let displays = FakeDisplays()
        var idle = 170.0
        var foreign: IdleBlankSignal = .inactive
        var foreignCalls = 0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { .inactive },
            foreignDisplayAssertion: {
                foreignCalls += 1
                return foreign
            }
        )
        blanker.configure(enabled: true, minutes: .three)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        let callsNearThreshold = foreignCalls
        #expect(callsNearThreshold == 2)

        foreign = signalBeforeBlank
        idle = 180
        blanker.evaluateForTesting()

        #expect(foreignCalls == callsNearThreshold + 1)
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

    @Test("Blanked: foreign assertion re-checked after TTL and restores (review fix)")
    func blankedForeignAssertionRecheckedAfterTTL() {
        let displays = FakeDisplays()
        let idle = 600.0
        var foreign: IdleBlankSignal = .inactive
        var foreignCalls = 0
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            foreignDisplayAssertion: {
                foreignCalls += 1
                return foreign
            }
        )
        blanker.configure(enabled: true, minutes: .five)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        #expect(blanker.isBlanked)
        let calls = foreignCalls

        foreign = .active
        for _ in 0..<10 { blanker.evaluateForTesting() }
        #expect(foreignCalls == calls) // TTL 內不重打 powerd
        #expect(blanker.isBlanked)

        blanker.ageForeignAssertionCacheForTesting(by: AgentIdleBlanker.foreignAssertionCacheTTL)
        blanker.evaluateForTesting()
        #expect(foreignCalls == calls + 1)
        #expect(!blanker.isBlanked)
        #expect(displays.restoreCalls == 1)
    }

    @Test("Blanked: media turning active restores immediately")
    func blankedMediaActiveRestores() {
        let displays = FakeDisplays()
        let idle = 600.0
        var media: IdleBlankSignal = .inactive
        let blanker = AgentIdleBlanker(
            displays: displays,
            idleSeconds: { idle },
            mediaOrFullscreen: { media }
        )
        blanker.configure(enabled: true, minutes: .three)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        #expect(blanker.isBlanked)

        media = .active
        blanker.evaluateForTesting()
        #expect(!blanker.isBlanked)
        #expect(displays.restoreCalls == 1)
    }

    @Test(
        "Invalid idle never blanks and never restores by itself",
        arguments: [Double.nan, -1.0, Double.infinity, -Double.infinity]
    )
    func invalidIdleIsConservative(bad: Double) {
        let displays = FakeDisplays()
        var idle = bad
        let blanker = AgentIdleBlanker(displays: displays, idleSeconds: { idle })
        blanker.configure(enabled: true, minutes: .three)
        blanker.update(agentModeActive: true, holdingAssertion: true)
        #expect(!blanker.isBlanked)

        idle = 600
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        idle = bad
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        #expect(displays.restoreCalls == 0)
    }
}

@Suite("IdleBlankProtectionReaders parsing (review fix)")
struct IdleBlankProtectionReadersTests {
    private static func window(pid: pid_t, _ rect: CGRect) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
        ]
    }

    // 主螢幕 1512×982；外接 1920×1080 在主螢幕上方偏左（Quartz y 為負）。
    private static let displays = [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: -408, y: -1080, width: 1920, height: 1080),
    ]

    @Test("Fullscreen window on a secondary display above main is active")
    func secondaryDisplayFullscreen() {
        let infos = [Self.window(pid: 42, CGRect(x: -408, y: -1080, width: 1920, height: 1080))]
        #expect(IdleBlankProtectionReaders.fullscreenSignal(
            windowInfos: infos, frontPID: 42, displayBounds: Self.displays
        ) == .active)
    }

    @Test("Ordinary or other-app windows are inactive; no front window is inactive")
    func nonFullscreenInactive() {
        let infos = [
            Self.window(pid: 42, CGRect(x: 0, y: 33, width: 512, height: 949)),
            Self.window(pid: 7, CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ]
        #expect(IdleBlankProtectionReaders.fullscreenSignal(
            windowInfos: infos, frontPID: 42, displayBounds: Self.displays
        ) == .inactive)
        #expect(IdleBlankProtectionReaders.fullscreenSignal(
            windowInfos: [], frontPID: 42, displayBounds: Self.displays
        ) == .inactive)
        #expect(IdleBlankProtectionReaders.fullscreenSignal(
            windowInfos: infos, frontPID: 42, displayBounds: []
        ) == .unknown)
    }

    @Test("Legacy NoDisplaySleepAssertion counts; own PID and level 0 do not")
    func foreignAssertionParsing() {
        func entry(_ type: String, level: UInt32 = 255) -> [String: Any] {
            ["AssertType": type, "AssertLevel": NSNumber(value: level)]
        }
        let legacy: NSDictionary = [NSNumber(value: 100): [entry("NoDisplaySleepAssertion")]]
        #expect(IdleBlankProtectionReaders.displaySleepSignal(assertionsByPID: legacy, selfPID: 1) == .active)

        let mine: NSDictionary = [NSNumber(value: 1): [entry("PreventUserIdleDisplaySleep")]]
        #expect(IdleBlankProtectionReaders.displaySleepSignal(assertionsByPID: mine, selfPID: 1) == .inactive)

        let systemOnly: NSDictionary = [
            NSNumber(value: 100): [
                entry("PreventUserIdleSystemSleep"),
                entry("PreventUserIdleDisplaySleep", level: 0),
            ],
        ]
        #expect(IdleBlankProtectionReaders.displaySleepSignal(assertionsByPID: systemOnly, selfPID: 1) == .inactive)

        let malformed: NSDictionary = [NSNumber(value: 100): "garbage"]
        #expect(IdleBlankProtectionReaders.displaySleepSignal(assertionsByPID: malformed, selfPID: 1) == .unknown)
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
