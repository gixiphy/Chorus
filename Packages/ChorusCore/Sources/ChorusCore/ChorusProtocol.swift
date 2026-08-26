/// Chorus 同步協定的全域常數。
public enum ChorusProtocol {
    /// 協定版本。major 不相容時拒連，minor 擴充需向後相容。
    public static let version = 1

    /// Bonjour service type。
    public static let serviceType = "_chorus._tcp"
}
