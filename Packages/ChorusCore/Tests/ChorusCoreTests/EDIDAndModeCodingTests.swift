import Testing
@testable import ChorusCore

@Suite("EDIDParser")
struct EDIDParserTests {
    @Test("header 不符回 nil")
    func badHeader() {
        #expect(EDIDParser.parse([UInt8](repeating: 0, count: 128)) == nil)
    }

    @Test("最小合法區塊可解析")
    func minimalBlock() {
        var data = [UInt8](repeating: 0, count: 128)
        data[0] = 0x00; data[1] = 0xFF; data[2] = 0xFF; data[3] = 0xFF
        data[4] = 0xFF; data[5] = 0xFF; data[6] = 0xFF; data[7] = 0x00
        // Manufacturer "ABC" = 00001 00010 00011 → packed
        // A=1, B=2, C=3 → (1<<10)|(2<<5)|3 = 0x0443
        data[8] = 0x04; data[9] = 0x43
        data[16] = 1; data[17] = 30 // week 1, year 2020
        data[21] = 60; data[22] = 34
        // checksum
        let sum = data.prefix(127).reduce(0) { $0 + Int($1) }
        data[127] = UInt8((256 - (sum & 0xFF)) & 0xFF)

        let parsed = EDIDParser.parse(data)
        #expect(parsed != nil)
        #expect(parsed?.manufacturerID == "ABC")
        #expect(parsed?.widthCm == 60)
        #expect(parsed?.heightCm == 34)
        #expect(parsed?.yearOfManufacture == 2020)
        #expect(parsed?.checksumOK == true)
    }
}

@Suite("DisplayModeValueCoding")
struct DisplayModeValueCodingTests {
    @Test("往返編碼")
    func roundTrip() {
        let mode = DisplayModeDescriptor(
            logicalWidth: 1512, logicalHeight: 982,
            pixelWidth: 3024, pixelHeight: 1964,
            refreshRate: 120
        )
        let text = DisplayModeValueCoding.encode(mode)
        let decoded = DisplayModeValueCoding.decode(text)
        #expect(decoded.map { $0.matches(mode) } == true)
    }

    @Test("低解析度無 p 後綴")
    func lowRes() {
        let mode = DisplayModeDescriptor(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 1920, pixelHeight: 1080,
            refreshRate: 60
        )
        #expect(DisplayModeValueCoding.encode(mode) == "1920x1080@60")
    }
}
