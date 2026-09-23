import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("SystemLoadSettings")
struct SystemLoadSettingsTests {
    private func makeStore() -> (SettingsStore, String) {
        let suite = "system-load-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults), suite)
    }

    @Test func defaultsAreOffWithDefaultConfiguration() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(!store.keepAwakeSystemLoadMode)
        #expect(store.keepAwakeSystemLoadConfiguration == .default)
    }

    @Test func validatedSetterPersistsAndRejectsInvalidConfiguration() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        store.keepAwakeSystemLoadMode = true
        #expect(store.keepAwakeSystemLoadMode)

        var config = SystemLoadConfiguration.default
        config.cpu.activation = 80
        config.cpu.release = 40
        store.keepAwakeSystemLoadConfiguration = config
        #expect(store.keepAwakeSystemLoadConfiguration.cpu.activation == 80)

        var invalid = SystemLoadConfiguration.default
        invalid.cpu.activation = 10
        invalid.cpu.release = 50
        store.keepAwakeSystemLoadConfiguration = invalid
        #expect(store.keepAwakeSystemLoadConfiguration == .default)
    }

    @Test func roundTripThroughFreshStore() {
        let suite = "system-load-settings-rt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        first.keepAwakeSystemLoadMode = true
        var config = SystemLoadConfiguration.default
        config.network.activation = 2_097_152
        config.network.release = 524_288
        first.keepAwakeSystemLoadConfiguration = config

        let second = SettingsStore(defaults: defaults)
        #expect(second.keepAwakeSystemLoadMode)
        #expect(second.keepAwakeSystemLoadConfiguration.network.activation == 2_097_152)
    }

    @Test func corruptStoredConfigurationFallsBackToDefault() {
        let suite = "system-load-settings-corrupt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not-json".utf8), forKey: "chorus.keepAwake.systemLoadConfiguration")
        let store = SettingsStore(defaults: defaults)
        #expect(store.keepAwakeSystemLoadConfiguration == .default)
    }

    @Test func statusFormatterCoversKeyPhases() {
        let waiting = SystemLoadEvaluation(
            phase: .waiting, shouldHold: false, qualifiedSignals: [], cooldownRemaining: nil
        )
        #expect(SystemLoadStatusFormatter.caption(
            evaluation: waiting, sample: nil, isHolding: false, alsoPreventSystemSleep: false
        ).contains("等待"))

        let cooling = SystemLoadEvaluation(
            phase: .coolingDown, shouldHold: true, qualifiedSignals: [], cooldownRemaining: 90
        )
        #expect(SystemLoadStatusFormatter.caption(
            evaluation: cooling, sample: nil, isHolding: true, alsoPreventSystemSleep: false
        ).contains("90"))
    }
}
