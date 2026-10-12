import Foundation
import Testing
@testable import ChorusCore

@Suite("SleepGuardLedger")
struct SleepGuardLedgerTests {
    @Test("V-C03-2 first acquire: system 0 → write(true); system 1 foreign → none, release does not write 0")
    func firstAcquireOwnership() {
        var ledger = SleepGuardLedger()
        let a1 = ledger.acquire(connectionID: 1, uid: 501, pid: 100, now: 0, currentSystemValue: false)
        #expect(a1 == .write(true))
        #expect(ledger.setByHelper)
        ledger.acknowledgeWrite(true)

        var foreign = SleepGuardLedger()
        let a2 = foreign.acquire(connectionID: 1, uid: 501, pid: 100, now: 0, currentSystemValue: true)
        #expect(a2 == .none)
        #expect(!foreign.setByHelper)
        #expect(foreign.priorValueWasDisabled == true)
        let rel = foreign.release(connectionID: 1, currentSystemValue: true)
        #expect(rel == .none)
        #expect(!foreign.setByHelper)
    }

    @Test("V-C03-5 two holders: first release none; last release write(false)")
    func twoHolders() {
        var ledger = SleepGuardLedger()
        _ = ledger.acquire(connectionID: 1, uid: 501, pid: 1, now: 0, currentSystemValue: false)
        ledger.acknowledgeWrite(true)
        _ = ledger.acquire(connectionID: 2, uid: 502, pid: 2, now: 1, currentSystemValue: true)
        let first = ledger.release(connectionID: 1, currentSystemValue: true)
        #expect(first == .none)
        #expect(ledger.holders.count == 1)
        let last = ledger.release(connectionID: 2, currentSystemValue: true)
        #expect(last == .write(false))
        #expect(ledger.setByHelper) // 確認前不清
        ledger.acknowledgeWrite(false)
        #expect(!ledger.setByHelper)
    }

    @Test("V-C03-5 / W0-10 same-uid: release one real connection; other survives")
    func sameUIDIndependent() {
        var ledger = SleepGuardLedger()
        _ = ledger.acquire(connectionID: 1, uid: 501, pid: 1, now: 0, currentSystemValue: false)
        ledger.acknowledgeWrite(true)
        _ = ledger.acquire(connectionID: 2, uid: 501, pid: 2, now: 1, currentSystemValue: true)
        let released = ledger.release(connectionID: 1, currentSystemValue: true)
        #expect(released == .none)
        #expect(ledger.holders.keys.sorted() == [2])
        #expect(ledger.setByHelper)
        let last = ledger.release(connectionID: 2, currentSystemValue: true)
        #expect(last == .write(false))
    }

    @Test("dropConnection equivalent to release")
    func dropEquivalent() {
        var a = SleepGuardLedger()
        _ = a.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
        a.acknowledgeWrite(true)
        let r1 = a.dropConnection(1, currentSystemValue: true)

        var b = SleepGuardLedger()
        _ = b.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
        b.acknowledgeWrite(true)
        let r2 = b.release(connectionID: 1, currentSystemValue: true)
        #expect(r1 == r2)
        #expect(r1 == .write(false))
    }

    @Test("V-C03-4 expire: 59s keep, 61s remove; only timed-out holder")
    func expireWatchdog() {
        var ledger = SleepGuardLedger()
        _ = ledger.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
        ledger.acknowledgeWrite(true)
        _ = ledger.acquire(connectionID: 2, uid: 1, pid: 2, now: 0, currentSystemValue: true)
        // renew holder 2 at t=50
        _ = ledger.acquire(connectionID: 2, uid: 1, pid: 2, now: 50, currentSystemValue: true)

        let (none, expiredEarly) = ledger.expire(now: 59, timeout: 60, currentSystemValue: true)
        #expect(none == .none)
        #expect(expiredEarly.isEmpty)
        #expect(ledger.holders.count == 2)

        let (action, expired) = ledger.expire(now: 61, timeout: 60, currentSystemValue: true)
        #expect(expired == [1])
        #expect(ledger.holders.keys.sorted() == [2])
        #expect(action == .none)
    }

    @Test("V-C03-6 forceOff: clears holders; helper-owned → write(false); foreign → none")
    func forceOff() {
        var owned = SleepGuardLedger()
        _ = owned.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
        owned.acknowledgeWrite(true)
        #expect(owned.forceOff(currentSystemValue: true) == .write(false))
        #expect(owned.holders.isEmpty)

        var foreign = SleepGuardLedger()
        _ = foreign.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: true)
        #expect(foreign.forceOff(currentSystemValue: true) == .none)
    }

    @Test("V-C03-3 own residual: setByHelper+system1+no holders → acquire then release writes 0")
    func ownResidual() {
        var ledger = SleepGuardLedger(priorValueWasDisabled: false, setByHelper: true)
        let acq = ledger.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: true)
        #expect(acq == .none)
        #expect(ledger.setByHelper)
        #expect(ledger.priorValueWasDisabled == false)
        let rel = ledger.release(connectionID: 1, currentSystemValue: true)
        #expect(rel == .write(false))
    }

    @Test("V-C03-8 heartbeats seeing 1 never clear setByHelper; final release writes 0")
    func heartbeatsKeepOwnership() {
        var ledger = SleepGuardLedger()
        #expect(
            ledger.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
                == .write(true)
        )
        ledger.acknowledgeWrite(true)
        for t in [20.0, 40.0, 60.0] {
            let action = ledger.acquire(
                connectionID: 1, uid: 1, pid: 1, now: t, currentSystemValue: true
            )
            #expect(action == .none)
            #expect(ledger.setByHelper)
        }
        #expect(ledger.release(connectionID: 1, currentSystemValue: true) == .write(false))
    }

    @Test("Fi A2 / W0-1: external 0 during owned session → interference, no write(true), no stale holders")
    func externalZeroInterference() {
        // 單連線續約
        var one = SleepGuardLedger()
        _ = one.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
        one.acknowledgeWrite(true)
        let renew = one.acquire(connectionID: 1, uid: 1, pid: 1, now: 20, currentSystemValue: false)
        #expect(renew == .externalInterference(shouldRestore: true))
        #expect(one.holders.isEmpty)
        #expect(one.pendingRestore)
        #expect(one.setByHelper)

        // 兩 holder（同／異 uid）：續約或新連線見 0 → 全域清掉，不寫 true
        for secondUID: UInt32 in [501, 502] {
            var ledger = SleepGuardLedger()
            _ = ledger.acquire(connectionID: 1, uid: 501, pid: 1, now: 0, currentSystemValue: false)
            ledger.acknowledgeWrite(true)
            _ = ledger.acquire(connectionID: 2, uid: secondUID, pid: 2, now: 1, currentSystemValue: true)
            #expect(ledger.holders.count == 2)

            let viaRenew = ledger.acquire(
                connectionID: 1, uid: 501, pid: 1, now: 20, currentSystemValue: false
            )
            #expect(viaRenew == .externalInterference(shouldRestore: true))
            #expect(ledger.holders.isEmpty)

            var ledger2 = SleepGuardLedger()
            _ = ledger2.acquire(connectionID: 1, uid: 501, pid: 1, now: 0, currentSystemValue: false)
            ledger2.acknowledgeWrite(true)
            _ = ledger2.acquire(connectionID: 2, uid: secondUID, pid: 2, now: 1, currentSystemValue: true)
            let viaNew = ledger2.acquire(
                connectionID: 3, uid: 503, pid: 3, now: 30, currentSystemValue: false
            )
            #expect(viaNew == .externalInterference(shouldRestore: true))
            #expect(ledger2.holders.isEmpty)
            #expect(ledger2.pendingRestore)
        }

        // foreign session（未擁有）：仍有 holder 時見外部 0 → 干擾、shouldRestore=false、不寫
        for secondUID: UInt32 in [1, 502] {
            var foreignRenew = SleepGuardLedger()
            _ = foreignRenew.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: true)
            #expect(!foreignRenew.setByHelper)
            #expect(foreignRenew.holders.count == 1)
            _ = foreignRenew.acquire(connectionID: 2, uid: secondUID, pid: 2, now: 1, currentSystemValue: true)
            #expect(foreignRenew.holders.count == 2)

            let viaRenew = foreignRenew.acquire(
                connectionID: 1, uid: 1, pid: 1, now: 20, currentSystemValue: false
            )
            #expect(viaRenew == .externalInterference(shouldRestore: false))
            #expect(foreignRenew.holders.isEmpty)
            #expect(!foreignRenew.pendingRestore)
            #expect(!foreignRenew.setByHelper)

            var foreignNew = SleepGuardLedger()
            _ = foreignNew.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: true)
            _ = foreignNew.acquire(connectionID: 2, uid: secondUID, pid: 2, now: 1, currentSystemValue: true)
            let viaNew = foreignNew.acquire(
                connectionID: 3, uid: 503, pid: 3, now: 30, currentSystemValue: false
            )
            #expect(viaNew == .externalInterference(shouldRestore: false))
            #expect(foreignNew.holders.isEmpty)
            #expect(!foreignNew.setByHelper)
        }

        // foreign 干擾後 holders 空：新 acquire 見系統 0 可正常寫 true（C05 仍須先處理通知）
        var afterForeign = SleepGuardLedger()
        _ = afterForeign.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: true)
        _ = afterForeign.acquire(connectionID: 1, uid: 1, pid: 1, now: 20, currentSystemValue: false)
        #expect(afterForeign.holders.isEmpty)
        let reacquire = afterForeign.acquire(
            connectionID: 9, uid: 1, pid: 9, now: 40, currentSystemValue: false
        )
        #expect(reacquire == .write(true))
    }

    @Test("V-C03-6 reconcileOnLaunch four combinations")
    func reconcileMatrix() {
        let cases: [(SleepGuardLedger?, Bool?, SleepGuardLedger.Action, Bool)] = [
            (nil, false, .none, false),
            (SleepGuardLedger(setByHelper: false), false, .none, false),
            (SleepGuardLedger(setByHelper: false), true, .none, false),
            (SleepGuardLedger(setByHelper: true), false, .none, true),
            (SleepGuardLedger(setByHelper: true), true, .write(false), true),
        ]
        for (persisted, system, expectedAction, expectSetByHelper) in cases {
            let (ledger, action) = SleepGuardLedger.reconcileOnLaunch(
                persisted: persisted,
                currentSystemValue: system
            )
            #expect(action == expectedAction)
            #expect(ledger.setByHelper == expectSetByHelper)
            #expect(ledger.holders.isEmpty)
            #expect(!ledger.recoveryBlocked)
        }
    }

    @Test("W0-4 / Fi A8 missing ledger + system 1 → recoveryBlocked; acquire refused")
    func recoveryBlockedMissingLedger() {
        let (blocked, action) = SleepGuardLedger.reconcileOnLaunch(persisted: nil, currentSystemValue: true)
        #expect(action == .recoveryBlocked)
        #expect(blocked.recoveryBlocked)

        var ledger = blocked
        for _ in 0..<3 {
            let acq = ledger.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
            #expect(acq == .recoveryBlocked)
            #expect(ledger.holders.isEmpty)
        }

        // nil system + missing ledger 同樣封鎖
        let (blockedNil, actionNil) = SleepGuardLedger.reconcileOnLaunch(persisted: nil, currentSystemValue: nil)
        #expect(actionNil == .recoveryBlocked)
        #expect(blockedNil.recoveryBlocked)

        // 已知 foreign 帳本保持原行為
        let (foreign, foreignAction) = SleepGuardLedger.reconcileOnLaunch(
            persisted: SleepGuardLedger(priorValueWasDisabled: true, setByHelper: false),
            currentSystemValue: true
        )
        #expect(foreignAction == .none)
        #expect(!foreign.recoveryBlocked)
        #expect(!foreign.setByHelper)

        // nil read 保留既有 recovery 封鎖
        let (retained, retainedAction) = SleepGuardLedger.reconcileOnLaunch(
            persisted: SleepGuardLedger(recoveryBlocked: true),
            currentSystemValue: nil
        )
        #expect(retainedAction == .recoveryBlocked)
        #expect(retained.recoveryBlocked)

        ledger.clearRecoveryBlock()
        #expect(!ledger.recoveryBlocked)
        let after = ledger.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false)
        #expect(after == .write(true))
    }

    @Test("§14.1 nil system value refuses first acquire")
    func nilSystemRefusesFirstAcquire() {
        var ledger = SleepGuardLedger()
        #expect(
            ledger.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: nil)
                == .systemValueUnknown
        )
        #expect(ledger.holders.isEmpty)
    }

    @Test("W0-10 failed write/read/ack and restore-retry preserve pendingRestore")
    func writeAckRestoreRetry() {
        var ledger = SleepGuardLedger()
        #expect(ledger.acquire(connectionID: 1, uid: 1, pid: 1, now: 0, currentSystemValue: false) == .write(true))
        // 寫入失敗：不得把 staged setByHelper 當確認成功清掉
        ledger.noteWriteFailure()
        #expect(ledger.setByHelper)
        #expect(!ledger.pendingRestore)
        ledger.acknowledgeWrite(true)
        #expect(ledger.setByHelper)

        #expect(ledger.release(connectionID: 1, currentSystemValue: true) == .write(false))
        #expect(ledger.pendingRestore)
        #expect(ledger.setByHelper)
        ledger.noteWriteFailure()
        #expect(ledger.pendingRestore)
        #expect(ledger.setByHelper)

        // nil-read during pending restoration：意圖存活，且可再取得 write(false) 重試
        let (nilReadRetry, _) = ledger.expire(now: 100, timeout: 60, currentSystemValue: nil)
        #expect(nilReadRetry == .write(false))
        #expect(ledger.pendingRestore)
        #expect(ledger.setByHelper)

        let forceRetry = ledger.forceOff(currentSystemValue: nil)
        #expect(forceRetry == .write(false))
        #expect(ledger.pendingRestore)
        #expect(ledger.setByHelper)

        // 確認還原後才清 ownership
        ledger.acknowledgeWrite(false)
        #expect(!ledger.setByHelper)
        #expect(!ledger.pendingRestore)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        var ledger = SleepGuardLedger(priorValueWasDisabled: false, setByHelper: true, recoveryBlocked: true)
        _ = ledger.acquire(connectionID: 9, uid: 501, pid: 42, now: 12.5, currentSystemValue: true)
        // recoveryBlocked 擋住 acquire；改為直接塞 holder 測 round-trip
        ledger = SleepGuardLedger(
            holders: [
                9: .init(connectionID: 9, uid: 501, pid: 42, since: 12.5, lastHeartbeat: 12.5)
            ],
            priorValueWasDisabled: false,
            setByHelper: true,
            pendingRestore: true,
            recoveryBlocked: false
        )
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(SleepGuardLedger.self, from: data)
        #expect(decoded == ledger)
    }
}
