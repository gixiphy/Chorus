import Foundation

/// 日出日落計算（NOAA General Solar Position Calculations 的簡化式）。
/// 純數學、不碰定位；誤差對緯度 60° 以內約 ±1 分鐘，夠時間排程用
/// （排程本身還有半小時漸變）。
public enum SolarCalculator {
    public struct SunTimes: Equatable, Sendable {
        /// 當地時區的當日分鐘數。
        public let sunriseMinute: Double
        public let sunsetMinute: Double

        public init(sunriseMinute: Double, sunsetMinute: Double) {
            self.sunriseMinute = sunriseMinute
            self.sunsetMinute = sunsetMinute
        }
    }

    /// 該日該地的日出／日落。極晝或極夜（太陽整天不落或不升）回 nil，
    /// 呼叫端保留手動時間。
    public static func sunTimes(
        on date: Date,
        latitude: Double,
        longitude: Double,
        calendar: Calendar = .current
    ) -> SunTimes? {
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        // 以當地正午為計算點：一天之內太陽參數變化很小，取中點誤差最小
        let startOfDay = calendar.startOfDay(for: date)
        let noon = startOfDay.addingTimeInterval(12 * 3600)
        let timeZoneHours = Double(calendar.timeZone.secondsFromGMT(for: noon)) / 3600
        let julianDay = noon.timeIntervalSince1970 / 86400 + 2_440_587.5
        let century = (julianDay - 2_451_545) / 36525

        let meanLongitude = normalizeDegrees(280.46646 + century * (36000.76983 + century * 0.0003032))
        let meanAnomaly = 357.52911 + century * (35999.05029 - 0.0001537 * century)
        let eccentricity = 0.016708634 - century * (0.000042037 + 0.0000001267 * century)
        let equationOfCenter = sinDeg(meanAnomaly) * (1.914602 - century * (0.004817 + 0.000014 * century))
            + sinDeg(2 * meanAnomaly) * (0.019993 - 0.000101 * century)
            + sinDeg(3 * meanAnomaly) * 0.000289
        let trueLongitude = meanLongitude + equationOfCenter
        let omega = 125.04 - 1934.136 * century
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sinDeg(omega)
        let meanObliquity = 23 + (26 + (21.448 - century * (46.815 + century * (0.00059 - century * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cosDeg(omega)
        let declination = asin(sinDeg(obliquity) * sinDeg(apparentLongitude)) * 180 / .pi

        let y = pow(tan(obliquity * .pi / 360), 2)
        let equationOfTime = 4 * (180 / .pi) * (
            y * sinDeg(2 * meanLongitude)
                - 2 * eccentricity * sinDeg(meanAnomaly)
                + 4 * eccentricity * y * sinDeg(meanAnomaly) * cosDeg(2 * meanLongitude)
                - 0.5 * y * y * sinDeg(4 * meanLongitude)
                - 1.25 * eccentricity * eccentricity * sinDeg(2 * meanAnomaly)
        )

        // 官方日出：太陽中心在地平線下 0.833°（半徑＋大氣折射）
        let cosHourAngle = cosDeg(90.833) / (cosDeg(latitude) * cosDeg(declination))
            - tanDeg(latitude) * tanDeg(declination)
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
        let hourAngle = acos(cosHourAngle) * 180 / .pi

        let solarNoon = 720 - 4 * longitude - equationOfTime + timeZoneHours * 60
        return SunTimes(sunriseMinute: solarNoon - hourAngle * 4, sunsetMinute: solarNoon + hourAngle * 4)
    }

    // MARK: - 私有

    private static func normalizeDegrees(_ value: Double) -> Double {
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func sinDeg(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }
    private static func cosDeg(_ degrees: Double) -> Double { cos(degrees * .pi / 180) }
    private static func tanDeg(_ degrees: Double) -> Double { tan(degrees * .pi / 180) }
}
