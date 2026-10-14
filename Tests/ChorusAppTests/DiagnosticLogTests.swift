import Foundation
import Testing
@testable import Chorus

/// 落地的診斷紀錄：格式、輪替、與 `ChorusLog` 的分流（debug 不落地）。
@Suite("診斷紀錄", .timeLimit(.minutes(1)))
struct DiagnosticLogTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("一行一筆：時間戳、等級、類別、訊息；換行被壓平")
    func lineFormat() throws {
        let directory = try makeDirectory()
        let log = DiagnosticLog(directory: directory)
        log.write(level: .notice, category: "focus", message: "限時場景開始\n第二行")
        #expect(log.flush())
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix(" N [focus] 限時場景開始⏎第二行"))
        // 「2026-09-02 12:49:30.276 」是 24 個字
        #expect(lines[0].count == 24 + " N [focus] 限時場景開始⏎第二行".count - 1)
    }

    @Test("超過上限就輪替：現用檔重新開始，舊的往後推、最舊的丟掉")
    func rotation() throws {
        let directory = try makeDirectory()
        let log = DiagnosticLog(directory: directory, maxBytes: 120, keep: 3)
        for index in 0..<12 {
            log.write(level: .info, category: "t", message: "line \(index)")
        }
        #expect(log.flush())
        let files = log.existingFiles().map(\.lastPathComponent)
        #expect(files == ["chorus.log", "chorus.1.log", "chorus.2.log"])
        let current = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(current.utf8.count <= 120)
        // 全部檔案加起來也不會超過三輪的量
        let total = try log.existingFiles()
            .map { try Data(contentsOf: $0).count }
            .reduce(0, +)
        #expect(total <= 120 * 3)
        // 最新的一行在現用檔裡
        #expect(current.contains("line 11"))
    }

    @Test("ChorusLog：notice/info/error 落地，debug 只走 os_log")
    func forwarding() throws {
        let directory = try makeDirectory()
        let sink = DiagnosticLog(directory: directory)
        let log = ChorusLog(category: "taps", sink: sink)
        log.debug("看不見")
        log.info("資訊")
        log.notice("通知")
        log.error("錯誤")
        #expect(sink.flush())
        let text = try String(contentsOf: sink.fileURL, encoding: .utf8)
        #expect(!text.contains("看不見"))
        #expect(text.contains(" I [taps] 資訊"))
        #expect(text.contains(" N [taps] 通知"))
        #expect(text.contains(" E [taps] 錯誤"))
    }

    @Test("磁碟卡住時寫紀錄不阻塞；緩衝滿了丟一般訊息、留 error，並記下丟棄數")
    func stuckDiskDoesNotBlock() throws {
        let directory = try makeDirectory()
        let faults = FaultRegistry(hangLimit: .seconds(10))
        let log = DiagnosticLog(
            directory: directory,
            limits: .init(maxLines: 50, maxBytes: 100_000, reservedErrorLines: 5),
            faults: faults
        )
        faults.set(.logWrite, .hang)

        let started = ContinuousClock.now
        for index in 0..<2_000 {
            log.write(level: .info, category: "t", message: "line \(index)")
        }
        log.write(level: .error, category: "t", message: "重要錯誤")
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!log.flush(timeout: .milliseconds(100)))

        faults.set(.logWrite, nil)
        #expect(log.flush())
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(text.contains("重要錯誤"))
        #expect(text.contains("紀錄緩衝已滿，丟棄"))
        #expect(text.split(separator: "\n").count < 200)
    }

    @Test("測試行程寫暫存目錄，不碰使用者的 ~/Library/Logs")
    func testProcessUsesTemporaryDirectory() {
        let underTest = DiagnosticLog.defaultDirectory(environment: ["XCTestBundlePath": "/x"])
        #expect(underTest.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let real = DiagnosticLog.defaultDirectory(environment: [:])
        #expect(real.path.hasSuffix("/Library/Logs/Chorus"))
    }

    @Test("同機多實例各寫各的檔")
    func instanceFileName() {
        #expect(DiagnosticLog.defaultFileName(instance: InstanceConfig(arguments: [])) == "chorus.log")
        #expect(DiagnosticLog.defaultFileName(instance: InstanceConfig(arguments: ["--instance", "b"])) == "chorus-b.log")
    }

    @Test("事件 API：notice/info/error 落地含事件名與欄位；debug 不落地")
    func eventLevelRouting() throws {
        let directory = try makeDirectory()
        let sink = DiagnosticLog(directory: directory)
        let log = ChorusLog(category: "display", sink: sink)

        log.event(
            KeepAwakeLogEvent.assertionCreated,
            level: .notice,
            fields: ["type": "display", "id": "42"]
        )
        log.event(
            KeepAwakeLogEvent.throttleSummary,
            level: .debug,
            fields: ["triggered": "100", "executed": "5"]
        )
        log.event(
            KeepAwakeLogEvent.idleBlank,
            level: .info,
            fields: ["reason": "idle"]
        )
        log.event(
            KeepAwakeLogEvent.assertionReleased,
            level: .error,
            fields: ["type": "system"]
        )

        #expect(sink.flush(timeout: .seconds(5)))
        let text = try String(contentsOf: sink.fileURL, encoding: .utf8)
        #expect(text.contains(" N [display] event=\(KeepAwakeLogEvent.assertionCreated)"))
        #expect(text.contains("type=display"))
        #expect(text.contains("id=42"))
        #expect(!text.contains(KeepAwakeLogEvent.throttleSummary))
        #expect(!text.contains("triggered=100"))
        #expect(text.contains(" I [display] event=\(KeepAwakeLogEvent.idleBlank)"))
        #expect(text.contains("reason=idle"))
        #expect(text.contains(" E [display] event=\(KeepAwakeLogEvent.assertionReleased)"))
        #expect(text.contains("type=system"))
    }

    @Test("keepawake 事件名常數固定，供 P1/P2/P4 共用")
    func keepAwakeEventNames() {
        #expect(KeepAwakeLogEvent.assertionCreated == "keepawake.assertion.created")
        #expect(KeepAwakeLogEvent.assertionReleased == "keepawake.assertion.released")
        #expect(KeepAwakeLogEvent.assertionRecreated == "keepawake.assertion.recreated")
        #expect(KeepAwakeLogEvent.throttleSummary == "keepawake.throttle.summary")
        #expect(KeepAwakeLogEvent.idleBlank == "keepawake.idle.blank")
        #expect(KeepAwakeLogEvent.idleRestore == "keepawake.idle.restore")
    }

    @Test("事件欄位格式穩定：依鍵名排序，CR／LF 被壓平")
    func eventFormatIsStable() {
        let line = ChorusLog.formatEvent(
            name: "keepawake.assertion.created",
            fields: ["b": "two\nlines", "a": "one", "c": "x\r\ny\rz"]
        )
        #expect(line == "event=keepawake.assertion.created a=one b=two⏎lines c=x⏎y⏎z")
        // 依鍵名而非整段 `k=v` 字串排序：`a` 必須排在 `a-b` 前。
        let keyed = ChorusLog.formatEvent(name: "e", fields: ["a-b": "2", "a": "1"])
        #expect(keyed == "event=e a=1 a-b=2")
    }
}
