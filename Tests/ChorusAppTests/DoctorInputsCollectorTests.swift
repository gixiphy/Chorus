import ChorusCore
import Testing
@testable import Chorus

@Suite("診斷快照")
struct DoctorInputsCollectorTests {
    @Test("TapEngine 狀態對應到診斷狀態")
    func tapStateMapping() {
        #expect(DoctorInputsCollector.tapState(.off) == (.off, nil))
        #expect(DoctorInputsCollector.tapState(.probing) == (.probing, nil))
        #expect(DoctorInputsCollector.tapState(.active) == (.active, nil))
        #expect(DoctorInputsCollector.tapState(.denied) == (.denied, nil))
        #expect(DoctorInputsCollector.tapState(.failed("boom")) == (.failed, "boom"))
    }
}
