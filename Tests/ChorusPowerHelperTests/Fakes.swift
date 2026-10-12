import ChorusCore
import Foundation

final class FakePMSetRunner: PMSetRunning, @unchecked Sendable {
    var systemValue: Bool? = false
    var writeError: Error?
    var readError: Error?
    var writeDelay: TimeInterval = 0
    /// Blocks write until `unblockWrite()` (W1-1 wedged runner).
    private let writeLock = NSCondition()
    private var writeBlocked = false
    private(set) var writes: [Bool] = []
    private(set) var readCount = 0
    private(set) var inFlightWrites = 0

    func blockNextWrites() {
        writeLock.lock()
        writeBlocked = true
        writeLock.unlock()
    }

    func unblockWrite() {
        writeLock.lock()
        writeBlocked = false
        writeLock.broadcast()
        writeLock.unlock()
    }

    func readSleepDisabled() throws -> Bool? {
        readCount += 1
        if let readError { throw readError }
        return systemValue
    }

    func writeSleepDisabled(_ enabled: Bool) throws {
        inFlightWrites += 1
        defer { inFlightWrites -= 1 }
        writeLock.lock()
        while writeBlocked {
            writeLock.wait()
        }
        writeLock.unlock()
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
    /// Fail on the Nth save (1-based). nil = use saveError for every save.
    var failOnSaveNumber: Int?
    private(set) var saveCount = 0
    private(set) var loadCount = 0

    func load() throws -> SleepGuardLedger? {
        loadCount += 1
        if let loadError { throw loadError }
        return stored
    }

    func save(_ ledger: SleepGuardLedger) throws {
        saveCount += 1
        if let failOnSaveNumber, saveCount == failOnSaveNumber {
            throw LedgerStoreError.writeFailed
        }
        if let saveError { throw saveError }
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
