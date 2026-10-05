/// `chorus doctor` 的終端機輸出。嚴重的排前面；同級維持規則給的順序。
public enum DoctorFormatter {
    public static func render(_ report: DoctorReport) -> String {
        let ordered = report.checks.enumerated().sorted {
            ($0.element.status.severity, -$0.offset) > ($1.element.status.severity, -$1.offset)
        }.map(\.element)
        var lines: [String] = []
        for check in ordered {
            var line = "\(symbol(check.status)) \(check.title)"
            if let detail = check.detail { line += " — \(detail)" }
            lines.append(line)
            if let remedy = check.remedy, check.status != .ok {
                lines.append("   → \(remedy)")
            }
        }
        let errors = report.checks.filter { $0.status == .error }.count
        let warnings = report.checks.filter { $0.status.severity == DoctorCheck.Status.warning.severity }.count
        lines.append("")
        lines.append(errors + warnings == 0 ? "沒有發現問題。" : "\(errors) 個錯誤、\(warnings) 個警告。")
        return lines.joined(separator: "\n")
    }

    private static func symbol(_ status: DoctorCheck.Status) -> String {
        switch status {
        case .ok: "✓"
        case .info: "ℹ"
        case .error: "✗"
        default: "⚠"
        }
    }
}
