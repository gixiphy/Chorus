import Foundation
import Testing
@testable import ChorusCore

@Suite("Ambient schedule")
struct AmbientScheduleTests {
    private let schedule = AmbientSchedule(
        dayLux: 400, nightLux: 40, dawnMinute: 7 * 60, duskMinute: 18 * 60, rampMinutes: 60
    )

    @Test("Steady day and night values outside the ramps")
    func steadyStates() {
        #expect(schedule.lux(atMinuteOfDay: 12 * 60) == 400)
        #expect(schedule.lux(atMinuteOfDay: 3 * 60) == 40)
        #expect(schedule.lux(atMinuteOfDay: 23 * 60) == 40)
        #expect(schedule.lux(atMinuteOfDay: 0) == 40)
    }

    @Test("Ramp midpoints sit halfway and ramp edges are exact")
    func rampShape() {
        #expect(abs(schedule.lux(atMinuteOfDay: 7 * 60) - 220) < 1e-9)
        #expect(abs(schedule.lux(atMinuteOfDay: 18 * 60) - 220) < 1e-9)
        #expect(schedule.lux(atMinuteOfDay: 6 * 60 + 30) == 40)
        #expect(schedule.lux(atMinuteOfDay: 7 * 60 + 30) == 400)
        #expect(schedule.lux(atMinuteOfDay: 17 * 60 + 30) == 400)
        #expect(schedule.lux(atMinuteOfDay: 18 * 60 + 30) == 40)
    }

    @Test("Dawn ramp is monotonic and dusk ramp is monotonic")
    func monotonicRamps() {
        var previous = -Double.infinity
        for minute in stride(from: 6 * 60 + 30, through: 7 * 60 + 30, by: 1) {
            let value = schedule.lux(atMinuteOfDay: Double(minute))
            #expect(value >= previous)
            previous = value
        }
        previous = Double.infinity
        for minute in stride(from: 17 * 60 + 30, through: 18 * 60 + 30, by: 1) {
            let value = schedule.lux(atMinuteOfDay: Double(minute))
            #expect(value <= previous)
            previous = value
        }
    }

    @Test("Ramp centred on midnight wraps across the day boundary")
    func midnightWrap() {
        let late = AmbientSchedule(dayLux: 300, nightLux: 30, dawnMinute: 8 * 60, duskMinute: 0, rampMinutes: 60)
        #expect(abs(late.lux(atMinuteOfDay: 0) - 165) < 1e-9)
        #expect(late.lux(atMinuteOfDay: 23 * 60 + 30) == 300)
        #expect(late.lux(atMinuteOfDay: 30) == 30)
        // 超出一天的分鐘數取模
        #expect(abs(late.lux(atMinuteOfDay: 1440) - 165) < 1e-9)
    }

    @Test("Long day (16 h) stays bright all the way to dusk")
    func longDay() {
        let long = AmbientSchedule(dayLux: 300, nightLux: 30, dawnMinute: 6 * 60, duskMinute: 22 * 60, rampMinutes: 60)
        #expect(long.lux(atMinuteOfDay: 20 * 60) == 300)
        #expect(long.lux(atMinuteOfDay: 21 * 60 + 29) == 300)
        #expect(long.lux(atMinuteOfDay: 23 * 60) == 30)
    }

    @Test("Ramp longer than the night is shortened so ramps never overlap")
    func rampClamp() {
        let tight = AmbientSchedule(dayLux: 100, nightLux: 0, dawnMinute: 60, duskMinute: 0, rampMinutes: 240)
        // 夜晚只有 60 分鐘 → 漸變縮成 60，00:30 是夜晚正中央、全暗
        #expect(tight.lux(atMinuteOfDay: 30) == 0)
        #expect(abs(tight.lux(atMinuteOfDay: 0) - 50) < 1e-9)
        #expect(abs(tight.lux(atMinuteOfDay: 60) - 50) < 1e-9)
        #expect(tight.lux(atMinuteOfDay: 12 * 60) == 100)
    }

    @Test("Dawn equal to dusk means no daytime")
    func degenerate() {
        let none = AmbientSchedule(dayLux: 500, nightLux: 5, dawnMinute: 600, duskMinute: 600)
        #expect(none.lux(atMinuteOfDay: 600) == 5)
        #expect(none.lux(atMinuteOfDay: 0) == 5)
    }

    @Test("Night-shift schedule (dusk before dawn) is bright at night")
    func nightShift() {
        let shift = AmbientSchedule(dayLux: 500, nightLux: 20, dawnMinute: 22 * 60, duskMinute: 6 * 60, rampMinutes: 30)
        #expect(shift.lux(atMinuteOfDay: 2 * 60) == 500)
        #expect(shift.lux(atMinuteOfDay: 23 * 60) == 500)
        #expect(shift.lux(atMinuteOfDay: 12 * 60) == 20)
    }

    @Test("Date-based lookup uses the given calendar's time zone")
    func dateLookup() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        // 2026-09-05 12:00 台北
        let noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!
        #expect(schedule.lux(at: noon, calendar: calendar) == 400)
        // 同一瞬間換成 UTC 是 04:00 → 夜間
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(schedule.lux(at: noon, calendar: utc) == 40)
    }

    @Test("Init sanitizes parameters")
    func sanitizedInit() {
        let odd = AmbientSchedule(dayLux: -5, nightLux: -1, dawnMinute: -60, duskMinute: 1500, rampMinutes: 0)
        #expect(odd.dayLux == 0)
        #expect(odd.nightLux == 0)
        #expect(odd.dawnMinute == 23 * 60)
        #expect(odd.duskMinute == 60)
        #expect(odd.rampMinutes == 1)
        #expect(AmbientSchedule(rampMinutes: 999).rampMinutes == 240)
    }

    @Test("Legacy JSON without sunTracking decodes as manual times")
    func legacyDecode() throws {
        let json = #"{"dayLux":400,"nightLux":40,"dawnMinute":420,"duskMinute":1080,"rampMinutes":60}"#
        let decoded = try JSONDecoder().decode(AmbientSchedule.self, from: Data(json.utf8))
        #expect(decoded.sunTracking == false)
        #expect(decoded == schedule)
    }

    @Test("Applying sun times replaces dawn and dusk only")
    func applyingSun() {
        var tracking = schedule
        tracking.sunTracking = true
        let applied = tracking.applying(sun: .init(sunriseMinute: 305.4, sunsetMinute: 1126.6))
        #expect(applied.dawnMinute == 305)
        #expect(applied.duskMinute == 1127)
        #expect(applied.dayLux == 400)
        #expect(applied.sunTracking == true)
    }

    @Test("Codable round trip")
    func codable() throws {
        var tracking = schedule
        tracking.sunTracking = true
        let data = try JSONEncoder().encode(tracking)
        let decoded = try JSONDecoder().decode(AmbientSchedule.self, from: data)
        #expect(decoded == tracking)
    }
}
