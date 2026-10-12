import ChorusCore
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

    @Test("V-C10-1 診斷包附 helper-status.json 且不含 uid／pid")
    func helperStatusAttachmentHasNoUIDOrPID() throws {
        let status = PowerHelperStatus(
            helperBuild: "136",
            sleepDisabled: true,
            setByHelper: true,
            holderCount: 2,
            callerIsHolder: true,
            otherUsersHolding: false,
            lastForcedOffReason: "thermal",
            recoveryBlocked: false,
            pendingRestore: false,
            persistRetryNeeded: false
        )
        let json = DiagnosticBundleExporter.encodeHelperStatusAttachment(
            availability: "ready",
            status: status,
            leftover: nil
        )
        #expect(json != nil)
        let text = try #require(json)
        #expect(!text.contains("\"uid\""))
        #expect(!text.contains("\"pid\""))
        #expect(!text.contains("uid="))
        #expect(!text.contains("pid="))
        #expect(text.contains("\"holderCount\":2"))
        #expect(text.contains("\"sleepDisabled\":true"))
        #expect(text.contains("\"availability\":\"ready\""))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-export-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("chorus.log")
        try "log\n".write(to: log, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("out.zip")
        try DiagnosticBundleExporter.export(
            to: destination,
            logFiles: [log],
            diagnosticsDirectory: diagnostics,
            healthJSON: #"{"ok":true}"#,
            helperStatusJSON: text
        )
        // 檔名在 zip local/central header 是明文；內容可能被 deflate，不在 zip bytes 裡找 JSON 欄位。
        let zipText = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        #expect(zipText.contains(DiagnosticBundleExporter.helperStatusFileName))
    }

    @Test("V-C10-2 helper attachment 消毒 forcedOff reason 中的 path／token")
    func helperAttachmentSanitizesReasons() throws {
        let status = PowerHelperStatus(
            helperBuild: "136",
            lastForcedOffReason: "path=/tmp/secret token=abc123"
        )
        let json = try #require(
            DiagnosticBundleExporter.encodeHelperStatusAttachment(
                availability: "ready",
                status: status,
                leftover: "foreign"
            )
        )
        #expect(!json.contains("/tmp/secret"))
        #expect(!json.contains("abc123"))
        #expect(json.contains("leftover"))
        let decoded = try JSONDecoder().decode(
            DiagnosticBundleExporter.HelperStatusAttachment.self,
            from: Data(json.utf8)
        )
        #expect(decoded.leftover == "foreign")
        #expect(decoded.lastForcedOffReason?.contains("<path>") == true
            || decoded.lastForcedOffReason?.contains("<redacted>") == true)
    }

    @Test("V-C10-2 allowlist 解碼：缺少 optional 欄位仍可解")
    func oldAttachmentJSONCompatible() throws {
        let data = Data(#"{"availability":"ready","holderCount":1}"#.utf8)
        let decoded = try JSONDecoder().decode(
            DiagnosticBundleExporter.HelperStatusAttachment.self,
            from: data
        )
        #expect(decoded.availability == "ready")
        #expect(decoded.holderCount == 1)
        #expect(decoded.sleepDisabled == nil)
        #expect(decoded.recoveryBlocked == nil)
        #expect(decoded.leftover == nil)
    }
}
