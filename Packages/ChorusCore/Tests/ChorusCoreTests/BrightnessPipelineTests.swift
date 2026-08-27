import Testing
@testable import ChorusCore

@Suite("BrightnessPipeline")
struct BrightnessPipelineTests {
    @Test("Pure hardware mode maps slider directly")
    func pureHardware() {
        let pipeline = BrightnessPipeline(softwareThreshold: 0)
        let out = pipeline.map(slider: 0.4, hasHardwareControl: true)
        #expect(out.hardware == 0.4)
        #expect(out.softwareFactor == 1)
    }

    @Test("Software-only display always dims via gamma")
    func softwareOnly() {
        let pipeline = BrightnessPipeline(minimumSoftwareFactor: 0.2)
        let bottom = pipeline.map(slider: 0, hasHardwareControl: false)
        #expect(bottom.hardware == nil)
        #expect(abs(bottom.softwareFactor - 0.2) < 0.0001)

        let top = pipeline.map(slider: 1, hasHardwareControl: false)
        #expect(abs(top.softwareFactor - 1) < 0.0001)
    }

    @Test("Combined dimming is continuous at the threshold")
    func combinedContinuity() {
        let pipeline = BrightnessPipeline(softwareThreshold: 0.3)
        let atThreshold = pipeline.map(slider: 0.3, hasHardwareControl: true)
        #expect(atThreshold.hardware == 0)
        #expect(atThreshold.softwareFactor == 1)

        let justBelow = pipeline.map(slider: 0.299, hasHardwareControl: true)
        #expect(justBelow.hardware == 0)
        #expect(justBelow.softwareFactor < 1)

        let top = pipeline.map(slider: 1, hasHardwareControl: true)
        #expect(top.hardware == 1)
    }

    @Test("Mapping is monotone over a slider sweep")
    func monotone() {
        let pipeline = BrightnessPipeline(softwareThreshold: 0.25, minimumSoftwareFactor: 0.15)
        var lastEffective = -1.0
        for step in 0...100 {
            let slider = Double(step) / 100
            let out = pipeline.map(slider: slider, hasHardwareControl: true)
            // 有效亮度：硬體與軟體係數的合成單調性
            let effective = (out.hardware ?? 0) + out.softwareFactor
            #expect(effective >= lastEffective - 0.0001)
            lastEffective = effective
        }
    }

    @Test("Slider values are clamped")
    func clamping() {
        let pipeline = BrightnessPipeline()
        #expect(pipeline.map(slider: -0.5, hasHardwareControl: true).hardware == 0)
        #expect(pipeline.map(slider: 1.5, hasHardwareControl: true).hardware == 1)
    }

    @Test("Inverse recovers the slider from hardware; hardware 0 is ambiguous")
    func inverse() {
        let pipeline = BrightnessPipeline(softwareThreshold: 0.25)
        // 硬體區間內（門檻以上）：map → invert 還原滑桿值
        for step in [0.3, 0.5, 0.75, 1.0] {
            let hardware = pipeline.map(slider: step, hasHardwareControl: true).hardware!
            #expect(abs(pipeline.sliderValue(forHardware: hardware)! - step) < 0.0001)
        }
        // 硬體 0 落在軟體調光整段，無法唯一還原
        #expect(pipeline.sliderValue(forHardware: 0) == nil)
        // 未啟用 combined dimming 時是恆等映射
        #expect(BrightnessPipeline().sliderValue(forHardware: 0.4) == 0.4)
    }
}
