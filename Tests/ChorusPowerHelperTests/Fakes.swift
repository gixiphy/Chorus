import ChorusCore
import Foundation

final class FakePMSetRunner: PMSetRunning, @unchecked Sendable {
    var systemValue: Bool? = false
    var writeError: Error?
    var readError: Error?
    var writeDelay: TimeInterval = 0
    private(set) var writes: [Bool] = []
    private(set) var readCount = 0

    func readSleepDisabled() throws -> Bool? {
        readCount += 1
        if let readError { throw readError }
        return systemValue
    }

    func writeSleepDisabled(_ enabled: Bool) throws {
        if writeDelay > 0 {
            Thread.sleep(forTimeInterval: writeDelay)
        }
        if let writeError { throw writeError }
        writes.append(enabled)
        systemValue = enabled
    }
}

final class FakeLedgerStore: LedgerStoring, @unchecked Sendable {
    var stored: SleepGuardLedger?
    var loadError: Error?
    var saveError: Error?
    private(set) var saveCount = 0
    private(set) var loadCount = 0

    func load() throws -> SleepGuardLedger? {
        loadCount += 1
        if let loadError { throw loadError }
        return stored
    }

    func save(_ ledger: SleepGuardLedger) throws {
        saveCount += 1
        if let saveError { throw saveError }
        // Persist metadata only (no holders), matching production store.
        stored = SleepGuardLedger(
            holders: [:],
            priorValueWasDisabled: ledger.priorValueWasDisabled,
            setByHelper: ledger.setByHelper,
            pendingRestore: ledger.pendingRestore,
            recoveryBlocked: ledger.recoveryBlocked
        )
    }
}

final class FakeSafety: HelperPowerSafetyChecking, @unchecked Sendable {
    var snap = HelperSafetySnapshot(thermal: .nominal, onBattery: false, batteryPercent: nil)

    func snapshot() -> HelperSafetySnapshot { snap }
}
