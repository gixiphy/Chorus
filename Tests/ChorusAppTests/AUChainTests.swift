import AudioToolbox
import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// AUChainBuilder／AUChainBlock 的真實 AudioToolbox 冒煙測試——用 Apple
/// 內建的 AUDelay（一定在、一定安全）離線驗證整條建鏈→render→拆鏈。
/// 不需要 tap 權限、不碰任何裝置；spike 驗過的行為改由正式碼路徑扛。
@MainActor
@Suite("AU chain (real AudioToolbox)")
struct AUChainTests {
    private var delayEntry: AUEffectEntry {
        AUEffectEntry(
            component: AUEffectComponent(
                type: kAudioUnitType_Effect,
                subtype: kAudioUnitSubType_Delay,
                manufacturer: kAudioUnitManufacturer_Apple
            ),
            name: "AUDelay", manufacturerName: "Apple"
        )
    }

    @Test("建鏈 → render 一個 buffer → 拆鏈；隔離閂順序正確")
    func buildRenderDispose() throws {
        var latched: [String?] = []
        let entry = delayEntry
        let result = AUChainBuilder.build(
            entries: [entry], sampleRate: 48_000, latch: { latched.append($0) }
        )
        #expect(result.failures.isEmpty)
        let block = try #require(result.block)
        defer { AUChainBlock.dispose(block) }
        #expect(latched == [entry.component.key, nil]) // 武裝 → 清空，恰好一輪

        let frames = 512
        let buffers = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames * 4)
        defer { buffers.deallocate() }
        buffers.initialize(repeating: 0)
        let inL = buffers.baseAddress!
        let inR = inL + frames
        let outL = inL + frames * 2
        let outR = inL + frames * 3
        for frame in 0..<frames {
            let sample = Float(sin(Double(frame) * 2 * .pi * 1000 / 48_000) * 0.5)
            inL[frame] = sample
            inR[frame] = sample
        }

        // AUDelay 預設 50% wet：第一個 buffer 就該有非零輸出（dry 分量）
        #expect(AUChainBlock.render(block, inL: inL, inR: inR, outL: outL, outR: outR, frames: frames))
        var peak: Float = 0
        for frame in 0..<frames {
            peak = max(peak, abs(outL[frame]))
        }
        #expect(peak > 0.01)
    }

    @Test("找不到的元件：整格誠實列入 failures、不建鏈")
    func missingComponentFailsHonestly() {
        let ghost = AUEffectEntry(
            component: AUEffectComponent(type: 0x61756678, subtype: 0x6E6F7065, manufacturer: 0x6E6F7065),
            name: "Ghost", manufacturerName: "Nobody"
        )
        let result = AUChainBuilder.build(entries: [ghost], sampleRate: 48_000, latch: { _ in })
        #expect(result.block == nil)
        #expect(result.failures.count == 1)
    }

    @Test("超過 maxFrames 的 buffer 整段旁通（防呆）")
    func oversizedBufferBypasses() throws {
        let result = AUChainBuilder.build(entries: [delayEntry], sampleRate: 48_000, latch: { _ in })
        let block = try #require(result.block)
        defer { AUChainBlock.dispose(block) }
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4)
        defer { scratch.deallocate() }
        scratch.initialize(repeating: 0)
        let base = scratch.baseAddress!
        let rendered = AUChainBlock.render(
            block, inL: base, inR: base + 1, outL: base + 2, outR: base + 3,
            frames: Int(AUChainBlock.maxFrames) + 1
        )
        #expect(!rendered)
    }
}
