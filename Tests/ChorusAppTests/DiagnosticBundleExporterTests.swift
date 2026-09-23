import Foundation
import Testing
@testable import Chorus

@Suite("診斷包匯出")
struct DiagnosticBundleExporterTests {
    @Test("把紀錄檔、diagnostics/ 與 health.json 打成一個 zip")
    func exportsZip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-export-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("chorus.log")
        try "2026-09-23 11:27:44.000 N [app] 啟動\n".write(to: log, atomically: true, encoding: .utf8)
        try "{}".write(to: diagnostics.appendingPathComponent("20260923-032744-000-crash.json"), atomically: true, encoding: .utf8)

        let destination = root.appendingPathComponent("out.zip")
        try DiagnosticBundleExporter.export(
            to: destination, logFiles: [log], diagnosticsDirectory: diagnostics, healthJSON: #"{"ok":true}"#
        )

        let data = try Data(contentsOf: destination)
        #expect(data.count > 100)
        #expect(data.prefix(2) == Data([0x50, 0x4B]))   // "PK"：zip 簽名
        // zip 的 central directory 以明文存檔名
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("chorus.log"))
        #expect(text.contains("health.json"))
        #expect(text.contains("20260923-032744-000-crash.json"))
    }

    @Test("預設檔名帶 build 與時間")
    func fileName() {
        let name = DiagnosticBundleExporter.defaultFileName(build: "116", now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(name.hasPrefix("Chorus-diagnostics-b116-"))
        #expect(name.hasSuffix(".zip"))
    }
}
