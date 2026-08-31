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

    @Test("denied 不是終態：裝置變動後自動重探測（藍牙重協商的誤判要能自癒）")
    func deniedReProbesOnDeviceChange() async throws {
        let (engine, backend, registry) = makeEngine(mode: .zeros)
        injectAudibleApp(registry)
        engine.rebuildDelay = .zero
        engine.setEnabled(true)
        engine.healthTick(); engine.healthTick()
        #expect(engine.state == .denied)

        backend.mode = .audio // 空窗過了，樣本恢復非零
        engine.audioDevicesChanged()
        for _ in 0..<100 {
            if engine.state == .probing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.state == .probing)
        engine.healthTick()
        #expect(engine.state == .active)
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

    // MARK: - B6-4：裝置級軟體音量（三後端矩陣第三條）

    @Test("開啟軟體音量 → 一條全域 session；關掉就收")
    func softwareVolumeStartsAndStopsOneGlobalSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        #expect(engine.deviceTapUID == nil)

        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil)
        #expect(engine.deviceTapUID == "fake-headphones")
        #expect(backend.globalSession?.initialGain == 0.5)

        engine.updateDeviceProcessing(deviceUID: nil, gain: 1, muted: false, eq: nil)
        #expect(engine.deviceTapUID == nil)
        #expect(backend.globalSession?.stopped == true)
    }

    @Test("調音量不重建 session——只推 atomic")
    func volumeChangesDoNotRebuild() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil)
        let after = backend.globalStartCount
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.2, muted: true, eq: nil)
        #expect(backend.globalStartCount == after)
        #expect(backend.globalSession?.lastGain == 0.2)
        #expect(backend.globalSession?.lastMuted == true)
    }

    @Test("每一路音訊只處理一次：被 per-app tap 抓走的行程要從全域 tap 排除")
    func perAppTappedProcessesAreExcluded() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        registry.injectFake([
            .init(objectID: 1001, pid: 2001, bundleID: "com.apple.Music", name: "Music", isAudible: true),
            .init(objectID: 1002, pid: 2002, bundleID: "com.apple.Safari", name: "Safari", isAudible: false),
        ])
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil)
        #expect(!backend.globalExclusions.contains(1001))

        // Music 被 per-app tap 接管 → 必須從全域 tap 排除，否則衰減兩次
        engine.setGain(0.5, bundleID: "com.apple.Music")
        #expect(backend.globalExclusions.contains(1001))
        #expect(!backend.globalExclusions.contains(1002))

        // 放掉 per-app → 回到全域 tap 的守備範圍
        engine.reset(bundleID: "com.apple.Music")
        #expect(!backend.globalExclusions.contains(1001))
    }

    @Test("目標裝置不在就不建——不要在錯的裝置上默默衰減")
    func missingDeviceMeansNoSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "gone-uid", gain: 0.5, muted: false, eq: nil)
        #expect(engine.deviceTapUID == nil)

        backend.availableOutputUIDs.append("gone-uid")
        engine.audioDevicesChanged()
        engine.updateDeviceProcessing(deviceUID: "gone-uid", gain: 0.5, muted: false, eq: nil)
        #expect(engine.deviceTapUID == "gone-uid")
    }

    @Test("停用引擎收掉全域 session（per-app 與裝置級一起收）")
    func disablingStopsTheGlobalSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil)
        engine.setEnabled(false)
        #expect(engine.deviceTapUID == nil)
        #expect(backend.globalSession?.stopped == true)
    }

    // MARK: - B6-5：裝置級等化

    private var sampleEQ: EQSettings {
        var settings = EQSettings.tenBandDefault()
        settings.bands[3].gainDB = 6
        return settings
    }

    @Test("裝置中途重新配置（藍牙耳機切降噪）→ 立即收掉、延遲後重建、設定原樣重放")
    func deviceReconfigureRebuildsSession() async throws {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.rebuildDelay = .zero // 正式值 1.5s（等藍牙鏈路穩定）
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        let first = backend.liveSessions["com.apple.Music"]
        #expect(first != nil)

        first?.simulateDeviceReconfigured()
        #expect(first?.stopped == true) // 立即收掉——過期格式不能繼續出聲

        var rebuilt: FakeTapSession?
        for _ in 0..<100 {
            rebuilt = backend.liveSessions["com.apple.Music"]
            if rebuilt !== first { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rebuilt !== first) // 新的 aggregate（新格式）
        #expect(rebuilt?.lastGain == 0.5) // 設定原樣重放
        #expect(engine.tappedBundles == ["com.apple.Music"])
    }

    @Test("App 層 EQ（B6-8）：只開 EQ 就建 tap，App 層與裝置層各自送達、互不混用")
    func perAppEQFlowsToItsOwnLayer() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()

        // gain 還是 1，只開 App 層 EQ → 也要建 tap（needsTap）
        engine.setAppEQ(sampleEQ, bundleID: "com.apple.Music")
        let session = backend.liveSessions["com.apple.Music"]
        #expect(session != nil)
        #expect(session?.lastAppEQ?.bands.count == 10)
        #expect(session?.lastEQ == nil) // 裝置層沒開就不該有

        // 裝置層也開 → 兩層各自送達（App 先、裝置後由 render 保證）
        engine.updateDeviceProcessing(
            deviceUID: "fake-output-uid", gain: 1, muted: false, eq: sampleEQ
        )
        #expect(session?.lastEQ?.bands.count == 10)
        #expect(session?.lastAppEQ?.bands.count == 10)

        // App 層 EQ 拆掉 → session 收掉（沒有其他調整了）
        engine.setAppEQ(nil, bundleID: "com.apple.Music")
        #expect(backend.liveSessions["com.apple.Music"]?.stopped == true)
    }

    @Test("per-app session 也套裝置級處理（相乘、單次）——被接管的 App 不再繞過裝置 EQ 與軟體音量")
    func perAppSessionCarriesDeviceProcessing() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        // 裝置級處理的目標＝該 session 的輸出裝置（預設輸出）
        engine.updateDeviceProcessing(
            deviceUID: "fake-output-uid", gain: 0.5, muted: false, eq: sampleEQ
        )
        let session = backend.liveSessions["com.apple.Music"]
        #expect(session?.lastGain == 0.25) // 0.5（App）× 0.5（裝置）——相乘檢查點 D7
        #expect(session?.lastEQ?.bands.count == 10) // 裝置 EQ 跟著套（D14/D17 的形狀）

        // 收掉裝置級處理 → per-app 回到只有 App 自己的調整
        engine.updateDeviceProcessing(deviceUID: nil, gain: 1, muted: false, eq: nil)
        #expect(session?.lastGain == 0.5)
        #expect(session?.lastEQ == nil)
    }

    @Test("路由到別的裝置的 App 不套預設輸出的裝置級處理")
    func routedSessionSkipsOtherDevicesProcessing() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Music")
        engine.updateDeviceProcessing(
            deviceUID: "fake-output-uid", gain: 0.5, muted: false, eq: sampleEQ
        )
        let session = backend.liveSessions["com.apple.Music"]
        #expect(session?.lastGain == 0.5) // 不乘別台裝置的軟體音量
        #expect(session?.lastEQ == nil)
    }

    @Test("EQ 送到全域 session；軟體音量與 EQ 共用同一條 tap")
    func eqSharesTheDeviceTap() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(
            deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: sampleEQ
        )
        #expect(engine.deviceTapUID == "fake-headphones")
        #expect(backend.globalStartCount == 1)
        #expect(backend.globalSession?.lastEQ?.bands.count == 10)
        #expect(backend.globalSession?.lastGain == 0.5)
    }

    @Test("只有 EQ、沒有軟體音量：一樣建 tap，增益維持 1（責任矩陣 §3.2）")
    func eqAloneKeepsGainAtUnity() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(
            deviceUID: "fake-headphones", gain: 1, muted: false, eq: sampleEQ
        )
        #expect(engine.deviceTapUID == "fake-headphones")
        #expect(backend.globalSession?.lastGain == 1)
    }

    @Test("換 EQ 不重建 session——只推新的係數")
    func changingEQDoesNotRebuild() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 1, muted: false, eq: sampleEQ)
        let after = backend.globalStartCount

        var changed = sampleEQ
        changed.bands[7].gainDB = -4
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 1, muted: false, eq: changed)
        #expect(backend.globalStartCount == after)
        #expect(backend.globalSession?.lastEQ?.bands[7].gainDB == -4)
    }

    @Test("EQ 拆掉就送 nil——樣本要原樣通過，不是留一組全平的係數在跑")
    func removingEQPushesNil() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: sampleEQ)
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil)
        #expect(backend.globalSession?.lastEQ == nil)
        #expect(engine.deviceTapUID == "fake-headphones") // 軟體音量還在，tap 留著
    }

    // MARK: - 裝置級左右平衡（軟體平衡，缺口批）

    @Test("平衡送到全域 session；只有平衡（無軟體音量、無 EQ）也建鏈")
    func balanceReachesTheGlobalSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(
            deviceUID: "fake-headphones", gain: 1, muted: false, eq: nil, balance: 0.4
        )
        #expect(engine.deviceTapUID == "fake-headphones")
        #expect(backend.globalSession?.lastBalance == 0.4)
        #expect(backend.globalSession?.lastGain == 1)
    }

    @Test("調平衡不重建 session——只推 atomic")
    func balanceChangesDoNotRebuild() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil, balance: 0.2)
        let after = backend.globalStartCount
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil, balance: -0.6)
        #expect(backend.globalStartCount == after)
        #expect(backend.globalSession?.lastBalance == -0.6)
    }

    @Test("被接管的 App 也套裝置平衡（在裝置鏈上）；路由到別台的不套")
    func perAppSessionsCarryDeviceBalanceOnlyOnTheChain() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        engine.setGain(0.5, bundleID: "com.apple.Safari")
        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Safari")

        // 裝置級處理目標＝預設輸出（Music 在鏈上、Safari 不在）
        engine.updateDeviceProcessing(
            deviceUID: "fake-output-uid", gain: 1, muted: false, eq: nil, balance: 0.3
        )
        #expect(backend.liveSessions["com.apple.Music"]?.lastBalance == 0.3)
        #expect(backend.liveSessions["com.apple.Safari"]?.lastBalance == 0)

        // 收掉裝置級處理 → 平衡跟著歸零
        engine.updateDeviceProcessing(deviceUID: nil, gain: 1, muted: false, eq: nil, balance: 0)
        #expect(backend.liveSessions["com.apple.Music"]?.lastBalance == 0)
    }

    // MARK: - AU 效果鏈（B6-8 AU-2b）

    private func sampleEffect(
        subtype: UInt32 = 0x64656C79, enabled: Bool = true
    ) -> AUEffectEntry {
        AUEffectEntry(
            component: AUEffectComponent(type: 0x61756678, subtype: subtype, manufacturer: 0x74657374),
            name: "TestFX-\(subtype)", manufacturerName: "Fake", enabled: enabled
        )
    }

    @Test("App 層效果鏈：只掛效果也建 tap，鏈送到 session 的 App 層")
    func appEffectsCreateAndReachTheSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()

        let effect = sampleEffect()
        engine.setAppEffects([effect], bundleID: "com.apple.Music")
        let session = backend.liveSessions["com.apple.Music"]
        #expect(session != nil)
        #expect(session?.lastAppEffects == [effect])
        #expect(session?.lastDeviceEffects == [])

        // 拆掉效果鏈 → 沒有其他調整了，session 收掉
        engine.setAppEffects([], bundleID: "com.apple.Music")
        #expect(backend.liveSessions["com.apple.Music"]?.stopped == true)
    }

    @Test("關掉的格不送進 session——enabled 才算數")
    func disabledEffectSlotsAreNotPushed() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        let on = sampleEffect(subtype: 1)
        let off = sampleEffect(subtype: 2, enabled: false)
        engine.setGain(0.5, bundleID: "com.apple.Music")
        engine.setAppEffects([on, off], bundleID: "com.apple.Music")
        #expect(backend.liveSessions["com.apple.Music"]?.lastAppEffects == [on])
    }

    @Test("隔離名單的格不自動載入（DESIGN §1.1）")
    func quarantinedEffectsAreFiltered() {
        let backend = FakeTapBackend()
        let registry = AudioProcessRegistry()
        injectAudibleApp(registry)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tap-au-\(UUID().uuidString)")!)
        let engine = TapEngine(backend: backend, registry: registry, settings: settings)
        engine.setEnabled(true)
        engine.healthTick()

        let bad = sampleEffect(subtype: 0xBAD)
        let good = sampleEffect(subtype: 0x600D)
        settings.effectQuarantine = [bad.component.key]
        engine.setAppEffects([bad, good], bundleID: "com.apple.Music")
        #expect(backend.liveSessions["com.apple.Music"]?.lastAppEffects == [good])
    }

    @Test("裝置級效果鏈：只有效果也建全域 session，鏈送到裝置層")
    func deviceEffectsAloneCreateTheGlobalSession() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        let effect = sampleEffect()
        engine.updateDeviceProcessing(
            deviceUID: "fake-headphones", gain: 1, muted: false, eq: nil, effects: [effect]
        )
        #expect(engine.deviceTapUID == "fake-headphones")
        #expect(backend.globalSession?.lastDeviceEffects == [effect])
    }

    @Test("被接管的 App 在裝置鏈上也套裝置效果鏈；路由到別台的不套")
    func perAppSessionsCarryDeviceEffectsOnlyOnTheChain() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        engine.setGain(0.5, bundleID: "com.apple.Safari")
        engine.setOutputDevice("fake-headphones", bundleID: "com.apple.Safari")

        let effect = sampleEffect()
        engine.updateDeviceProcessing(
            deviceUID: "fake-output-uid", gain: 1, muted: false, eq: nil, effects: [effect]
        )
        #expect(backend.liveSessions["com.apple.Music"]?.lastDeviceEffects == [effect])
        #expect(backend.liveSessions["com.apple.Safari"]?.lastDeviceEffects == [])
    }

    @Test("改效果鏈走得到 session——快路徑不能吞掉 effects 變更")
    func effectChangesGetThroughTheFastPath() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        let first = sampleEffect(subtype: 1)
        engine.setAppEffects([first], bundleID: "com.apple.Music")
        #expect(backend.liveSessions["com.apple.Music"]?.lastAppEffects == [first])

        // gain 沒變、只換效果——這正是快路徑判準漏掉 effects 時會吞掉的形狀
        let second = sampleEffect(subtype: 2)
        engine.setAppEffects([first, second], bundleID: "com.apple.Music")
        #expect(backend.liveSessions["com.apple.Music"]?.lastAppEffects == [first, second])
    }

    @Test("隔離閂接線：實例化期間武裝、成功後清空（pendingLoad 收尾必為 nil）")
    func effectLatchIsWiredAndCleared() {
        let backend = FakeTapBackend()
        let registry = AudioProcessRegistry()
        injectAudibleApp(registry)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tap-latch-\(UUID().uuidString)")!)
        let engine = TapEngine(backend: backend, registry: registry, settings: settings)
        engine.setEnabled(true)
        engine.healthTick()

        engine.setAppEffects([sampleEffect()], bundleID: "com.apple.Music")
        // fake 的建鏈流程會走 latch(key) → latch(nil)——收尾必須是清空的
        #expect(settings.effectPendingLoad == nil)
        #expect(backend.liveSessions["com.apple.Music"]?.effectLatch != nil)
    }

    // MARK: - 排除清單（Excluded Applications）

    @Test("排除的 App 不建 tap——調整保留但不生效，取消排除原樣恢復")
    func excludedAppGetsNoTap() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setGain(0.5, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles == ["com.apple.Music"])

        engine.setExcluded(true, bundleID: "com.apple.Music")
        #expect(engine.isExcluded(bundleID: "com.apple.Music"))
        #expect(engine.tappedBundles.isEmpty)
        #expect(backend.liveSessions["com.apple.Music"]?.stopped == true)
        #expect(engine.setting(for: "com.apple.Music").gain == 0.5) // 設定留著

        engine.setExcluded(false, bundleID: "com.apple.Music")
        #expect(engine.tappedBundles == ["com.apple.Music"])
        #expect(backend.liveSessions["com.apple.Music"]?.lastGain == 0.5)
    }

    @Test("排除的 App 也從裝置級全域 tap 排除——沒有 per-app 調整也一樣")
    func excludedAppLeavesTheGlobalTap() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        registry.injectFake([
            .init(objectID: 1001, pid: 2001, bundleID: "com.apple.Music", name: "Music", isAudible: true),
            .init(objectID: 1002, pid: 2002, bundleID: "com.apple.Safari", name: "Safari", isAudible: false),
        ])
        engine.setEnabled(true)
        engine.healthTick()
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil)
        #expect(!backend.globalExclusions.contains(1001))

        engine.setExcluded(true, bundleID: "com.apple.Music")
        #expect(backend.globalExclusions.contains(1001))
        #expect(!backend.globalExclusions.contains(1002))

        engine.setExcluded(false, bundleID: "com.apple.Music")
        #expect(!backend.globalExclusions.contains(1001))
    }

    @Test("先排除、App 後啟動：行程一出現就補進全域 tap 的排除清單")
    func excludedAppLaunchingLaterIsPickedUp() {
        let (engine, backend, registry) = makeEngine(mode: .audio)
        injectAudibleApp(registry)
        engine.setEnabled(true)
        engine.healthTick()
        engine.setExcluded(true, bundleID: "com.apple.Safari") // 還沒在跑
        engine.updateDeviceProcessing(deviceUID: "fake-headphones", gain: 0.5, muted: false, eq: nil)
        #expect(!backend.globalExclusions.contains(1002)) // 查不到行程，先排除不了

        // Safari 啟動——injectFake 會觸發 onProcessesChanged（與真實
        // process 清單 listener 同一條路），排除清單要跟著長
        registry.injectFake([
            .init(objectID: 1001, pid: 2001, bundleID: "com.apple.Music", name: "Music", isAudible: true),
            .init(objectID: 1002, pid: 2002, bundleID: "com.apple.Safari", name: "Safari", isAudible: true),
        ])
        #expect(backend.globalExclusions.contains(1002))
        #expect(!backend.globalExclusions.contains(1001))
    }

    @Test("排除清單跨重啟保留（與 per-app 設定同一份 SettingsStore）")
    func exclusionSurvivesRestart() {
        let backend = FakeTapBackend()
        let registry = AudioProcessRegistry()
        injectAudibleApp(registry)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tap-excl-\(UUID().uuidString)")!)

        let first = TapEngine(backend: backend, registry: registry, settings: settings)
        first.setEnabled(true)
        first.healthTick()
        first.setGain(0.5, bundleID: "com.apple.Music")
        first.setExcluded(true, bundleID: "com.apple.Music")
        first.setEnabled(false)

        settings.audioTapsEnabled = true
        let second = TapEngine(backend: backend, registry: registry, settings: settings)
        second.start()
        second.healthTick()
        #expect(second.state == .active)
        #expect(second.isExcluded(bundleID: "com.apple.Music"))
        #expect(second.tappedBundles.isEmpty) // 調整還在，但排除優先
        #expect(second.setting(for: "com.apple.Music").gain == 0.5)
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
