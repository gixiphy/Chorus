import Testing
@testable import Chorus

@Test("Unknown bundle IDs fall back to the last path component")
func runningAppsDisplayNameFallback() {
    #expect(RunningApps.displayName(for: "com.example.not-installed") == "not-installed")
    #expect(RunningApps.displayName(for: "notabundleid") == "notabundleid")
}

@MainActor
@Test("Pickable apps are unique, name-sorted and never Chorus itself")
func runningAppsOptions() {
    let options = RunningApps.options()
    let ids = options.map(\.bundleID)
    #expect(Set(ids).count == ids.count)
    #expect(!ids.contains(Bundle.main.bundleIdentifier ?? "com.hermes.Chorus"))
    #expect(options.map(\.name) == options.map(\.name)
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    // 執行中的 App 一定也在「所有 bundle ID」那份裡（選單挑得到 ⇒ 綁得起來）
    let running = RunningApps.bundleIDs()
    #expect(ids.allSatisfy(running.contains))
}
