import Foundation
import Testing
@testable import Chorus

/// 光環境建議的「套用前原始配置」：逐螢幕累積、保留第一次的原值、
/// 舊版快照格式照樣解得開。
@Suite("Advice baseline")
struct AdviceBaselineTests {
    @Test("連續套用保留第一次套用前的原值")
    func keepsFirstOriginal() {
        var baseline = AdviceBaseline()
        baseline.recordLocal("A", original: 0)
        baseline.recordMaxLux(500)
        // 第二次套用：A 的「現值」已是第一次的建議值，不能蓋掉原值
        baseline.recordLocal("A", original: -0.2)
        baseline.recordLocal("B", original: 0.1)
        baseline.recordMaxLux(800)
        baseline.recordRemote("peer|display:X", original: 0.05)
        baseline.recordRemote("peer|display:X", original: -0.1)

        #expect(baseline.displayOffsets == ["A": 0, "B": 0.1])
        #expect(baseline.remoteOffsets == ["peer|display:X": 0.05])
        #expect(baseline.maxLux == 500)
        #expect(baseline.minBrightness == nil)
    }

    @Test("節點鍵：本機在前、遠端在後，各自排序")
    func displayIDs() {
        var baseline = AdviceBaseline()
        baseline.recordRemote("p|display:Z", original: 0)
        baseline.recordLocal("B", original: 0)
        baseline.recordLocal("A", original: 0)
        #expect(baseline.displayIDs == ["display:A", "display:B", "remote:p|display:Z"])
    }

    @Test("只記曲線或只記螢幕都不算空")
    func emptiness() {
        var baseline = AdviceBaseline()
        #expect(baseline.isEmpty)
        baseline.recordMinBrightness(0.1)
        #expect(!baseline.isEmpty && baseline.hasCurve)
        baseline.minBrightness = nil
        #expect(baseline.isEmpty)
        baseline.recordLocal("A", original: 0)
        #expect(!baseline.isEmpty && !baseline.hasCurve)
    }

    @Test("舊版快照（曲線必填、無 remoteOffsets）解得開")
    func decodesLegacySnapshot() throws {
        let legacy = #"{"displayOffsets":{"A":-0.1},"minBrightness":0.05,"maxLux":600}"#
        let baseline = try JSONDecoder().decode(AdviceBaseline.self, from: Data(legacy.utf8))
        #expect(baseline.displayOffsets == ["A": -0.1])
        #expect(baseline.remoteOffsets == nil)
        #expect(baseline.minBrightness == 0.05)
        #expect(baseline.maxLux == 600)
    }

    @Test("新格式只記過螢幕時省略曲線也解得開")
    func roundTripWithoutCurve() throws {
        var baseline = AdviceBaseline()
        baseline.recordLocal("A", original: 0.2)
        let data = try JSONEncoder().encode(baseline)
        #expect(try JSONDecoder().decode(AdviceBaseline.self, from: data) == baseline)
    }
}
