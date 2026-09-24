import Testing
@testable import ChorusCore

@Suite("ArrangementReport")
struct ArrangementReportTests {
    private let target = LayoutRect(x: 0, y: 0, width: 100, height: 100)

    private func item(
        token: String,
        status: ArrangementReport.Status,
        before: LayoutRect? = nil,
        after: LayoutRect? = nil
    ) -> ArrangementReport.Item {
        ArrangementReport.Item(
            token: token,
            appName: token,
            target: target,
            before: before,
            after: after,
            status: status
        )
    }

    @Test("全部 applied：isComplete、appliedCount＝items.count、retryable 空")
    func allApplied() {
        let report = ArrangementReport(
            arrangement: .threeColumns,
            slotCount: 3,
            items: [
                item(token: "a", status: .applied),
                item(token: "b", status: .applied),
                item(token: "c", status: .applied),
            ],
            groupID: nil
        )
        #expect(report.isComplete)
        #expect(report.appliedCount == 3)
        #expect(report.retryable.isEmpty)
        #expect(report.failedItems.isEmpty)
    }

    @Test("constrained 算已排列但另計 constrainedCount")
    func constrainedCounts() {
        let report = ArrangementReport(
            arrangement: .leftRight,
            slotCount: 2,
            items: [
                item(token: "a", status: .applied),
                item(token: "b", status: .constrained),
            ],
            groupID: nil
        )
        #expect(report.appliedCount == 2)
        #expect(report.constrainedCount == 1)
        #expect(report.isComplete)
    }

    @Test("timeout 失敗與 timeBudget／topologyChanged skip 可重試；unsupported 與 permissionRevoked 不可")
    func retryable() {
        let report = ArrangementReport(
            arrangement: .threeColumns,
            slotCount: 5,
            items: [
                item(token: "a", status: .applied),
                item(token: "b", status: .failed(reason: ArrangementReport.timeoutReason)),
                item(token: "c", status: .skipped(.timeBudget)),
                item(token: "d", status: .skipped(.topologyChanged)),
                item(token: "e", status: .failed(reason: "unsupported")),
                item(token: "f", status: .skipped(.permissionRevoked)),
            ],
            groupID: nil
        )
        #expect(report.retryable.map(\.token) == ["b", "c", "d"])
    }

    @Test("revertFailed 算有動到視窗，reverted 不算")
    func didMoveAnyWindow() {
        let reverted = ArrangementReport(
            arrangement: nil,
            slotCount: 1,
            items: [item(token: "a", status: .reverted(reason: "timeout"))],
            groupID: nil
        )
        #expect(!reverted.didMoveAnyWindow)

        let revertFailed = ArrangementReport(
            arrangement: nil,
            slotCount: 1,
            items: [item(token: "a", status: .revertFailed(reason: "timeout"))],
            groupID: nil
        )
        #expect(revertFailed.didMoveAnyWindow)
    }

    @Test("emptySlots ＝ 格數 − 視窗數，不會小於 0")
    func emptySlots() {
        let under = ArrangementReport(
            arrangement: .threeColumns,
            slotCount: 3,
            items: [item(token: "a", status: .applied)],
            groupID: nil
        )
        #expect(under.emptySlots == 2)

        let over = ArrangementReport(
            arrangement: .leftRight,
            slotCount: 2,
            items: [
                item(token: "a", status: .applied),
                item(token: "b", status: .applied),
                item(token: "c", status: .applied),
            ],
            groupID: nil
        )
        #expect(over.emptySlots == 0)
    }
}
