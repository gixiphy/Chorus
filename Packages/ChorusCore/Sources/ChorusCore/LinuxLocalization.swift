#if os(Linux)
import Foundation

extension String {
    /// Apple's `String(localized:)` looks up the app string catalog. swift-corelibs
    /// does not provide that initializer. On Linux the source string is the value,
    /// matching the catalog's development language (zh-Hant) when no translation is applied.
    init(localized key: String) {
        self = key
    }
}
#endif
