import AppKit
import ChorusCore
import Foundation
import UniformTypeIdentifiers

/// 診斷包：`chorus.log*`、`diagnostics/`、`health.json`、可選 `helper-status.json` 打成一個 zip。
/// zip 用 `NSFileCoordinator` 的 `.forUploading` 拿——不開子行程，沙盒下也能用。
enum DiagnosticBundleExporter {
    /// 診斷包內 helper 狀態檔名（allowlist JSON，不含 uid／pid）。
    static let helperStatusFileName = "helper-status.json"

    static func defaultFileName(
        build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Chorus-diagnostics-b\(build)-\(formatter.string(from: now)).zip"
    }

    @MainActor
    static func export(to destination: URL) throws {
        // 紀錄是背景寫的，先把還在緩衝的行補進檔案
        DiagnosticLog.shared.flush()
        try export(
            to: destination,
            logFiles: DiagnosticLog.shared.existingFiles(),
            diagnosticsDirectory: CrashReportCollector.shared.directory,
            healthJSON: AutomationHTTPTransport.healthJSON(),
            helperStatusJSON: currentHelperStatusJSON()
        )
    }

    static func export(
        to destination: URL,
        logFiles: [URL],
        diagnosticsDirectory: URL,
        healthJSON: String,
        helperStatusJSON: String? = nil
    ) throws {
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
        if let helperStatusJSON {
            try helperStatusJSON.write(
                to: staging.appendingPathComponent(helperStatusFileName),
                atomically: true,
                encoding: .utf8
            )
        }

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

    // MARK: - Helper status attachment（§8.4／§14.3 allowlist）

    /// 從目前 App 快取組出消毒後的 helper status JSON；無 keepAwake 時回 nil。
    @MainActor
    static func currentHelperStatusJSON() -> String? {
        guard let keepAwake = AppStateRegistry.keepAwake else { return nil }
        let lid = keepAwake.lidGuard
        return encodeHelperStatusAttachment(
            availability: DoctorInputsCollector.helperAvailabilityWire(
                phase: lid.phase,
                helperStatus: lid.helperStatus,
                leftover: lid.leftover
            ),
            status: lid.helperStatus,
            leftover: lid.leftover.map(DoctorInputsCollector.leftoverWire)
        )
    }

    /// 診斷 export 專用 allowlist：只有計數與旗標，不含 uid／pid／path／token。
    static func encodeHelperStatusAttachment(
        availability: String?,
        status: PowerHelperStatus?,
        leftover: String? = nil
    ) -> String? {
        guard availability != nil || status != nil || leftover != nil else { return nil }
        let attachment = HelperStatusAttachment(
            availability: availability.map(DoctorInputsCollector.sanitizeDoctorText),
            sleepDisabled: status?.sleepDisabled,
            setByHelper: status?.setByHelper,
            holderCount: status?.holderCount,
            callerIsHolder: status?.callerIsHolder,
            otherUsersHolding: status?.otherUsersHolding,
            lastForcedOffReason: status?.lastForcedOffReason.map(DoctorInputsCollector.sanitizeDoctorText),
            recoveryBlocked: status?.recoveryBlocked,
            pendingRestore: status?.pendingRestore,
            persistRetryNeeded: status?.persistRetryNeeded,
            protocolVersion: status?.protocolVersion,
            helperBuild: status?.helperBuild,
            leftover: leftover
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(attachment),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Allowlisted helper status for diagnostic zip（V-C10-1／V-C10-2／S-11）。
    struct HelperStatusAttachment: Codable, Equatable, Sendable {
        var availability: String?
        var sleepDisabled: Bool?
        var setByHelper: Bool?
        var holderCount: Int?
        var callerIsHolder: Bool?
        var otherUsersHolding: Bool?
        var lastForcedOffReason: String?
        var recoveryBlocked: Bool?
        var pendingRestore: Bool?
        var persistRetryNeeded: Bool?
        var protocolVersion: Int?
        var helperBuild: String?
        var leftover: String?
    }
}
