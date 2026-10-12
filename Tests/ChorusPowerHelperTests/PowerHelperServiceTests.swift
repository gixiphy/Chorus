import ChorusCore
import Foundation
import Testing

@Suite("PowerHelperService crash windows (V-C05-1)")
struct PowerHelperServiceCrashWindowTests {
    private func makeService(
        runner: FakePMSetRunner = FakePMSetRunner(),
        store: FakeLedgerStore = FakeLedgerStore(),
        safety: FakeSafety = FakeSafety()
    ) -> PowerHelperService {
        let service = PowerHelperService(
            runner: runner,
            store: store,
            safety: safety,
            helperBuild: "136",
            isRelease: false,
            now: { 100 },
            onIdleExit: {}
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
        // Read becomes unknown after launch; new acquire must refuse without writing.
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
        _ = sem.wait(timeout: .now() + 2)
        return (box.status, box.error)
    }
}

@Suite("PowerHelperService safety (V-C05-2)")
struct PowerHelperServiceWatchdogTests {
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
        _ = sem.wait(timeout: .now() + 2)
        #expect(box.error == nil)
        #expect(service.ledgerSnapshotForTesting().holders.count == 1)

        safety.snap.thermal = .critical
        let sem2 = DispatchSemaphore(value: 0)
        exported.setSleepDisabled(true) { _, error in
            box.error = error
            sem2.signal()
        }
        _ = sem2.wait(timeout: .now() + 2)
        #expect(box.error == "refusedThermal")

        var ledger = service.ledgerSnapshotForTesting()
        #expect(ledger.setByHelper == true)
        let action = ledger.forceOff(currentSystemValue: true)
        #expect(action == .write(false))
    }
}

@Suite("LedgerStore safety (V-C05-3)")
struct LedgerStoreTests {
    @Test("round-trip metadata without holders")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LedgerStore(directoryPath: dir.path, policy: .testing())
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
    }

    @Test("corrupt JSON yields corrupt error")
    func corrupt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-ledger-\(UUID().uuidString)", isDirectory: true)
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-ledger-\(UUID().uuidString)", isDirectory: true)
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

    @Test("unsupported version is corrupt")
    func badVersion() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-ledger-\(UUID().uuidString)", isDirectory: true)
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

private final class ReplyBox: @unchecked Sendable {
    var status: Data?
    var error: String?
}
