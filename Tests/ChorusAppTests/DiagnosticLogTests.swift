import Foundation
import Testing
@testable import Chorus

/// 落地的診斷紀錄：格式、輪替、與 `ChorusLog` 的分流（debug 不落地）。
@Suite("診斷紀錄")
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
        let text = try String(contentsOf: sink.fileURL, encoding: .utf8)
        #expect(!text.contains("看不見"))
        #expect(text.contains(" I [taps] 資訊"))
        #expect(text.contains(" N [taps] 通知"))
        #expect(text.contains(" E [taps] 錯誤"))
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
}
