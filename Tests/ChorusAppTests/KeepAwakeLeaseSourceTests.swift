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

    @Test("clearImmediately drops leases without grace")
    func clearImmediate() {
        var clock = Date(timeIntervalSince1970: 8_200_000)
        let source = KeepAwakeLeaseSource(
            wallNow: { clock },
            uptimeNow: { clock.timeIntervalSince1970 }
        )
        source.start()
        _ = source.hold(id: "a", ttl: 600)
        #expect(!source.report.isEmpty)
        source.clearImmediately()
        #expect(source.report.isEmpty)
        let snap = source.snapshot()
        #expect(snap.active.isEmpty)
        #expect(snap.tombstones.isEmpty)
        source.stop()
    }
}
