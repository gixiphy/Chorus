import Foundation

/// 沒有任何環境光來源時的兜底：依一天中的時間估一個 lux。
///
/// 位階是最低的——本機感器、peer 回報都優先；只有兩者皆無（Mac mini 單機、
/// 筆電合蓋且 peer 全離線）才用它。它不是量測，是猜：室內白天靠窗光，
/// 晚上靠燈，所以模型不是日照角而是「日間值／夜間值＋兩段餘弦漸變」。
/// 天亮天黑時間預設由使用者設；開 `sunTracking` 則由 app 端拿所在地的日出日落
/// （SolarCalculator）每天覆蓋——本型別本身不碰定位，只提供 `applying(sun:)`。
///
/// 純邏輯、可序列化；時間一律用「當地時區的當日分鐘數」表達。
public struct AmbientSchedule: Codable, Sendable, Equatable {
    /// 日間穩態 lux。
    public var dayLux: Double
    /// 夜間穩態 lux。
    public var nightLux: Double
    /// 天亮（漸變中點）：當日分鐘數 0…1439。
    public var dawnMinute: Int
    /// 天黑（漸變中點）：當日分鐘數 0…1439。
    public var duskMinute: Int
    /// 每段漸變的總長度（分鐘），以天亮／天黑為中心前後各一半。
    public var rampMinutes: Int
    /// 天亮／天黑改用所在地日出日落（app 端有座標時才生效，否則沿用手動時間）。
    public var sunTracking: Bool

    public static let minutesPerDay = 1440

    public init(
        dayLux: Double = 400,
        nightLux: Double = 40,
        dawnMinute: Int = 7 * 60,
        duskMinute: Int = 18 * 60,
        rampMinutes: Int = 60,
        sunTracking: Bool = false
    ) {
        self.dayLux = max(dayLux, 0)
        self.nightLux = max(nightLux, 0)
        self.dawnMinute = Self.wrap(dawnMinute)
        self.duskMinute = Self.wrap(duskMinute)
        self.rampMinutes = min(max(rampMinutes, 1), 240)
        self.sunTracking = sunTracking
    }

    /// 舊版存檔沒有 `sunTracking` 欄位 → 視為關閉。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dayLux: try c.decode(Double.self, forKey: .dayLux),
            nightLux: try c.decode(Double.self, forKey: .nightLux),
            dawnMinute: try c.decode(Int.self, forKey: .dawnMinute),
            duskMinute: try c.decode(Int.self, forKey: .duskMinute),
            rampMinutes: try c.decode(Int.self, forKey: .rampMinutes),
            sunTracking: try c.decodeIfPresent(Bool.self, forKey: .sunTracking) ?? false
        )
    }

    /// 以日出日落取代天亮／天黑（取整分鐘）。其餘參數不動。
    public func applying(sun: SolarCalculator.SunTimes) -> AmbientSchedule {
        var copy = self
        copy.dawnMinute = Self.wrap(Int(sun.sunriseMinute.rounded()))
        copy.duskMinute = Self.wrap(Int(sun.sunsetMinute.rounded()))
        return copy
    }

    /// 該時刻的估計 lux。`minuteOfDay` 可帶小數（秒），超出一天會取模。
    public func lux(atMinuteOfDay minuteOfDay: Double) -> Double {
        let dayness = dayFraction(atMinuteOfDay: minuteOfDay)
        return nightLux + (dayLux - nightLux) * dayness
    }

    /// 以當地時區換算後的估計 lux。
    public func lux(at date: Date, calendar: Calendar = .current) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minute = Double(components.hour ?? 0) * 60
            + Double(components.minute ?? 0)
            + Double(components.second ?? 0) / 60
        return lux(atMinuteOfDay: minute)
    }

    /// 0（全夜）…1（全日）。把時刻換成「距天亮幾分鐘」（0…1439），白天長度
    /// 是天亮到天黑的環狀距離：漸變太長塞不進白天或夜晚時自動縮短，
    /// 兩段漸變永遠不重疊；天黑在午夜後、或夜班式「天亮 22:00／天黑 06:00」都成立。
    public func dayFraction(atMinuteOfDay minuteOfDay: Double) -> Double {
        let period = Double(Self.minutesPerDay)
        let dayLength = Double(Self.wrap(duskMinute - dawnMinute))
        guard dayLength > 0 else { return 0 }
        let ramp = max(1, min(Double(rampMinutes), dayLength, period - dayLength))
        let half = ramp / 2
        var sinceDawn = (minuteOfDay - Double(dawnMinute)).truncatingRemainder(dividingBy: period)
        if sinceDawn < 0 { sinceDawn += period }

        if sinceDawn < half {
            return Self.ramp(sinceDawn, half: half, length: ramp)
        }
        if sinceDawn < dayLength - half {
            return 1
        }
        if sinceDawn < dayLength + half {
            return 1 - Self.ramp(sinceDawn - dayLength, half: half, length: ramp)
        }
        if sinceDawn >= period - half {
            return Self.ramp(sinceDawn - period, half: half, length: ramp)
        }
        return 0
    }

    // MARK: - 私有

    /// 餘弦漸變：offset 從 −half 走到 +half 時由 0 升到 1。
    private static func ramp(_ offset: Double, half: Double, length: Double) -> Double {
        0.5 - 0.5 * cos(.pi * (offset + half) / length)
    }

    private static func wrap(_ minute: Int) -> Int {
        let wrapped = minute % minutesPerDay
        return wrapped < 0 ? wrapped + minutesPerDay : wrapped
    }
}
