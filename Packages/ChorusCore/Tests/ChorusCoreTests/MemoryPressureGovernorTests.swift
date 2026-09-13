import Testing
@testable import ChorusCore

@Suite("MemoryPressureGovernor")
struct MemoryPressureGovernorTests {
    @Test("Escalation takes effect immediately")
    func escalatesImmediately() {
        var governor = MemoryPressureGovernor(recovery: .seconds(30))
        let warning = governor.report(.warning, now: .zero)
        let critical = governor.report(.critical, now: .seconds(1))
        #expect(warning == .warning)
        #expect(critical == .critical)
        #expect(governor.effective == .critical)
    }

    @Test("De-escalation waits for the recovery period")
    func recoveryHysteresis() {
        var governor = MemoryPressureGovernor(recovery: .seconds(30))
        _ = governor.report(.critical, now: .zero)
        let early = governor.report(.normal, now: .seconds(10))
        #expect(early == nil)
        #expect(governor.effective == .critical)
        #expect(governor.needsTicks)

        let notYet = governor.tick(now: .seconds(39))
        #expect(notYet == nil)
        let recovered = governor.tick(now: .seconds(40))
        #expect(recovered == .normal)
        #expect(!governor.needsTicks)
    }

    @Test("Pressure returning during recovery cancels it")
    func flappingResetsRecovery() {
        var governor = MemoryPressureGovernor(recovery: .seconds(30))
        _ = governor.report(.warning, now: .zero)
        _ = governor.report(.normal, now: .seconds(5))
        _ = governor.report(.warning, now: .seconds(20))
        let stillWarning = governor.tick(now: .seconds(40))
        #expect(stillWarning == nil)
        #expect(governor.effective == .warning)

        _ = governor.report(.normal, now: .seconds(50))
        let recovered = governor.tick(now: .seconds(80))
        #expect(recovered == .normal)
    }

    @Test("Critical easing to warning steps down to warning, not straight to normal")
    func stepsDownToReportedLevel() {
        var governor = MemoryPressureGovernor(recovery: .seconds(30))
        _ = governor.report(.critical, now: .zero)
        _ = governor.report(.warning, now: .seconds(1))
        let stepped = governor.tick(now: .seconds(31))
        #expect(stepped == .warning)
        #expect(governor.effective == .warning)
    }
}
