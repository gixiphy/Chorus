/// EDID 區塊解析（純資料）。完整原始位元組不進預設診斷匯出。
public struct EDIDSummary: Sendable, Hashable, Equatable, Codable {
    public var manufacturerID: String?
    public var productCode: UInt16?
    public var weekOfManufacture: UInt8?
    public var yearOfManufacture: Int?
    /// 公分；解析失敗為 nil。
    public var widthCm: Int?
    public var heightCm: Int?
    public var displayName: String?
    public var blockCount: Int
    public var checksumOK: Bool
    public var extensionCount: Int

    public init(
        manufacturerID: String? = nil,
        productCode: UInt16? = nil,
        weekOfManufacture: UInt8? = nil,
        yearOfManufacture: Int? = nil,
        widthCm: Int? = nil,
        heightCm: Int? = nil,
        displayName: String? = nil,
        blockCount: Int = 0,
        checksumOK: Bool = false,
        extensionCount: Int = 0
    ) {
        self.manufacturerID = manufacturerID
        self.productCode = productCode
        self.weekOfManufacture = weekOfManufacture
        self.yearOfManufacture = yearOfManufacture
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.displayName = displayName
        self.blockCount = blockCount
        self.checksumOK = checksumOK
        self.extensionCount = extensionCount
    }

    public var summaryLine: String {
        var parts: [String] = []
        if let name = displayName, !name.isEmpty { parts.append(name) }
        if let mfg = manufacturerID { parts.append(mfg) }
        if let w = widthCm, let h = heightCm { parts.append("\(w)×\(h) cm") }
        if !checksumOK { parts.append("checksum?") }
        return parts.isEmpty ? "unknown" : parts.joined(separator: " · ")
    }
}

public enum EDIDParser {
    /// 解析一或多個 128-byte EDID 區塊。長度不足或 header 不符回 nil。
    public static func parse(_ data: [UInt8]) -> EDIDSummary? {
        guard data.count >= 128 else { return nil }
        guard data[0] == 0x00, data[1] == 0xFF, data[2] == 0xFF, data[3] == 0xFF,
              data[4] == 0xFF, data[5] == 0xFF, data[6] == 0xFF, data[7] == 0x00
        else { return nil }

        let blockCount = data.count / 128
        var checksumOK = true
        for block in 0..<blockCount {
            let start = block * 128
            let slice = Array(data[start..<(start + 128)])
            let sum = slice.reduce(0) { ($0 + Int($1)) & 0xFF }
            if sum != 0 { checksumOK = false }
        }

        let mfg = manufacturerID(data[8], data[9])
        let product = UInt16(data[10]) | (UInt16(data[11]) << 8)
        let week = data[16]
        let year = 1990 + Int(data[17])
        let widthCm = Int(data[21])
        let heightCm = Int(data[22])
        let extensionCount = Int(data[126])
        let name = descriptorName(in: Array(data[0..<128]))

        return EDIDSummary(
            manufacturerID: mfg,
            productCode: product,
            weekOfManufacture: week == 0xFF ? nil : week,
            yearOfManufacture: year,
            widthCm: widthCm > 0 ? widthCm : nil,
            heightCm: heightCm > 0 ? heightCm : nil,
            displayName: name,
            blockCount: blockCount,
            checksumOK: checksumOK,
            extensionCount: extensionCount
        )
    }

    private static func manufacturerID(_ hi: UInt8, _ lo: UInt8) -> String? {
        let value = (UInt16(hi) << 8) | UInt16(lo)
        guard value != 0 else { return nil }
        let c1 = Character(UnicodeScalar(64 + Int((value >> 10) & 0x1F))!)
        let c2 = Character(UnicodeScalar(64 + Int((value >> 5) & 0x1F))!)
        let c3 = Character(UnicodeScalar(64 + Int(value & 0x1F))!)
        return String([c1, c2, c3])
    }

    /// Descriptor type 0xFC = monitor name。
    private static func descriptorName(in block: [UInt8]) -> String? {
        guard block.count >= 128 else { return nil }
        for offset in stride(from: 54, through: 108, by: 18) {
            let desc = Array(block[offset..<(offset + 18)])
            guard desc[0] == 0, desc[1] == 0, desc[2] == 0, desc[3] == 0xFC else { continue }
            let raw = desc[5..<18].prefix { $0 != 0x0A && $0 != 0x00 }
            let name = String(bytes: raw, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
        }
        return nil
    }
}
