import ChorusCore
import Foundation

/// 交給 realtime 執行緒的一塊 EQ 係數。
///
/// **問題**：係數在主執行緒算，在 realtime 執行緒用。realtime 端不能上鎖、
/// 不能配置、不能碰 ARC（PLAN §8-2），所以不能直接傳一個 Swift 陣列或
/// class——`Array` 的取值會碰到 CoW 檢查，class 的取值會 retain／release。
///
/// **作法**：主執行緒把整組係數寫進一塊**手動配置、寫完就不再更動**的
/// 記憶體，然後用一次 atomic store 交出指標。render 端只做「讀指標 →
/// 指標運算」，沒有任何同步原語。
///
/// **回收**：舊的那塊不能立刻釋放——可能正好有一個回呼在讀它。
/// 改由主執行緒延後釋放（`retirementDelay`）。回呼約 10 ms 一次
/// （DESIGN §1 實測），延遲一秒是三個數量級的餘裕。
/// 這比在 realtime 端做引用計數簡單得多，也不會有計數本身的競態。
enum EQCoefficientBlock {
    /// 版本號存在的理由：換一組係數時 biquad 的狀態必須歸零，否則舊狀態
    /// 會用新係數繼續衰減、聽得到一聲。render 端比對版本號來決定要不要
    /// reset——主執行緒沒辦法安全地去清 render 擁有的狀態。
    struct Header {
        var generation: UInt32
        var count: UInt32
        var preamp: Float
    }

    static let coefficientOffset = MemoryLayout<Header>.stride
    static let retirementDelay = Duration.seconds(1)

    static func allocate(
        coefficients: [BiquadCoefficients],
        preamp: Float,
        generation: UInt32
    ) -> UnsafeMutableRawPointer {
        let count = min(coefficients.count, EQSettings.maxBands)
        let bytes = coefficientOffset + count * MemoryLayout<BiquadCoefficients>.stride
        let block = UnsafeMutableRawPointer.allocate(
            byteCount: bytes,
            alignment: max(MemoryLayout<Header>.alignment, MemoryLayout<BiquadCoefficients>.alignment)
        )
        block.bindMemory(to: Header.self, capacity: 1).initialize(
            to: Header(generation: generation, count: UInt32(count), preamp: preamp)
        )
        let slots = (block + coefficientOffset)
            .bindMemory(to: BiquadCoefficients.self, capacity: max(count, 1))
        for index in 0..<count {
            slots[index] = coefficients[index]
        }
        return block
    }

    static func deallocate(_ block: UnsafeMutableRawPointer) {
        block.deallocate()
    }
}
