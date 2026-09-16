import Testing
@testable import ChorusCore

@Suite("DisplayModeDescriptor")
struct DisplayModeDescriptorTests {
    @Test("HiDPI 由像素／邏輯比例判定")
    func hiDPIScale() {
        let retina = DisplayModeDescriptor(
            logicalWidth: 1512, logicalHeight: 982,
            pixelWidth: 3024, pixelHeight: 1964,
            refreshRate: 120
        )
        #expect(retina.isHiDPI)
        #expect(abs(retina.scaleFactor - 2) < 0.01)
        #expect(retina.summary.contains("HiDPI"))

        let low = DisplayModeDescriptor(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 1920, pixelHeight: 1080,
            refreshRate: 60
        )
        #expect(!low.isHiDPI)
    }

    @Test("0Hz 不寫成 60")
    func zeroRefresh() {
        let mode = DisplayModeDescriptor(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 1920, pixelHeight: 1080,
            refreshRate: 0
        )
        #expect(!mode.summary.contains("60"))
        #expect(!mode.summary.contains("Hz"))
    }

    @Test("去重保留不同更新率與縮放")
    func dedupeKeepsRefreshAndScale() {
        let a = DisplayModeDescriptor(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 1920, pixelHeight: 1080,
            refreshRate: 60
        )
        let b = DisplayModeDescriptor(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 1920, pixelHeight: 1080,
            refreshRate: 120
        )
        let c = DisplayModeDescriptor(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60
        )
        let d = DisplayModeDescriptor(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 1920, pixelHeight: 1080,
            refreshRate: 60.1
        )
        let unique = DisplayModeCatalog.dedupe([a, b, c, d, a])
        #expect(unique.count == 3)
    }

    @Test("偏好解析找不到時回 nil")
    func resolveMissing() {
        let pref = DisplayModeDescriptor(
            logicalWidth: 2560, logicalHeight: 1440,
            pixelWidth: 2560, pixelHeight: 1440,
            refreshRate: 144
        )
        let available = [
            DisplayModeDescriptor(
                logicalWidth: 1920, logicalHeight: 1080,
                pixelWidth: 1920, pixelHeight: 1080,
                refreshRate: 60
            )
        ]
        #expect(DisplayModeCatalog.resolve(preference: pref, in: available) == nil)
    }
}

@Suite("DisplayModeTransactionPolicy")
struct DisplayModeTransactionPolicyTests {
    private var policy = DisplayModeTransactionPolicy(confirmationDuration: .seconds(15))

    private let original = DisplayModeDescriptor(
        logicalWidth: 1920, logicalHeight: 1080,
        pixelWidth: 1920, pixelHeight: 1080,
        refreshRate: 60
    )
    private let candidate = DisplayModeDescriptor(
        logicalWidth: 2560, logicalHeight: 1440,
        pixelWidth: 2560, pixelHeight: 1440,
        refreshRate: 60
    )

    @Test("成功路徑：套用 → 確認 → idle")
    func confirmPath() {
        var state = DisplayModeTransactionPolicy.State()
        let begin = policy.beginTrial(
            state: &state,
            displayUUID: "u1",
            topologyGeneration: 1,
            original: original,
            candidate: candidate,
            now: .zero
        )
        #expect(begin == .applyCandidate)
        #expect(state.phase == .applying)

        let waiting = policy.applySucceeded(state: &state, now: .seconds(1))
        #expect(waiting == .scheduleDeadline(at: .seconds(16)))
        #expect(state.phase == .awaitingConfirmation)

        let done = policy.confirm(state: &state)
        #expect(done == .finished(.confirmed))
        #expect(state.phase == .idle)
    }

    @Test("逾時進入還原")
    func timeoutReverts() {
        var state = DisplayModeTransactionPolicy.State()
        _ = policy.beginTrial(
            state: &state, displayUUID: "u1", topologyGeneration: 1,
            original: original, candidate: candidate, now: .zero
        )
        _ = policy.applySucceeded(state: &state, now: .zero)
        let action = policy.deadlineReached(state: &state, now: .seconds(15))
        #expect(action == .revertToOriginal)
        #expect(state.phase == .reverting)
    }

    @Test("進行中再試用回 busy")
    func busyWhileActive() {
        var state = DisplayModeTransactionPolicy.State()
        _ = policy.beginTrial(
            state: &state, displayUUID: "u1", topologyGeneration: 1,
            original: original, candidate: candidate, now: .zero
        )
        _ = policy.applySucceeded(state: &state, now: .zero)
        let again = policy.beginTrial(
            state: &state, displayUUID: "u1", topologyGeneration: 1,
            original: original, candidate: candidate, now: .seconds(1)
        )
        #expect(again == .rejectedBusy)
        #expect(state.phase == .awaitingConfirmation)
    }

    @Test("外部切模式不強行覆蓋")
    func externalReplace() {
        var state = DisplayModeTransactionPolicy.State()
        _ = policy.beginTrial(
            state: &state, displayUUID: "u1", topologyGeneration: 1,
            original: original, candidate: candidate, now: .zero
        )
        _ = policy.applySucceeded(state: &state, now: .zero)
        let other = DisplayModeDescriptor(
            logicalWidth: 1280, logicalHeight: 720,
            pixelWidth: 1280, pixelHeight: 720,
            refreshRate: 60
        )
        let action = policy.noteExternalMode(state: &state, actual: other)
        #expect(action == .finished(.externallyReplaced))
    }
}
