import Testing
@testable import Chorus

/// DDC/CI Get VCP Feature Reply 的框架驗證（AppleSiliconDDC 的本機修改）。
/// 卡死的 DDC controller 會 ACK 讀取卻吐出雜訊或別筆的殘留框架，
/// 偶爾湊巧通過 checksum——這層驗證負責把它們擋下來。
@Suite("DDC reply frame")
struct DDCReplyFrameTests {
    /// 合法的 Get VCP Feature Reply：
    /// [0]=0x6E [1]=0x88 [2]=0x02 [3]=result [4]=VCP echo [5]=型別
    /// [6][7]=max hi/lo [8][9]=current hi/lo [10]=checksum
    private func reply(
        source: UInt8 = 0x6E,
        opcode: UInt8 = 0x02,
        result: UInt8 = 0x00,
        echo: UInt8,
        max: UInt16 = 100,
        current: UInt16 = 50
    ) -> [UInt8] {
        [
            source, 0x88, opcode, result, echo, 0x00,
            UInt8(max >> 8), UInt8(max & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF),
            0x00,
        ]
    }

    @Test("合法框架通過")
    func acceptsWellFormedReply() {
        #expect(AppleSiliconDDC.isValidGetVCPReply(reply(echo: 0x10), command: 0x10))
        #expect(AppleSiliconDDC.isValidGetVCPReply(reply(echo: 0x62), command: 0x62))
    }

    @Test("VCP echo 不符即拒收——這是最關鍵的一道：延遲到達的前一筆回覆會被誤當本次結果")
    func rejectsMismatchedEcho() {
        // 問亮度 0x10、回的卻是音量 0x62 的值
        #expect(!AppleSiliconDDC.isValidGetVCPReply(reply(echo: 0x62), command: 0x10))
        // 問音量 0x62、回的是亮度——音量橋接會因此誤判螢幕不支援 0x62
        #expect(!AppleSiliconDDC.isValidGetVCPReply(reply(echo: 0x10), command: 0x62))
    }

    @Test("result code 非 0 即拒收：螢幕回報不支援此 VCP，資料無意義")
    func rejectsNonZeroResultCode() {
        // 0x01 = Unsupported VCP code
        #expect(!AppleSiliconDDC.isValidGetVCPReply(reply(result: 0x01, echo: 0x10), command: 0x10))
    }

    @Test("來源位址／reply opcode 不符即拒收")
    func rejectsWrongHeader() {
        #expect(!AppleSiliconDDC.isValidGetVCPReply(reply(source: 0x00, echo: 0x10), command: 0x10))
        #expect(!AppleSiliconDDC.isValidGetVCPReply(reply(opcode: 0x00, echo: 0x10), command: 0x10))
    }

    @Test("全零框架拒收——內建面板通道實測會 ACK 讀取並回這種空框架")
    func rejectsNullFrame() {
        #expect(!AppleSiliconDDC.isValidGetVCPReply([UInt8](repeating: 0, count: 11), command: 0x10))
    }

    @Test("長度不足或無 command 即拒收")
    func rejectsShortOrUnknownCommand() {
        #expect(!AppleSiliconDDC.isValidGetVCPReply(Array(reply(echo: 0x10).prefix(10)), command: 0x10))
        #expect(!AppleSiliconDDC.isValidGetVCPReply(reply(echo: 0x10), command: nil))
    }

    /// 長度 byte [1] 刻意不驗：部分螢幕回非標準值，但不影響 [6]–[9] 的取值位置。
    @Test("非標準長度 byte 仍接受")
    func toleratesNonStandardLengthByte() {
        var frame = reply(echo: 0x10)
        frame[1] = 0x00
        #expect(AppleSiliconDDC.isValidGetVCPReply(frame, command: 0x10))
    }
}
