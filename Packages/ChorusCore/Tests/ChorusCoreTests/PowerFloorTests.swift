import Foundation
import Testing
@testable import ChorusCore

@Suite("PowerFloorPolicy")
struct PowerFloorTests {
    private func snap(
        battery: Bool = true,
        onBattery: Bool? = true,
        percent: Int? = 50,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> PowerSnapshot {
        PowerSnapshot(
            hasInternalBattery: battery, onBattery: onBattery, percent: percent, thermal: thermal
        )
    }

    @Test("Battery hysteresis: trip below floor, hold through +4, recover at +5")
    func batteryHysteresis() {
        let floor = KeepAwakeBatteryFloor.percent20
        let tripped = PowerFloorPolicy.evaluate(
            snapshot: snap(percent: 19), floor: floor, previous: .ok
        )
        #expect(tripped == .lowBattery(percent: 19))

        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(percent: 22), floor: floor, previous: tripped
            ) == .lowBattery(percent: 22)
        )
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(percent: 24), floor: floor, previous: tripped
            ) == .lowBattery(percent: 24)
        )
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(percent: 25), floor: floor, previous: .lowBattery(percent: 24)
            ) == .ok
        )
    }

    @Test("Plugging in recovers immediately even below the floor")
    func acRecoversImmediately() {
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(onBattery: false, percent: 5),
                floor: .percent20,
                previous: .lowBattery(percent: 5)
            ) == .ok
        )
    }

    @Test("Machines without an internal battery never trip on battery")
    func desktopNeverTrips() {
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(battery: false, onBattery: nil, percent: nil),
                floor: .percent20,
                previous: .ok
            ) == .ok
        )
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(battery: false, onBattery: true, percent: 5),
                floor: .percent20,
                previous: .ok
            ) == .ok
        )
    }

    @Test("Unknown percent keeps the previous battery judgment")
    func unknownPercentKeepsPrevious() {
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(percent: nil),
                floor: .percent20,
                previous: .ok
            ) == .ok
        )
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(percent: nil),
                floor: .percent20,
                previous: .lowBattery(percent: 12)
            ) == .lowBattery(percent: 12)
        )
    }

    @Test("Thermal critical trips; serious does not recover; fair does")
    func thermalHysteresis() {
        let critical = PowerFloorPolicy.evaluate(
            snapshot: snap(thermal: .critical), floor: .percent20, previous: .ok
        )
        #expect(critical == .critical)

        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(thermal: .serious), floor: .percent20, previous: .critical
            ) == .critical
        )
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(thermal: .fair), floor: .percent20, previous: .critical
            ) == .ok
        )
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(thermal: .serious), floor: .percent20, previous: .ok
            ) == .ok
        )
    }

    @Test("Floor off disables battery trips but thermal still applies")
    func floorOff() {
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(percent: 5), floor: .off, previous: .ok
            ) == .ok
        )
        #expect(
            PowerFloorPolicy.evaluate(
                snapshot: snap(percent: 5, thermal: .critical), floor: .off, previous: .ok
            ) == .critical
        )
    }

    @Test("Planner drops the assertion when the power floor is tripped")
    func plannerRespectsFloor() {
        #expect(
            KeepAwakePlanner.shouldHoldAssertion(
                mode: .indefinite, startedAt: 0, now: 10,
                connectedDisplayUUIDs: [], runningAppBundleIDs: [],
                agentsWorking: false, systemBusy: false, powerFloorTripped: true
            ) == false
        )
        #expect(
            KeepAwakePlanner.shouldHoldAssertion(
                mode: .indefinite, startedAt: 0, now: 10,
                connectedDisplayUUIDs: [], runningAppBundleIDs: [],
                agentsWorking: false, systemBusy: false, powerFloorTripped: false
            )
        )
    }
}
