import ChorusCore
import Foundation
import Testing
@testable import Chorus

@Suite("異常結束收集器")
struct CrashReportCollectorTests {
    private struct Fixture {
        let collector: CrashReportCollector
        let diagnostics: URL
        let reports: URL
    }

    private func makeFixture(keep: Int = 20) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-crash-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        let reports = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "chorus-crash-tests-\(UUID().uuidString)")!
        let collector = CrashReportCollector(
            directory: diagnostics, reportsDirectory: reports, defaults: defaults,
            instance: InstanceConfig(arguments: []), keep: keep
        )
        return Fixture(collector: collector, diagnostics: diagnostics, reports: reports)
    }

    private let sampleIPS = """
    {"app_name":"Chorus","timestamp":"2026-09-23 11:27:44.00 +0800","app_version":"1.11.0","build_version":"116","name":"Chorus"}
    {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"faultingThread":0,
     "threads":[{"frames":[{"imageOffset":4096,"imageIndex":0}]}],
     "usedImages":[{"name":"Chorus","uuid":"11111111-2222-3333-4444-555555555555","base":0}]}
    """

    @Test("掃描只收 Chorus-*.ips、只收上次掃描之後的新檔，摘要存進 diagnostics/")
    func scansSystemReports() throws {
        let fixture = try makeFixture()
        try sampleIPS.write(to: fixture.reports.appendingPathComponent("Chorus-2026-09-23-112744.ips"), atomically: true, encoding: .utf8)
        try sampleIPS.write(to: fixture.reports.appendingPathComponent("Other-2026-09-23-112744.ips"), atomically: true, encoding: .utf8)

        #expect(fixture.collector.scanSystemReports() == 1)
        let snapshot = fixture.collector.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot.recent.first?.kind == .ips)
        #expect(snapshot.recent.first?.exception == "EXC_BAD_ACCESS (SIGSEGV)")
        #expect(snapshot.unacknowledged?.kind == .ips)

        // 再掃一次：同一個檔不會重複收
        #expect(fixture.collector.scanSystemReports() == 0)
        #expect(fixture.collector.snapshot().count == 1)

        // envelope 帶原檔路徑
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: fixture.diagnostics.path).first)
        let data = try Data(contentsOf: fixture.diagnostics.appendingPathComponent(file))
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((envelope["sourcePath"] as? String)?.hasSuffix("Chorus-2026-09-23-112744.ips") == true)
    }

    @Test("MetricKit 診斷：整份 JSON 進 envelope，crash 才算未確認；hang 不算")
    func storesDiagnostic() throws {
        let fixture = try makeFixture()
        let json = Data(#"{"diagnosticMetaData":{"appBuildVersion":"116","signal":11},"callStackTree":{"callStacks":[]}}"#.utf8)
        fixture.collector.storeDiagnostic(json, kind: .hang, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(fixture.collector.unacknowledged == nil)
        fixture.collector.storeDiagnostic(json, kind: .crash, at: Date(timeIntervalSince1970: 1_800_000_100))
        let unacknowledged = try #require(fixture.collector.unacknowledged)
        #expect(unacknowledged.kind == .crash)
        #expect(unacknowledged.exception == "signal=11")

        let snapshot = fixture.collector.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.recent.map(\.kind) == [.crash, .hang])   // 新的在前

        let data = try Data(contentsOf: fixture.diagnostics.appendingPathComponent(unacknowledged.fileName))
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let diagnostic = try #require(envelope["diagnostic"] as? [String: Any])
        #expect((diagnostic["diagnosticMetaData"] as? [String: Any])?["appBuildVersion"] as? String == "116")
    }

    /// 這個測試防的是「處理 crash 的過程中自己 crash」。
    ///
    /// MetricKit 的整包 diagnostic 以前會被 parse 成 Foundation 物件再重新
    /// 序列化，而那一步在 crash-reports 那條 queue 上撞過堆疊保護頁
    /// （512 KB，不是主執行緒的 8 MB）。現在原始 bytes 原樣接進 envelope，
    /// 完全不進 Foundation 的寫入器——這裡就釘住「原樣」這件事。
    @Test("MetricKit 的原始 bytes 原樣寫進 envelope，不重新序列化")
    func storesDiagnosticBytesVerbatim() throws {
        let fixture = try makeFixture()
        // 鍵刻意不照字母序，且值裡有空白：有重新序列化就會被 .sortedKeys
        // 重排、空白也會被正規化，位元組比對就對不上了。
        let text = #"""
        {"diagnosticMetaData":{"signal":5,"appBuildVersion":"121"},"callStackTree":{"callStacks":[{"callStackRootFrames":[{"binaryName":"Chorus","subFrames":[{"binaryName":"Chorus"}]}]}]},"zzz":"a  b"}
        """#
        let json = Data(text.utf8)

        fixture.collector.storeDiagnostic(json, kind: .crash, at: Date(timeIntervalSince1970: 1_800_000_200))
        let unacknowledged = try #require(fixture.collector.unacknowledged)

        let written = try Data(contentsOf: fixture.diagnostics.appendingPathComponent(unacknowledged.fileName))
        #expect(written.range(of: json) != nil)

        // 仍是合法 JSON、鍵名沒變——讀取端不必改
        let envelope = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(envelope["summary"] != nil)
        let diagnostic = try #require(envelope["diagnostic"] as? [String: Any])
        #expect((diagnostic["diagnosticMetaData"] as? [String: Any])?["appBuildVersion"] as? String == "121")
    }

    @Test("超過 keep 份就刪最舊")
    func prunes() throws {
        let fixture = try makeFixture(keep: 3)
        let json = Data(#"{"diagnosticMetaData":{}}"#.utf8)
        for index in 0..<5 {
            fixture.collector.storeDiagnostic(json, kind: .hang, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.diagnostics.path).sorted()
        #expect(names.count == 3)
        #expect(names.first?.hasPrefix(CrashReportCollector.fileName(kind: .hang, at: Date(timeIntervalSince1970: 1_800_000_002)).prefix(15)) == true)
    }

    @Test("acknowledge 後同一筆不再是未確認，重建收集器也記得")
    func acknowledges() throws {
        let fixture = try makeFixture()
        let json = Data(#"{"diagnosticMetaData":{}}"#.utf8)
        fixture.collector.storeDiagnostic(json, kind: .crash, at: Date())
        #expect(fixture.collector.unacknowledged != nil)
        fixture.collector.acknowledge()
        #expect(fixture.collector.unacknowledged == nil)
        #expect(fixture.collector.snapshot().unacknowledged == nil)
    }

    @Test("start：哨兵說 crash 但沒有新 .ips → 補一筆 uncleanExit；正常結束不補")
    func uncleanExitFallback() throws {
        let fixture = try makeFixture()
        fixture.collector.start(build: "116")
        fixture.collector.waitForPendingWork()
        #expect(fixture.collector.snapshot().lastExit == .firstLaunch)
        #expect(fixture.collector.snapshot().count == 0)

        // 沒 markCleanExit 就再 start：上次是 crash
        fixture.collector.start(build: "116")
        fixture.collector.waitForPendingWork()
        let snapshot = fixture.collector.snapshot()
        #expect(snapshot.lastExit == .crash)
        #expect(snapshot.recent.first?.kind == .uncleanExit)
        #expect(snapshot.recent.first?.appVersion == "116")

        fixture.collector.markCleanExit(build: "116")
        fixture.collector.start(build: "116")
        fixture.collector.waitForPendingWork()
        #expect(fixture.collector.snapshot().lastExit == .clean)
        #expect(fixture.collector.snapshot().count == 1)
    }
}
