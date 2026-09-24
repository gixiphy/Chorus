import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("ArrangementReportPresentation", .serialized)
struct ArrangementReportPresentationTests {
    @Test("全部套用時顯示已排列視窗數")
    func summaryAllApplied() {
        let report = makeReport(statuses: [.applied, .applied, .applied])

        #expect(report.summaryText == "已排列 3 個視窗")
        #expect(report.outcome == .applied)
    }

    @Test("問題明細最多顯示三行")
    func issueLinesCapped() {
        let report = makeReport(
            statuses: Array(repeating: .failed(reason: "目標視窗已關閉"), count: 5),
            appNames: ["Safari", "Finder", "Terminal", "Xcode", "Mail"]
        )

        #expect(report.issueLines == [
            "Safari：目標視窗已關閉",
            "Finder：目標視窗已關閉",
            "Terminal：目標視窗已關閉",
        ])
    }

    @Test("權限撤銷時回報需要輔助使用權限")
    func permissionOutcome() {
        let report = makeReport(statuses: [
            .skipped(.permissionRevoked),
            .skipped(.permissionRevoked),
        ])

        #expect(report.summaryText == "沒有視窗被移動：需要輔助使用權限")
        #expect(report.outcome == .permissionRequired)
    }

    @Test("回復失敗的文案不能聲稱已還原")
    func revertFailedWording() {
        let report = makeReport(
            arrangement: nil,
            statuses: [.revertFailed(reason: ArrangementReport.timeoutReason)]
        )

        #expect(!report.summaryText.contains("已還原"))
        #expect(!report.issueLines[0].contains("已還原"))
        #expect(report.outcome == .partial)
    }

    @Test("重試時目標已關閉會退化為沒有目標")
    func retryStaleTargetDegrades() {
        let ref = WindowRef(
            token: "w1",
            pid: 101,
            bundleID: "com.example.test",
            appName: "Test"
        )
        let fake = FakeWindowBackend(
            windows: [
                "w1": .init(
                    ref: ref,
                    frame: LayoutRect(x: 100, y: 100, width: 700, height: 600)
                ),
                "w2": .init(
                    ref: WindowRef(
                        token: "w2",
                        pid: 102,
                        bundleID: "com.example.other",
                        appName: "Other"
                    ),
                    frame: LayoutRect(x: 200, y: 100, width: 700, height: 600)
                ),
            ],
            focusedToken: "w1",
            zOrder: ["w2"]
        )
        var now: TimeInterval = 0
        let manager = makeManager(fake: fake) {
            defer { now += 1 }
            return now
        }
        manager.arrange(.leftRight, source: .shortcut)
        #expect(manager.lastReport?.retryable.isEmpty == false)

        fake.windows["w1"] = nil
        manager.retryLastArrangement()

        #expect(manager.lastOutcome == .noTarget)
        #expect(manager.statusMessage == "沒有可排列的視窗")
    }

    private func makeReport(
        arrangement: WindowArrangement? = .threeColumns,
        statuses: [ArrangementReport.Status],
        appNames: [String] = []
    ) -> ArrangementReport {
        ArrangementReport(
            arrangement: arrangement,
            slotCount: statuses.count,
            items: statuses.enumerated().map { index, status in
                ArrangementReport.Item(
                    token: "w\(index)",
                    appName: appNames.indices.contains(index) ? appNames[index] : "App \(index)",
                    target: LayoutRect(x: 0, y: 0, width: 100, height: 100),
                    before: nil,
                    after: nil,
                    status: status
                )
            },
            groupID: arrangement == nil ? UUID() : nil
        )
    }

    private func makeManager(
        fake: FakeWindowBackend,
        now: @escaping () -> TimeInterval = { 100 }
    ) -> WindowManager {
        let defaults = UserDefaults(suiteName: "window-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.windowArrangementEnabled = true
        let visible = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
        return WindowManager(
            settings: settings,
            worker: fake,
            captureTopology: { generation in
                ScreenTopology(
                    generation: generation,
                    screens: [
                        .init(
                            displayUUID: "A",
                            displayID: 1,
                            name: "Main",
                            frame: visible,
                            visibleFrame: visible,
                            isLandscape: true
                        )
                    ],
                    primaryHeight: 900
                )
            },
            now: now
        )
    }
}
