import Testing
@testable import ChorusCore

@Suite("DisplayPowerPlanner")
struct DisplayPowerTests {
    @Test("DDC wins when the monitor reports power support")
    func ddcPreferred() {
        let layer = DisplayPowerPlanner.layer(for: DisplayPowerCapability(
            supportsDDCPower: true,
            supportsSoftDisconnect: true,
            isOnlyActiveDisplay: false
        ))
        #expect(layer == .ddc)
    }

    @Test("Soft-disconnect covers the built-in panel (no DDC)")
    func softDisconnectForBuiltin() {
        let layer = DisplayPowerPlanner.layer(for: DisplayPowerCapability(
            supportsDDCPower: false,
            supportsSoftDisconnect: true,
            isOnlyActiveDisplay: false
        ))
        #expect(layer == .softDisconnect)
    }

    @Test("The only display is never soft-disconnected — that would lock the user out")
    func onlyDisplayNeverSoftDisconnected() {
        let layer = DisplayPowerPlanner.layer(for: DisplayPowerCapability(
            supportsDDCPower: false,
            supportsSoftDisconnect: true,
            isOnlyActiveDisplay: true
        ))
        #expect(layer == .gammaBlackout)
    }

    @Test("A single external monitor may still use DDC — its power button always recovers it")
    func onlyDisplayStillAllowsDDC() {
        let layer = DisplayPowerPlanner.layer(for: DisplayPowerCapability(
            supportsDDCPower: true,
            supportsSoftDisconnect: false,
            isOnlyActiveDisplay: true
        ))
        #expect(layer == .ddc)
    }

    @Test("No capability at all falls back to gamma blackout")
    func fallback() {
        let layer = DisplayPowerPlanner.layer(for: DisplayPowerCapability(
            supportsDDCPower: false,
            supportsSoftDisconnect: false,
            isOnlyActiveDisplay: false
        ))
        #expect(layer == .gammaBlackout)
    }

    @Test("We never write the hard-off VCP value")
    func neverHardOff() {
        #expect(DisplayPowerValue.off == 0x04)
        #expect(DisplayPowerValue.on == 0x01)
        #expect(DisplayPowerValue.hardOff == 0x05)
    }
}
