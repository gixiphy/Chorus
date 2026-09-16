import Testing
@testable import ChorusCore

@Suite("BrightnessReconcile")
struct BrightnessReconcileTests {
    private let reconcile = BrightnessReconcile()

    @Test("相同讀值忽略")
    func sameValueIgnored() {
        let decision = reconcile.decide(
            modelBrightness: 0.5,
            actual: 0.504,
            source: .poll,
            localWrite: nil,
            now: .zero,
            autoHandled: false
        )
        #expect(decision == .ignore)
    }

    @Test("原生鍵讀回廣播")
    func nativeKeyBroadcasts() {
        let decision = reconcile.decide(
            modelBrightness: 0.5,
            actual: 0.6,
            source: .nativeKey,
            localWrite: nil,
            now: .zero,
            autoHandled: false
        )
        #expect(decision == .accept(broadcast: true))
    }

    @Test("auto 已處理則不廣播")
    func autoHandledNoBroadcast() {
        let decision = reconcile.decide(
            modelBrightness: 0.5,
            actual: 0.6,
            source: .poll,
            localWrite: nil,
            now: .zero,
            autoHandled: true
        )
        #expect(decision == .accept(broadcast: false))
    }

    @Test("本機寫入後朝目標收斂的中間值忽略")
    func localWriteSettleIgnoresIntermediate() {
        let write = BrightnessReconcile.LocalWrite(target: 0.8, writtenAt: .zero)
        let decision = reconcile.decide(
            modelBrightness: 0.5,
            actual: 0.65,
            source: .poll,
            localWrite: write,
            now: .milliseconds(100),
            autoHandled: false
        )
        #expect(decision == .ignore)
    }

    @Test("本機寫入收斂完成只更新不廣播")
    func localWriteSettledNoBroadcast() {
        let write = BrightnessReconcile.LocalWrite(target: 0.8, writtenAt: .zero)
        let decision = reconcile.decide(
            modelBrightness: 0.5,
            actual: 0.8,
            source: .nativeKey,
            localWrite: write,
            now: .milliseconds(100),
            autoHandled: false
        )
        #expect(decision == .accept(broadcast: false))
    }
}
