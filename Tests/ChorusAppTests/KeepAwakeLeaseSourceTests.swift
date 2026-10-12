import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("KeepAwakeLeaseSource")
struct KeepAwakeLeaseSourceTests {
    @Test("hold triggers onChange immediately")
    func holdOnChange() {
        var clock = Date(timeIntervalSince1970: 8_000_000)
        let source = KeepAwakeLeaseSource(
            wallNow: { clock },
            uptimeNow: { clock.timeIntervalSince1970 }
        )
        var changes = 0
        source.onChange = { changes += 1 }
        source.start()
        #expect(changes == 0)
        _ = source.hold(id: "build", ttl: 120)
        #expect(changes == 1)
        #expect(source.report.first?.isWorkingNow == true)
        source.stop()
    }

    @Test("expired lease within grace: isWorkingNow false, lastWorkingAt == expiry")
    func expiredInGrace() {
        var clock = Date(timeIntervalSince1970: 8_100_000)
        let source = KeepAwakeLeaseSource(
            graceSeconds: 300,
            wallNow: { clock },
            uptimeNow: { clock.timeIntervalSince1970 }
        )
        source.start()
        _ = source.hold(id: "job", ttl: 30)
        let expiresAtWall = clock.addingTimeInterval(30)

        clock = clock.addingTimeInterval(31)
        source.refresh()
        let report = source.report.first { $0.id == "lease:job" }
        #expect(report != nil)
        #expect(report?.isWorkingNow == false)
        #expect(report?.lastWorkingAt == expiresAtWall)
        source.stop()
    }

    @Test("clearImmediately drops leases without grace and notifies when running")
    func clearImmediate() {
        var clock = Date(timeIntervalSince1970: 8_200_000)
        let source = KeepAwakeLeaseSource(
            wallNow: { clock },
            uptimeNow: { clock.timeIntervalSince1970 }
        )
        var changes = 0
        source.onChange = { changes += 1 }
        source.start()
        _ = source.hold(id: "a", ttl: 600)
        #expect(!source.report.isEmpty)
        let before = changes
        source.clearImmediately()
        #expect(source.report.isEmpty)
        #expect(changes == before + 1)
        let snap = source.snapshot()
        #expect(snap.active.isEmpty)
        #expect(snap.tombstones.isEmpty)

        source.stop()
        let afterStop = changes
        source.clearImmediately()
        #expect(changes == afterStop) // stopped → silent
    }

    @Test("snapshot refreshes report after expiry")
    func snapshotRefreshesReport() {
        var clock = Date(timeIntervalSince1970: 8_300_000)
        let source = KeepAwakeLeaseSource(
            graceSeconds: 300,
            wallNow: { clock },
            uptimeNow: { clock.timeIntervalSince1970 }
        )
        source.start()
        _ = source.hold(id: "s", ttl: 30)
        clock = clock.addingTimeInterval(31)
        _ = source.snapshot()
        #expect(source.report.first?.isWorkingNow == false)
        source.stop()
    }

    @Test("V1-2 start is idempotent; drifting wall keeps lastWorkingAt stable")
    func startIdempotentStableWall() {
        var uptime = 100.0
        var wallReads = 0
        let source = KeepAwakeLeaseSource(
            wallNow: {
                wallReads += 1
                return Date(timeIntervalSince1970: 9_000_000 + Double(wallReads))
            },
            uptimeNow: { uptime }
        )
        var changes = 0
        source.onChange = { changes += 1 }
        source.start()
        _ = source.hold(id: "stable", ttl: 120)
        let first = source.report.first?.lastWorkingAt
        #expect(first != nil)
        let before = changes
        source.start() // already running — no refresh notify
        source.refresh()
        #expect(source.report.first?.lastWorkingAt == first)
        #expect(changes == before)
        uptime = 101
        _ = source.hold(id: "stable", ttl: 120) // renew → new stamp may update wall
        #expect(changes == before + 1)
        source.stop()
    }

    @Test("V1-7 continuous clock sleep jump expires TTL-60 lease")
    func continuousSleepJumpExpires() {
        var continuous = 1_000.0
        let source = KeepAwakeLeaseSource(
            graceSeconds: 300,
            wallNow: { Date(timeIntervalSince1970: continuous) },
            uptimeNow: { continuous }
        )
        source.start()
        _ = source.hold(id: "ttl60", ttl: 60)
        #expect(source.report.first?.isWorkingNow == true)
        // Past TTL but still inside grace — must not remain live on continuous clock.
        continuous += 61
        source.refresh()
        let inGrace = source.report.first { $0.id == "lease:ttl60" }
        #expect(inGrace != nil)
        #expect(inGrace?.isWorkingNow == false)
        // Long sleep past grace — no fabricated live lease.
        continuous += 3_600
        source.refresh()
        #expect(!source.report.contains { $0.id == "lease:ttl60" && $0.isWorkingNow })
        source.stop()
    }

    @Test("V1-7 clock failure freezes last continuous stamp (no systemUptime epoch switch)")
    func clockFailureFreezesEpoch() {
        var continuous: Double? = 5_000
        let source = KeepAwakeLeaseSource(
            graceSeconds: 300,
            wallNow: { Date(timeIntervalSince1970: continuous ?? 0) },
            continuousNow: { continuous }
        )
        source.start()
        _ = source.hold(id: "sticky", ttl: 120)
        let firstExpiryBudget = source.currentUptime()
        #expect(firstExpiryBudget == 5_000)
        continuous = nil // primary clock fails
        #expect(source.currentUptime() == 5_000)
        source.refresh()
        #expect(source.report.contains { $0.id == "lease:sticky" && $0.isWorkingNow })
        // Recovery resumes the same continuous epoch — not a different base.
        continuous = 5_030
        #expect(source.currentUptime() == 5_030)
        source.refresh()
        #expect(source.report.contains { $0.id == "lease:sticky" && $0.isWorkingNow })
        source.stop()
    }

    @Test("V1-9 expired full table accepts new id without intervening tick")
    func expiredCapacityWithoutTick() {
        var continuous = 0.0
        let source = KeepAwakeLeaseSource(
            wallNow: { Date(timeIntervalSince1970: continuous) },
            uptimeNow: { continuous }
        )
        source.start()
        for i in 0..<32 {
            let result = source.hold(id: "e-\(i)", ttl: 30)
            guard case .held = result else {
                Issue.record("seed \(i)")
                return
            }
        }
        continuous = 31
        let result = source.hold(id: "new", ttl: 60)
        guard case .held = result else {
            Issue.record("expected held, got \(result)")
            return
        }
        #expect(source.report.contains { $0.id == "lease:new" && $0.isWorkingNow })
        source.stop()
    }
}
