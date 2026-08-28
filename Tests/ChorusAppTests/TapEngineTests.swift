import ChorusCore
import CoreAudio
import Foundation
import Testing
@testable import Chorus

/// TapEngine 生命週期，全部走 FakeTapBackend——不需權限、不碰 CoreAudio。
/// 權限判讀的「發聲卻全零＝denied」形狀來自實測（DESIGN-M12 §1.2）。
@MainActor
@Suite("Tap engine")
struct TapEngineTests {
    private func makeEngine(mode: FakeTapBackend.Mode) -> (TapEngine, FakeTapBackend, AudioProcessRegistry) {
        let backend = FakeTapBackend()
        backend.mode = mode
        let registry = AudioProcessRegistry()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tap-tests-\(UUID().uuidString)")!)
        let engine = TapEngine(backend: backend, registry: registry, settings: settings)
        return (engine, backend, registry)
    }

    private func injectAudibleApp(_ registry: AudioProcessRegistry) {
        registry.injectFake([
            .init(objectID: 1001, pid: 2001, bundleID: "com.apple.Music", name: "Music", isAudible: true),
        ])
    }

    @Test("啟用 → 探測；看到非零樣本 → active，且探測 session 被收掉")
    func probeToActive() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        #expect(engine.state == .probing)
        #expect(backend.startedSessions.map(\.kind) == [.captureOnly])
        engine.healthTick()
        #expect(engine.state == .active)
    }

    @Test("發聲卻全零：兩格判讀後 → denied（實測的權限被拒形狀）")
    func zerosWhileAudibleMeansDenied() {
        let (engine, _, registry) = makeEngine(mode: .zeros)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        #expect(engine.state == .probing)
        engine.healthTick()
        #expect(engine.state == .denied)
    }

    @Test("沒有任何來源發聲時全零不算證據——永遠停在 probing 不誤判")
    func silentSystemStaysProbing() {
        let (engine, _, registry) = makeEngine(mode: .zeros)
        registry.injectFake([
            .init(objectID: 1001, pid: 2001, bundleID: "com.apple.Music", name: "Music", isAudible: false),
        ])
        engine.setEnabled(true)
        for _ in 0..<5 { engine.healthTick() }
        #expect(engine.state == .probing)
    }

    @Test("denied 後 retry 會重新探測；權限修好即轉 active")
    func retryAfterDenied() {
        let (engine, backend, registry) = makeEngine(mode: .zeros)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick(); engine.healthTick()
        #expect(engine.state == .denied)
        backend.mode = .audio // 使用者去系統設定開了權限
        engine.retryPermission()
        #expect(engine.state == .probing)
        engine.healthTick()
        #expect(engine.state == .active)
    }

    @Test("active 前不建 tap；active 後依設定自動建 playthrough session")
    func tapRequiresActive() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.setGain(0.5, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles.isEmpty) // probing 中不建，但設定留著
        #expect(engine.setting(for: "com.apple.Music").gain == 0.5)
        engine.healthTick()
        // 權限到手 → 對帳把設定套上（App 重啟自動恢復走的是同一條路）
        #expect(engine.tappedBundles == ["com.apple.Music"])
        #expect(backend.startedSessions.last?.kind == .playthrough)
        #expect(backend.startedSessions.last?.target == "com.apple.Music")
    }

    @Test("停用收掉一切：探測與 per-app session 都停")
    func disableStopsEverything() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        engine.setEnabled(false)
        #expect(engine.state == .off)
        #expect(engine.tappedBundles.isEmpty)
    }

    @Test("預設輸出變更：跟隨預設的 session 搬家（收舊建新）")
    func sessionsFollowDefaultOutput() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        let before = backend.startedSessions.count

        backend.defaultOutputUID = "fake-speakers"
        backend.availableOutputUIDs = ["fake-speakers", "fake-headphones"]
        backend.simulateDefaultOutputChange()
        #expect(backend.startedSessions.count == before + 1)
        #expect(engine.tappedBundles == ["com.apple.Music"])
        #expect(engine.activeOutputUID(bundleID: "com.apple.Music") == "fake-speakers")
    }

    @Test("預設輸出「事件來了但裝置沒變」不重建——沒必要的中斷不該發生")
    func spuriousDefaultChangeIsIgnored() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        let before = backend.startedSessions.count
        backend.simulateDefaultOutputChange()
        #expect(backend.startedSessions.count == before)
    }

    @Test("拒絕 tap 自己——回音紀律")
    func refusesSelfTap() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: Bundle.main.bundleIdentifier ?? "com.hermes.Chorus")
        #expect(engine.tappedBundles.isEmpty)
        #expect(engine.lastTapError != nil) // 失敗有被說出來，不是靜靜消失
        #expect(engine.state == .active)    // 但引擎不因此離開 active
    }

    // MARK: - B6-2：設定驅動的 session 對帳

    @Test("沒調整就一個 tap 都沒有——歸零後 session 也收掉（DESIGN §2.3 規則 2）")
    func neutralSettingsMeanNoTaps() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        #expect(engine.tappedBundles.isEmpty)

        engine.setGain(0.4, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles == ["com.apple.Music"])

        engine.setGain(1, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles.isEmpty)
    }

    @Test("靜音也是一種調整：gain 回到 1 但仍靜音時 tap 要留著")
    func muteAloneKeepsTheTap() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setMuted(true, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles == ["com.apple.Music"])
        engine.setGain(1, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles == ["com.apple.Music"])
        engine.setMuted(false, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles.isEmpty)
    }

    @Test("調整推到 session：增益與靜音都送到 realtime 端")
    func adjustmentsReachTheSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(2.5, bundleID: "com.apple.Music")
        engine.setMuted(true, bundleID: "com.apple.Music")
        let session = backend.liveSessions["com.apple.Music"]
        #expect(session?.lastGain == 2.5)
        #expect(session?.lastMuted == true)
    }

    @Test("session 起步就在正確的增益上——不會先響一段全音量")
    func sessionStartsAtTheConfiguredGain() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.2, bundleID: "com.apple.Music")
        #expect(backend.liveSessions["com.apple.Music"]?.initialGain == 0.2)
    }

    @Test("gain 夾在 0–4x")
    func gainIsClamped() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(99, bundleID: "com.apple.Music")
        #expect(engine.setting(for: "com.apple.Music").gain == GainRamp.maxGain)
    }

    @Test("重複調整同一個 App 不重建 session（重建會有可聽見的中斷）")
    func repeatedAdjustmentsReuseTheSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        let after = backend.startedSessions.count
        engine.setGain(0.6, bundleID: "com.apple.Music")
        engine.setGain(0.7, bundleID: "com.apple.Music")
        engine.setMuted(true, bundleID: "com.apple.Music")
        #expect(backend.startedSessions.count == after)
    }

    @Test("reset 清掉所有調整，回到完全原生路徑")
    func resetReturnsToNativePath() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(2, bundleID: "com.apple.Music")
        engine.setMuted(true, bundleID: "com.apple.Music")
        engine.reset(bundleID: "com.apple.Music")
        #expect(engine.tappedBundles.isEmpty)
        #expect(engine.setting(for: "com.apple.Music").isNeutral)
    }

    // MARK: - B6-3：逐 App 路由

    @Test("指定輸出裝置：session 建在那個裝置上，不是系統預設")
    func routesToTheChosenDevice() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        #expect(engine.activeOutputUID(bundleID: "com.apple.Music") == "fake-output-uid")

        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Music")
        #expect(engine.activeOutputUID(bundleID: "com.apple.Music") == "fake-headphones")
        #expect(backend.startedOutputs.last == "fake-headphones")
    }

    @Test("只指定路由、音量不動也算調整——一樣要有 session")
    func routeAloneIsAnAdjustment() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Music")
        #expect(engine.tappedBundles == ["com.apple.Music"])
        engine.setOutputDevice(nil, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles.isEmpty)
    }

    @Test("指定的裝置被拔掉：暫時退回系統預設，但設定留著")
    func missingRouteFallsBackWithoutLosingTheSetting() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Music")

        backend.availableOutputUIDs = ["fake-output-uid"] // 耳機拔掉
        engine.audioDevicesChanged()
        #expect(engine.activeOutputUID(bundleID: "com.apple.Music") == "fake-output-uid")
        #expect(engine.setting(for: "com.apple.Music").outputDeviceUID == "fake-headphones")
        #expect(engine.lastTapError != nil) // 有說出來，不是靜靜換掉

        backend.availableOutputUIDs = ["fake-output-uid", "fake-headphones"] // 插回去
        engine.audioDevicesChanged()
        #expect(engine.activeOutputUID(bundleID: "com.apple.Music") == "fake-headphones")
        #expect(engine.lastTapError == nil)
    }

    @Test("換系統預設：跟隨預設的搬家，指定路由的不動")
    func defaultChangeOnlyMovesFollowers() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        engine.setGain(0.5, bundleID: "com.apple.Safari")
        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Safari")

        backend.defaultOutputUID = "fake-speakers"
        backend.availableOutputUIDs = ["fake-speakers", "fake-headphones"]
        engine.audioDevicesChanged()
        #expect(engine.activeOutputUID(bundleID: "com.apple.Music") == "fake-speakers")
        #expect(engine.activeOutputUID(bundleID: "com.apple.Safari") == "fake-headphones")
    }

    @Test("路由沒變就不重建 session（重建會有可聽見的中斷）")
    func unchangedRouteReusesTheSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Music")
        let after = backend.startedSessions.count
        engine.setGain(0.5, bundleID: "com.apple.Music")
        engine.audioDevicesChanged()
        #expect(backend.startedSessions.count == after)
    }

    @Test("設定跨重啟保留：新引擎接上同一份設定，取得權限後自動恢復")
    func settingsSurviveRestart() {
        let backend = FakeTapBackend()
        let registry = AudioProcessRegistry()
        injectAudibleApp(registry)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tap-restart-\(UUID().uuidString)")!)

        let first = TapEngine(backend: backend, registry: registry, settings: settings)
        first.setEnabled(true)
        first.healthTick()
        first.setGain(0.3, bundleID: "com.apple.Music")
        first.setEnabled(false)

        // 模擬重啟：同一份 SettingsStore，全新引擎
        settings.audioTapsEnabled = true
        let second = TapEngine(backend: backend, registry: registry, settings: settings)
        second.start()
        #expect(second.state == .probing)
        second.healthTick()
        #expect(second.state == .active)
        #expect(second.tappedBundles == ["com.apple.Music"])
        #expect(second.setting(for: "com.apple.Music").gain == 0.3)
    }
}
