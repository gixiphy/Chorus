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

    @Test("active 前不能 tap；active 後 tap 建 playthrough session")
    func tapRequiresActive() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.tap(bundleID: "com.apple.Music")
        #expect(engine.tappedBundles.isEmpty) // probing 中拒絕
        engine.healthTick()
        engine.tap(bundleID: "com.apple.Music")
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
        engine.tap(bundleID: "com.apple.Music")
        engine.setEnabled(false)
        #expect(engine.state == .off)
        #expect(engine.tappedBundles.isEmpty)
    }

    @Test("預設輸出變更：per-app session 搬家（收舊建新）")
    func sessionsFollowDefaultOutput() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.tap(bundleID: "com.apple.Music")
        let before = backend.startedSessions.count
        backend.simulateDefaultOutputChange()
        #expect(backend.startedSessions.count == before + 1)
        #expect(engine.tappedBundles == ["com.apple.Music"])
    }

    @Test("拒絕 tap 自己——回音紀律")
    func refusesSelfTap() {
        let (engine, _, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.tap(bundleID: Bundle.main.bundleIdentifier ?? "com.hermes.Chorus")
        #expect(engine.tappedBundles.isEmpty)
    }
}
