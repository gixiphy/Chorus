import AppKit
import Foundation
import UniformTypeIdentifiers

/// 診斷包：`chorus.log*`、`diagnostics/`、`health.json` 打成一個 zip，使用者附到 GitHub issue。
/// zip 用 `NSFileCoordinator` 的 `.forUploading` 拿——不開子行程，沙盒下也能用。
enum DiagnosticBundleExporter {
    static func defaultFileName(
        build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Chorus-diagnostics-b\(build)-\(formatter.string(from: now)).zip"
    }

    static func export(to destination: URL) throws {
        // 紀錄是背景寫的，先把還在緩衝的行補進檔案
        DiagnosticLog.shared.flush()
        try export(
            to: destination,
            logFiles: DiagnosticLog.shared.existingFiles(),
            diagnosticsDirectory: CrashReportCollector.shared.directory,
            healthJSON: AutomationHTTPTransport.healthJSON()
        )
    }

    static func export(to destination: URL, logFiles: [URL], diagnosticsDirectory: URL, healthJSON: String) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("Chorus-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        for file in logFiles {
            try? manager.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
        }
        if manager.fileExists(atPath: diagnosticsDirectory.path) {
            try? manager.copyItem(at: diagnosticsDirectory, to: staging.appendingPathComponent("diagnostics", isDirectory: true))
        }
        try healthJSON.write(to: staging.appendingPathComponent("health.json"), atomically: true, encoding: .utf8)

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinatorError) { zipURL in
            do {
                try? manager.removeItem(at: destination)
                try manager.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }

    /// 設定頁與選單列共用：存檔面板 → 匯出；失敗寫一行 log 並 beep，不跳 alert 打斷。
    @MainActor
    static func presentSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(to: url)
            ChorusLog.app.notice("已匯出診斷包：\(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            ChorusLog.app.error("匯出診斷包失敗：\(error.localizedDescription)")
            NSSound.beep()
        }
    }
}
