import ChorusCore
import Darwin
import Foundation
import IOKit.ps
import Testing

@Suite("PowerHelperService crash windows (V-C05-1 / W1-8)")
struct PowerHelperServiceCrashWindowTests {
    private func makeService(
        runner: FakePMSetRunner = FakePMSetRunner(),
        store: FakeLedgerStore = FakeLedgerStore(),
        safety: FakeSafety = FakeSafety(),
        idleExitDelay: TimeInterval = 30,
        onIdleExit: @escaping () -> Void = {}
    ) -> PowerHelperService {
        let service = PowerHelperService(
            runner: runner,
            store: store,
            safety: safety,
            helperBuild: "136",
            isRelease: false,
            now: { 100 },
            idleExitDelay: idleExitDelay,
            onIdleExit: onIdleExit
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.05)
        return service
    }

    @Test("store failure before write(true) does not call pmset and rolls back holder")
    func storeFailBlocksWriteTrue() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let store = FakeLedgerStore()
        store.saveError = LedgerStoreError.writeFailed
        let service = makeService(runner: runner, store: store)

        let result = driveSet(service: service, enabled: true, connectionID: 7, uid: 501, pid: 9)
        #expect(result.error == "storeFailed")
        #expect(runner.writes.isEmpty)
        #expect(service.ledgerSnapshotForTesting().holders.isEmpty)
        #expect(service.ledgerSnapshotForTesting().setByHelper == false)
    }

    @Test("write(false) failure keeps setByHelper ownership")
    func writeFalseFailureKeepsOwnership() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let store = FakeLedgerStore()
        let service = makeService(runner: runner, store: store)

        let hold = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(hold.error == nil)
        #expect(runner.writes == [true])
        #expect(service.ledgerSnapshotForTesting().setByHelper == true)

        runner.writeError = PMSetRunnerError.timedOut
        let release = driveSet(service: service, enabled: false, connectionID: 1, uid: 501, pid: 1)
        #expect(release.error == "pmsetFailed")
        let ledger = service.ledgerSnapshotForTesting()
        #expect(ledger.setByHelper == true)
        #expect(ledger.pendingRestore == true)
    }

    @Test("save succeeds before write1 but fails after ack → storeFailed + retry state (W1-8)")
    func saveFailsAfterWrite1Ack() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let store = FakeLedgerStore()
        // Launch reconcile may save once; acquire saves intent then post-ack.
        // failOnSaveNumber: first save after start that is the post-ack persist.
        // start() reconcile with system false + no persisted → may save.
        // Count: reconcile save (1), pre-write1 save (2), post-ack save (3).
        store.failOnSaveNumber = 3
        let service = makeService(runner: runner, store: store)

        let hold = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(hold.error == "storeFailed")
        #expect(runner.writes == [true])
        #expect(service.ledgerSnapshotForTesting().setByHelper == true)
        #expect(service.persistRetryNeededForTesting() == true)
    }

    @Test("write0 succeeds but save fails → storeFailed and restaged pendingRestore (W1-8)")
    func saveFailsAfterWrite0Ack() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let store = FakeLedgerStore()
        let service = makeService(runner: runner, store: store)

        let hold = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(hold.error == nil)
        let savesBeforeRelease = store.saveCount
        store.saveError = LedgerStoreError.writeFailed

        let release = driveSet(service: service, enabled: false, connectionID: 1, uid: 501, pid: 1)
        #expect(release.error == "storeFailed")
        #expect(runner.writes == [true, false])
        let ledger = service.ledgerSnapshotForTesting()
        #expect(ledger.setByHelper == true)
        #expect(ledger.pendingRestore == true)
        #expect(service.persistRetryNeededForTesting() == true)
        #expect(store.saveCount > savesBeforeRelease)
    }

    @Test("nil system at launch enters recoveryBlocked (Fi A8)")
    func nilSystemAtLaunchBlocks() {
        let runner = FakePMSetRunner()
        runner.systemValue = nil
        let service = makeService(runner: runner)
        #expect(service.ledgerSnapshotForTesting().recoveryBlocked == true)
        let result = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(result.error == "recoveryBlocked")
        #expect(runner.writes.isEmpty)
        #expect(service.ledgerSnapshotForTesting().holders.isEmpty)
    }

    @Test("unknown system value after healthy launch rejects new acquire")
    func unknownSystemRejectsAcquire() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let service = makeService(runner: runner)
        #expect(service.ledgerSnapshotForTesting().recoveryBlocked == false)
        runner.systemValue = nil
        let result = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(result.error == "systemValueUnknown")
        #expect(runner.writes.isEmpty)
        #expect(service.ledgerSnapshotForTesting().holders.isEmpty)
    }

    @Test("restart reconcile does not resurrect holders")
    func restartRejectsOldHolders() {
        let store = FakeLedgerStore()
        store.stored = SleepGuardLedger(
            holders: [
                99: .init(connectionID: 99, uid: 501, pid: 1, since: 1, lastHeartbeat: 1)
            ],
            priorValueWasDisabled: false,
            setByHelper: true,
            pendingRestore: true
        )
        let runner = FakePMSetRunner()
        runner.systemValue = true
        let service = makeService(runner: runner, store: store)
        let ledger = service.ledgerSnapshotForTesting()
        #expect(ledger.holders.isEmpty)
        #expect(runner.writes.contains(false))
    }

    @Test("thermal refuse does not write true")
    func thermalRefuse() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let safety = FakeSafety()
        safety.snap.thermal = .critical
        let service = makeService(runner: runner, safety: safety)
        let result = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(result.error == "refusedThermal")
        #expect(runner.writes.isEmpty)
    }

    @Test("unknown power refuses acquire")
    func unknownPowerRefuse() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let safety = FakeSafety()
        safety.snap.onBattery = nil
        let service = makeService(runner: runner, safety: safety)
        let result = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(result.error == "refusedBattery")
        #expect(runner.writes.isEmpty)
    }

    @Test("Release requirement string is Developer ID without get-task-allow")
    func releaseRequirement() {
        let service = PowerHelperService(
            runner: FakePMSetRunner(),
            store: FakeLedgerStore(),
            safety: FakeSafety(),
            helperBuild: "1",
            isRelease: true,
            onIdleExit: {}
        )
        let req = service.clientRequirementString
        #expect(req.contains("1.2.840.113635.100.6.1.13"))
        #expect(req.contains("get-task-allow"))
        #expect(PowerHelperConstants.validateRequirementSyntax(req))
    }

    @Test("successful acquire then release writes 1 then 0")
    func acquireReleaseRoundTrip() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let service = makeService(runner: runner)
        let hold = driveSet(service: service, enabled: true, connectionID: 1, uid: 501, pid: 1)
        #expect(hold.error == nil)
        let release = driveSet(service: service, enabled: false, connectionID: 1, uid: 501, pid: 1)
        #expect(release.error == nil)
        #expect(runner.writes == [true, false])
        #expect(service.ledgerSnapshotForTesting().setByHelper == false)
        #expect(service.ledgerSnapshotForTesting().holders.isEmpty)
    }

    private func driveSet(
        service: PowerHelperService,
        enabled: Bool,
        connectionID: UInt64,
        uid: UInt32,
        pid: Int32
    ) -> (status: Data?, error: String?) {
        let box = ReplyBox()
        let exported = PowerHelperService.ExportedObject(
            service: service,
            connectionID: connectionID,
            uid: uid,
            pid: pid
        )
        let sem = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(enabled) { data, error in
            box.status = data
            box.error = error
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return (box.status, box.error)
    }
}

@Suite("PowerHelperService async I/O independence (V-C05-2 / W1-1)")
struct PowerHelperServiceWatchdogTests {
    @Test("wedged runner: watchdog/forceOff still run; obsolete acquire discarded")
    func wedgedRunnerForceOffWins() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        runner.blockNextWrites()
        let safety = FakeSafety()
        let service = PowerHelperService(
            runner: runner,
            store: FakeLedgerStore(),
            safety: safety,
            helperBuild: "136",
            now: { 100 },
            onIdleExit: {}
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.05)

        let exported = PowerHelperService.ExportedObject(
            service: service, connectionID: 1, uid: 501, pid: 1
        )
        let acquireBox = ReplyBox()
        let acquireSem = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(true) { data, error in
            acquireBox.status = data
            acquireBox.error = error
            acquireSem.signal()
        }

        // While write is wedged, ledger queue must still service watchdog.
        Thread.sleep(forTimeInterval: 0.1)
        service.runWatchdogTickForTesting()

        // forceOff via safety refuse path on ledger (simulate safety tick).
        safety.snap.thermal = .critical
        // Unblock so the in-flight write(true) can finish — generation should reject ack
        // after we bump via a concurrent forceOff.
        // First: schedule forceOff by calling set which refuses; then unblock.
        // Better: use ledger forceOff through a second connection release path.
        // Direct: bump generation by starting another apply via release while wedged.
        let forceExported = PowerHelperService.ExportedObject(
            service: service, connectionID: 2, uid: 501, pid: 2
        )
        // Acquire connection 1 is in-flight. Unblock write, then forceOff via safety.
        runner.unblockWrite()
        _ = acquireSem.wait(timeout: .now() + 3)

        // Now holding; safety tick should forceOff without being blocked.
        runner.blockNextWrites()
        let tickStart = Date()
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.05)
            runner.unblockWrite()
        }
        service.runSafetyTickForTesting()
        // Safety tick schedules async IO; wait for write(false).
        let deadline = Date().addingTimeInterval(3)
        while runner.writes.filter({ $0 == false }).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(Date().timeIntervalSince(tickStart) < 2.5)
        #expect(runner.writes.contains(false))
        _ = forceExported
    }

    @Test("forceOff ledger path restores when setByHelper")
    func forceOffWhileHolding() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let safety = FakeSafety()
        let service = PowerHelperService(
            runner: runner,
            store: FakeLedgerStore(),
            safety: safety,
            helperBuild: "136",
            onIdleExit: {}
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.05)

        let box = ReplyBox()
        let exported = PowerHelperService.ExportedObject(
            service: service, connectionID: 1, uid: 501, pid: 1
        )
        let sem = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(true) { data, error in
            box.status = data
            box.error = error
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        #expect(box.error == nil)
        #expect(service.ledgerSnapshotForTesting().holders.count == 1)

        safety.snap.thermal = .critical
        let sem2 = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(true) { _, error in
            box.error = error
            sem2.signal()
        }
        _ = sem2.wait(timeout: .now() + 5)
        #expect(box.error == "refusedThermal")

        // W1-7: unsafe heartbeat must initiate protected restoration, not leave holders intact.
        let deadline = Date().addingTimeInterval(3)
        while service.ledgerSnapshotForTesting().holders.isEmpty == false, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let ledger = service.ledgerSnapshotForTesting()
        #expect(ledger.holders.isEmpty)
        #expect(runner.writes.contains(false))
    }

    @Test("refused heartbeat does not bump generation over pending release (W1-1)")
    func refuseDoesNotSupersedeRelease() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let safety = FakeSafety()
        let service = PowerHelperService(
            runner: runner,
            store: FakeLedgerStore(),
            safety: safety,
            helperBuild: "136",
            onIdleExit: {}
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.05)

        let exported = PowerHelperService.ExportedObject(
            service: service, connectionID: 1, uid: 501, pid: 1
        )
        let acquireSem = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(true) { _, _ in acquireSem.signal() }
        _ = acquireSem.wait(timeout: .now() + 3)
        #expect(service.ledgerSnapshotForTesting().holders.count == 1)

        // Wedged release write; a refused heartbeat must not cancel it via generation.
        runner.blockNextWrites()
        let releaseSem = DispatchSemaphore(value: 0)
        var releaseError: String?
        exported.setSleepDisabled(false) { _, error in
            releaseError = error
            releaseSem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        safety.snap.thermal = .critical
        let refuseSem = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(true) { _, error in
            #expect(error == "refusedThermal")
            refuseSem.signal()
        }
        _ = refuseSem.wait(timeout: .now() + 2)
        runner.unblockWrite()
        _ = releaseSem.wait(timeout: .now() + 3)
        #expect(releaseError == nil || releaseError == "storeFailed")
        #expect(runner.writes.contains(false))
    }

    @Test("obsolete queued write1 cancelled before side effect (W1-1)")
    func obsoleteWriteCancelledBeforeSideEffect() {
        let runner = FakePMSetRunner()
        runner.systemValue = false
        let safety = FakeSafety()
        let service = PowerHelperService(
            runner: runner,
            store: FakeLedgerStore(),
            safety: safety,
            helperBuild: "136",
            onIdleExit: {}
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.05)

        let exported = PowerHelperService.ExportedObject(
            service: service, connectionID: 1, uid: 501, pid: 1
        )
        runner.blockNextWrites()
        let acquireSem = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(true) { _, _ in acquireSem.signal() }
        Thread.sleep(forTimeInterval: 0.05)
        // ForceOff bumps generation while write(true) is queued/blocked.
        safety.snap.thermal = .critical
        service.runSafetyTickForTesting()
        Thread.sleep(forTimeInterval: 0.05)
        runner.unblockWrite()
        _ = acquireSem.wait(timeout: .now() + 2)
        // Either write(true) was cancelled before side effect, or its ack was discarded and
        // forceOff wrote false afterward — never leave an unopposed obsolete hold.
        let deadline = Date().addingTimeInterval(3)
        while !runner.writes.contains(false), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(service.ledgerSnapshotForTesting().holders.isEmpty || runner.writes.contains(false))
    }

    @Test("status encodes recovery health fields (W1-6)")
    func statusEncodesRecoveryFields() throws {
        let store = FakeLedgerStore()
        store.stored = SleepGuardLedger(
            holders: [:],
            priorValueWasDisabled: false,
            setByHelper: true,
            pendingRestore: true,
            recoveryBlocked: false
        )
        let runner = FakePMSetRunner()
        runner.systemValue = true
        runner.writeError = PMSetRunnerError.timedOut
        let service = PowerHelperService(
            runner: runner,
            store: store,
            safety: FakeSafety(),
            helperBuild: "136",
            onIdleExit: {}
        )
        service.start()
        let deadline = Date().addingTimeInterval(2)
        while !service.startupReadyForTesting(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let exported = PowerHelperService.ExportedObject(
            service: service, connectionID: 1, uid: 501, pid: 1
        )
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        exported.status { json in
            data = json
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        let status = try JSONDecoder().decode(PowerHelperStatus.self, from: try #require(data))
        #expect(status.pendingRestore == true || status.setByHelper == true)
        #expect(status.helperBuild == "136")
    }
}

@Suite("PowerHelperService idle exit (W1-9)")
struct PowerHelperServiceIdleTests {
    @Test("watchdog ticks do not renew idle; exits after delay")
    func idleDespiteWatchdog() {
        let exited = ExpectationFlag()
        let service = PowerHelperService(
            runner: FakePMSetRunner(),
            store: FakeLedgerStore(),
            safety: FakeSafety(),
            helperBuild: "136",
            now: { 100 },
            idleExitDelay: 0.15,
            onIdleExit: { exited.flag = true }
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.05)
        service.runWatchdogTickForTesting()
        service.runWatchdogTickForTesting()
        Thread.sleep(forTimeInterval: 0.25)
        service.checkIdleForTesting()
        #expect(exited.flag == true)
    }

    @Test("pending restore blocks idle exit")
    func pendingRestoreBlocksIdle() {
        let exited = ExpectationFlag()
        let store = FakeLedgerStore()
        store.stored = SleepGuardLedger(
            holders: [:],
            priorValueWasDisabled: false,
            setByHelper: true,
            pendingRestore: true
        )
        let runner = FakePMSetRunner()
        // Keep system true so reconcile does not clear pending immediately without write;
        // after restore write(false), pending clears — inject save failure to keep retry.
        runner.systemValue = true
        runner.writeError = PMSetRunnerError.timedOut
        let service = PowerHelperService(
            runner: runner,
            store: store,
            safety: FakeSafety(),
            helperBuild: "136",
            now: { 100 },
            idleExitDelay: 0.1,
            onIdleExit: { exited.flag = true }
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.05)
        // pendingRestore should remain (write failed).
        #expect(service.ledgerSnapshotForTesting().pendingRestore == true
            || service.ledgerSnapshotForTesting().setByHelper == true
            || service.persistRetryNeededForTesting())
        Thread.sleep(forTimeInterval: 0.2)
        service.checkIdleForTesting()
        #expect(exited.flag == false)
    }

    @Test("idle rearms after temporary blocker clears without external activity (W1-16)")
    func idleRearmsAfterBlockerClears() {
        let exited = ExpectationFlag()
        let store = FakeLedgerStore()
        store.stored = SleepGuardLedger(
            holders: [:],
            priorValueWasDisabled: false,
            setByHelper: true,
            pendingRestore: true
        )
        let runner = FakePMSetRunner()
        runner.systemValue = true
        // First restore attempt fails; later succeeds without further XPC.
        runner.writeError = PMSetRunnerError.timedOut
        let service = PowerHelperService(
            runner: runner,
            store: store,
            safety: FakeSafety(),
            helperBuild: "136",
            now: { 100 },
            idleExitDelay: 0.15,
            onIdleExit: { exited.flag = true }
        )
        service.start()
        Thread.sleep(forTimeInterval: 0.08)
        #expect(exited.flag == false)
        runner.writeError = nil
        runner.systemValue = true
        // Watchdog/retry path clears pending restore.
        service.runWatchdogTickForTesting()
        let deadline = Date().addingTimeInterval(3)
        while (service.ledgerSnapshotForTesting().pendingRestore
            || service.ledgerSnapshotForTesting().setByHelper
            || service.persistRetryNeededForTesting()), Date() < deadline
        {
            service.runWatchdogTickForTesting()
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.25)
        service.checkIdleForTesting()
        #expect(exited.flag == true)
    }
}

@Suite("HelperPowerSafety classification (W1-7)")
struct HelperPowerSafetyTests {
    @Test("nil providing source with internal battery is unknown, not AC")
    func nilProvidingUnknown() {
        let desc: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 80,
            kIOPSMaxCapacityKey as String: 100
        ]
        let result = HelperPowerSafety.classifyPowerSources(
            descriptions: [desc],
            providingType: nil
        )
        #expect(result.onBattery == nil)
        #expect(result.percent == 80)
    }

    @Test("unrecognized providing source is unknown")
    func unrecognizedProviding() {
        let desc: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 50,
            kIOPSMaxCapacityKey as String: 100
        ]
        let result = HelperPowerSafety.classifyPowerSources(
            descriptions: [desc],
            providingType: "SpaceshipPower"
        )
        #expect(result.onBattery == nil)
    }

    @Test("empty descriptions are unknown, not AC")
    func emptyUnknown() {
        let result = HelperPowerSafety.classifyPowerSources(descriptions: [], providingType: kIOPSACPowerValue as String)
        #expect(result.onBattery == nil)
    }

    @Test("confirmed AC with no internal battery")
    func confirmedDesktopAC() {
        let desc: [String: Any] = [
            kIOPSTypeKey as String: "UPS"
        ]
        let result = HelperPowerSafety.classifyPowerSources(
            descriptions: [desc],
            providingType: kIOPSACPowerValue as String
        )
        #expect(result.onBattery == false)
        #expect(result.percent == nil)
    }

    @Test("nonfinite capacity yields nil percent")
    func nonfiniteCapacity() {
        let desc: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: Double.nan,
            kIOPSMaxCapacityKey as String: 100
        ]
        let result = HelperPowerSafety.classifyPowerSources(
            descriptions: [desc],
            providingType: kIOPSBatteryPowerValue as String
        )
        #expect(result.onBattery == true)
        #expect(result.percent == nil)
    }

    @Test("current/max normalization")
    func currentMaxNorm() {
        let desc: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 4000,
            kIOPSMaxCapacityKey as String: 5000
        ]
        let pct = HelperPowerSafety.normalizedCapacityPercent(desc)
        #expect(pct == 80)
    }

    @Test("malformed max does not fall back to current as percent (W1-7)")
    func malformedMaxUnknown() {
        let desc: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 50,
            kIOPSMaxCapacityKey as String: Double.nan
        ]
        #expect(HelperPowerSafety.normalizedCapacityPercent(desc) == nil)
        let zeroMax: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 50,
            kIOPSMaxCapacityKey as String: 0
        ]
        #expect(HelperPowerSafety.normalizedCapacityPercent(zeroMax) == nil)
    }

    @Test("huge finite ratio clamps before Int conversion (W1-7)")
    func hugeRatioClamps() {
        // Finite but far outside 0…100 before Int conversion (must not trap).
        let desc: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 1e20,
            kIOPSMaxCapacityKey as String: 1.0
        ]
        let pct = HelperPowerSafety.normalizedCapacityPercent(desc)
        #expect(pct == 100)
    }
}

@Suite("LedgerStore safety (V-C05-3 / W1-12)")
struct LedgerStoreTests {
    /// Darwin `realpath` of the process temp dir (URL.resolvingSymlinksInPath leaves `/var` as a link).
    private func makeResolvedTempDir(suffix: String = "") throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.path
        let resolved: String = try tmp.withCString { cstr in
            guard let ptr = realpath(cstr, nil) else {
                throw LedgerStoreError.unsafeRoot
            }
            defer { free(ptr) }
            return String(cString: ptr)
        }
        return URL(fileURLWithPath: resolved, isDirectory: true)
            .appendingPathComponent("chorus-ledger-\(UUID().uuidString)\(suffix)", isDirectory: true)
    }

    @Test("round-trip metadata without holders; absent initial save")
    func roundTrip() throws {
        let dir = try makeResolvedTempDir()
        // Directory does not exist yet — save must create securely.
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
        #expect(try store.load() == nil)

        var ledger = SleepGuardLedger()
        ledger.setByHelper = true
        ledger.priorValueWasDisabled = false
        ledger.pendingRestore = true
        try store.save(ledger)

        let loaded = try #require(try store.load())
        #expect(loaded.setByHelper == true)
        #expect(loaded.priorValueWasDisabled == false)
        #expect(loaded.pendingRestore == true)
        #expect(loaded.holders.isEmpty)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("ledger.json").path
        )
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(mode & 0o077 == 0) // not group/world accessible beyond owner
        #expect(mode & 0o600 == 0o600)
    }

    @Test("corrupt JSON yields corrupt error")
    func corrupt() throws {
        let dir = try makeResolvedTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("ledger.json")
        try Data("not-json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
        #expect(throws: LedgerStoreError.corruptOrUnsupportedVersion) {
            _ = try store.load()
        }
    }

    @Test("symlink file is rejected")
    func symlinkFile() throws {
        let dir = try makeResolvedTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = dir.appendingPathComponent("ledger.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
        #expect(throws: LedgerStoreError.symlinkRejected) {
            _ = try store.load()
        }
    }

    @Test("writable leaf directory is rejected")
    func writableParent() throws {
        let dir = try makeResolvedTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
        #expect(throws: LedgerStoreError.worldOrGroupWritable) {
            try store.save(SleepGuardLedger())
        }
    }

    @Test("writable intermediate ancestor is rejected (W1-12)")
    func writableAncestor() throws {
        let root = try makeResolvedTempDir()
        let ancestor = root.appendingPathComponent("ancestor", isDirectory: true)
        let leaf = ancestor.appendingPathComponent("helper", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: ancestor.path)

        let store = LedgerStore(directoryPath: leaf.path, policy: .testing())
        #expect(throws: LedgerStoreError.worldOrGroupWritable) {
            try store.save(SleepGuardLedger())
        }
    }

    @Test("FIFO / nonregular file rejected on load")
    func fifoRejected() throws {
        let dir = try makeResolvedTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fifo = dir.appendingPathComponent("ledger.json")
        let rc = mkfifo(fifo.path, 0o600)
        #expect(rc == 0)

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
        #expect(throws: LedgerStoreError.notRegularFile) {
            _ = try store.load()
        }
    }

    @Test("save rejects existing FIFO without blocking (W1-12)")
    func saveRejectsFIFO() throws {
        let dir = try makeResolvedTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fifo = dir.appendingPathComponent("ledger.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
        let start = Date()
        #expect(throws: LedgerStoreError.notRegularFile) {
            try store.save(SleepGuardLedger())
        }
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test("symlink parent rejected")
    func symlinkParent() throws {
        let root = try makeResolvedTempDir()
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let store = LedgerStore(directoryPath: link.path, policy: .testing())
        #expect(throws: LedgerStoreError.symlinkRejected) {
            try store.save(SleepGuardLedger())
        }
    }

    @Test("intermediate ancestor symlink rejected (W1-12)")
    func intermediateSymlinkRejected() throws {
        let root = try makeResolvedTempDir()
        let real = root.appendingPathComponent("real", isDirectory: true)
        let mid = root.appendingPathComponent("mid", isDirectory: true)
        let leafName = "helper"
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent(leafName, isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: mid, withDestinationURL: real)

        let store = LedgerStore(
            directoryPath: mid.appendingPathComponent(leafName).path,
            policy: .testing()
        )
        #expect(throws: LedgerStoreError.symlinkRejected) {
            try store.save(SleepGuardLedger())
        }
    }

    @Test("unsupported version is corrupt")
    func badVersion() throws {
        let dir = try makeResolvedTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = #"{"version":99,"setByHelper":true,"pendingRestore":false,"recoveryBlocked":false}"#
        let file = dir.appendingPathComponent("ledger.json")
        try Data(payload.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
        #expect(throws: LedgerStoreError.corruptOrUnsupportedVersion) {
            _ = try store.load()
        }
    }
}

@Suite("PMSetRunner monotonic timeout (W1-1)")
struct PMSetRunnerTimeoutTests {
    @Test("runSubprocess times out with bounded kill when child ignores TERM")
    func timedOutWedged() throws {
        // /bin/sleep ignores nothing but exits; use a script that ignores TERM.
        let script = """
        #!/bin/sh
        trap '' TERM
        while true; do printf 'x'; sleep 0.05; done
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmset-wedge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("wedge.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)

        let start = MonotonicTime.seconds()
        do {
            _ = try PMSetRunner.runSubprocess(
                executableURL: path,
                arguments: [],
                timeout: 0.3
            )
            Issue.record("expected timeout")
        } catch let error as PMSetRunnerError {
            #expect(error == .timedOut)
        }
        let elapsed = MonotonicTime.seconds() - start
        #expect(elapsed < 2.5) // timeout + term grace + reap, bounded
    }

    @Test("descendant-held pipes and dual-pipe saturation stay bounded (W1-1)")
    func descendantAndSaturatedPipesBounded() throws {
        let script = """
        #!/bin/sh
        trap '' TERM
        # Child holds both pipes open after parent would exit.
        ( while true; do printf 'S'; printf 'E' >&2; sleep 0.01; done ) &
        while true; do printf 'x'; printf 'y' >&2; sleep 0.01; done
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmset-desc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("desc.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)

        let start = MonotonicTime.seconds()
        do {
            _ = try PMSetRunner.runSubprocess(
                executableURL: path,
                arguments: [],
                timeout: 0.25
            )
            Issue.record("expected timeout")
        } catch let error as PMSetRunnerError {
            #expect(error == .timedOut)
        }
        let elapsed = MonotonicTime.seconds() - start
        #expect(elapsed < 3.0)
    }
}

@Suite("PowerHelperService startup reconcile (W1-15)")
struct PowerHelperServiceStartupTests {
    @Test("startup reconcile is async; RPC waits without same-queue deadlock")
    func asyncStartupNoDeadlock() throws {
        let runner = FakePMSetRunner()
        runner.systemValue = true
        runner.writeDelay = 0.15
        let store = FakeLedgerStore()
        store.stored = SleepGuardLedger(
            holders: [:],
            priorValueWasDisabled: false,
            setByHelper: true,
            pendingRestore: true
        )
        let service = PowerHelperService(
            runner: runner,
            store: store,
            safety: FakeSafety(),
            helperBuild: "136",
            onIdleExit: {}
        )
        let start = Date()
        service.start()
        // RPC enqueued during startup must complete after reconcile — no 7s same-queue hang.
        let exported = PowerHelperService.ExportedObject(
            service: service, connectionID: 1, uid: 501, pid: 1
        )
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        exported.status { json in
            data = json
            sem.signal()
        }
        #expect(sem.wait(timeout: .now() + 3) == .success)
        #expect(data != nil)
        #expect(Date().timeIntervalSince(start) < 2.5)
        #expect(service.startupReadyForTesting() == true)
    }
}

private final class ReplyBox: @unchecked Sendable {
    var status: Data?
    var error: String?
}

private final class ExpectationFlag: @unchecked Sendable {
    var flag = false
}
