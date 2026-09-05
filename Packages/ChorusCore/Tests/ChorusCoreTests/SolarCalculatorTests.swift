import Foundation
import Testing
@testable import ChorusCore

@Suite("Solar calculator")
struct SolarCalculatorTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 3))!
    }

    /// 對照 timeanddate.com 公布值，容差 3 分鐘。
    @Test("Taipei summer solstice")
    func taipeiSummer() throws {
        let calendar = calendar("Asia/Taipei")
        let sun = try #require(SolarCalculator.sunTimes(
            on: date(calendar, 2026, 6, 21), latitude: 25.033, longitude: 121.565, calendar: calendar
        ))
        #expect(abs(sun.sunriseMinute - (5 * 60 + 5)) < 3)
        #expect(abs(sun.sunsetMinute - (18 * 60 + 47)) < 3)
    }

    @Test("Taipei winter solstice")
    func taipeiWinter() throws {
        let calendar = calendar("Asia/Taipei")
        let sun = try #require(SolarCalculator.sunTimes(
            on: date(calendar, 2026, 12, 21), latitude: 25.033, longitude: 121.565, calendar: calendar
        ))
        #expect(abs(sun.sunriseMinute - (6 * 60 + 34)) < 3)
        #expect(abs(sun.sunsetMinute - (17 * 60 + 11)) < 3)
    }

    @Test("London in summer respects daylight saving time")
    func londonSummer() throws {
        let calendar = calendar("Europe/London")
        let sun = try #require(SolarCalculator.sunTimes(
            on: date(calendar, 2026, 6, 21), latitude: 51.507, longitude: -0.128, calendar: calendar
        ))
        #expect(abs(sun.sunriseMinute - (4 * 60 + 43)) < 3)
        #expect(abs(sun.sunsetMinute - (21 * 60 + 21)) < 3)
    }

    @Test("Southern hemisphere: Sydney's June day is short")
    func sydneyWinter() throws {
        let calendar = calendar("Australia/Sydney")
        let sun = try #require(SolarCalculator.sunTimes(
            on: date(calendar, 2026, 6, 21), latitude: -33.868, longitude: 151.209, calendar: calendar
        ))
        #expect(abs(sun.sunriseMinute - (7 * 60 + 0)) < 3)
        #expect(abs(sun.sunsetMinute - (16 * 60 + 54)) < 3)
    }

    @Test("Polar day returns nil")
    func polarDay() {
        let calendar = calendar("Europe/Oslo")
        #expect(SolarCalculator.sunTimes(
            on: date(calendar, 2026, 6, 21), latitude: 69.649, longitude: 18.956, calendar: calendar
        ) == nil)
    }

    @Test("Polar night returns nil")
    func polarNight() {
        let calendar = calendar("Europe/Oslo")
        #expect(SolarCalculator.sunTimes(
            on: date(calendar, 2026, 12, 21), latitude: 69.649, longitude: 18.956, calendar: calendar
        ) == nil)
    }

    @Test("Invalid coordinates return nil")
    func invalid() {
        #expect(SolarCalculator.sunTimes(on: Date(), latitude: 91, longitude: 0) == nil)
        #expect(SolarCalculator.sunTimes(on: Date(), latitude: 0, longitude: 181) == nil)
    }
}
