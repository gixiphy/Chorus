import Foundation

/// CLI／HTTP 試用模式的 value 編碼：`WIDTHxHEIGHT@RATE` 或 HiDPI `WIDTHxHEIGHT@RATEpPIXELWxPIXELH`。
public enum DisplayModeValueCoding {
    public static func encode(_ mode: DisplayModeDescriptor) -> String {
        var base = "\(mode.logicalWidth)x\(mode.logicalHeight)@\(formatRate(mode.refreshRate))"
        if mode.pixelWidth != mode.logicalWidth || mode.pixelHeight != mode.logicalHeight {
            base += "p\(mode.pixelWidth)x\(mode.pixelHeight)"
        }
        return base
    }

    public static func decode(_ text: String) -> DisplayModeDescriptor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 1512x982@120p3024x1964 或 1920x1080@60
        let pattern = #"^(\d+)x(\d+)@([0-9]+(?:\.[0-9]+)?)(?:p(\d+)x(\d+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else { return nil }
        func group(_ i: Int) -> String? {
            let range = match.range(at: i)
            guard range.location != NSNotFound, let r = Range(range, in: trimmed) else { return nil }
            return String(trimmed[r])
        }
        guard let w = group(1).flatMap(Int.init),
              let h = group(2).flatMap(Int.init),
              let rate = group(3).flatMap(Double.init)
        else { return nil }
        let pw = group(4).flatMap(Int.init) ?? w
        let ph = group(5).flatMap(Int.init) ?? h
        return DisplayModeDescriptor(
            logicalWidth: w, logicalHeight: h,
            pixelWidth: pw, pixelHeight: ph,
            refreshRate: rate
        )
    }

    private static func formatRate(_ rate: Double) -> String {
        if rate <= 0 { return "0" }
        if rate.rounded() == rate { return String(format: "%.0f", rate) }
        return String(format: "%.2f", rate)
    }
}
