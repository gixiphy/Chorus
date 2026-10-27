import ChorusCore
import CoreAudio
import Foundation
import Testing
@testable import Chorus

/// 來電接手 hold／靜音不變式（D-2026-10-27；正式版只無聲＝NullPlaybackController）。
@MainActor
@Suite("Call handoff hold")
struct CallHandoffHoldTests {
    private let music = "com.apple.Music"
    private let safari = "com.apple.Safari"
    private let screen = "ChorusAudioDevice_UID"
    private let airpods = "94-16-25-48-CC-A9:output"
    private let airpods4 = "F8-D3-F0-59-73-BD:output"
    private let headsetB = "headset-b"
    private let builtIn = "BuiltInSpeakerDevice"

    @MainActor
    final class TestClock {
        private var now: ContinuousClock.Instant
        init() { now = ContinuousClock.now }
        func instant() -> ContinuousClock.Instant { now }
        func advance(by duration: Duration) { now = now.advanced(by: duration) }
    }

    private struct Harness {
        let engine: TapEngine
        let backend: FakeTapBackend
        let registry: AudioProcessRegistry
        let settings: SettingsStore
        let playback: FakePlaybackController?
        let clock: TestClock
    }

    private func rate(_ hz: Double) -> NominalSampleRate {
        NominalSampleRate(hertz: hz)!
    }

    private func makeHarness(useNullPlayback: Bool = false) -> Harness {
        let backend = FakeTapBackend()
        backend.availableOutputUIDs = [airpods, headsetB, builtIn, screen]
        backend.defaultOutputUID = airpods
        let registry = AudioProcessRegistry()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "handoff-\(UUID().uuidString)")!)
        let clock = TestClock()
        let playback: FakePlaybackController?
        let engine: TapEngine
        if useNullPlayback {
            playback = nil
            engine = TapEngine(backend: backend, registry: registry, settings: settings)
        } else {
            let fake = FakePlaybackController()
            fake.addressable = [music]
            playback = fake
            engine = TapEngine(backend: backend, registry: registry, settings: settings, playback: fake)
        }
        engine.currentInstant = { clock.instant() }
        engine.rebuildDelay = .seconds(3600)
        engine.handoffSettleDelay = .seconds(3)
        engine.pauseSettleDelay = .seconds(1)
        engine.playbackVerifyDelay = .seconds(2)
        registry.injectFake([
            .init(objectID: 1001, pid: 2001, bundleID: music, name: "Music", isAudible: true),
            .init(objectID: 1002, pid: 2002, bundleID: safari, name: "Safari", isAudible: true),
        ])
        if let playback {
            playback.onSend = { command, bundleID in
                var entries = registry.processes
                for i in entries.indices where entries[i].bundleID == bundleID {
                    entries[i].isAudible = (command == .play)
                }
                registry.injectFake(entries)
            }
        }
        engine.setEnabled(true)
        engine.healthTick()
        return Harness(
            engine: engine, backend: backend, registry: registry,
            settings: settings, playback: playback, clock: clock
        )
    }

    private func setAudible(_ registry: AudioProcessRegistry, _ bundleID: String, _ audible: Bool) {
        var entries = registry.processes
        for i in entries.indices where entries[i].bundleID == bundleID {
            entries[i].isAudible = audible
        }
        registry.injectFake(entries)
    }

    private func assertSilent(_ backend: FakeTapBackend, mark: Int) {
        #expect(backend.sourceOutput(for: music) != screen)
        #expect(backend.muteGaps(for: music, since: mark).isEmpty)
    }

    private func reproduce1440(_ h: Harness) -> Int {
        h.engine.setGain(0.5, bundleID: music)
        h.backend.nominalRates[airpods] = rate(24000)
        let mark = h.backend.events.count
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        h.engine.audioDevicesChanged()
        h.backend.nominalRates[airpods] = rate(48000)
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(48000))
        h.engine.audioDevicesChanged()
        h.clock.advance(by: .seconds(11))
        return mark
    }

    private func takeAway(_ h: Harness, defaultFirst: Bool) {
        h.backend.availableOutputUIDs.removeAll { $0 == airpods }
        h.backend.defaultOutputUID = screen
        if defaultFirst {
            h.backend.simulateDefaultOutputChange()
            h.engine.audioDevicesChanged()
        } else {
            h.engine.audioDevicesChanged()
            h.backend.simulateDefaultOutputChange()
        }
    }

    private func restoreAirpods(_ h: Harness, defaultToAirpods: Bool = true) {
        if !h.backend.availableOutputUIDs.contains(airpods) {
            h.backend.availableOutputUIDs.append(airpods)
        }
        if defaultToAirpods { h.backend.defaultOutputUID = airpods }
        h.engine.audioDevicesChanged()
    }

    // MARK: - Hold & silence

    @Test("H1 來電帶走耳機（先消失再換預設）：全程靜音、不進 Screen Output")
    func h1() {
        let h = makeHarness()
        let mark = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        #expect(!h.backend.startedOutputs.contains(screen))
        #expect(!h.backend.startedOutputs.contains(builtIn))
        #expect(h.engine.hasMuteGuard(bundleID: music))
        #expect(h.engine.setting(for: music).outputDeviceUID == nil)
        #expect(!h.engine.tappedBundles.contains(music))
        assertSilent(h.backend, mark: mark)
    }

    @Test("H1b 先換預設、裝置還列著 → 延後跟隨後再消失")
    func h1b() {
        let h = makeHarness()
        let mark = reproduce1440(h)
        h.backend.defaultOutputUID = screen
        h.backend.simulateDefaultOutputChange()
        assertSilent(h.backend, mark: mark)
        #expect(h.engine.activeOutputUID(bundleID: music) == airpods)
        h.backend.availableOutputUIDs.removeAll { $0 == airpods }
        h.engine.audioDevicesChanged()
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        #expect(h.engine.hasMuteGuard(bundleID: music))
        assertSilent(h.backend, mark: mark)
    }

    @Test("H1c 重新配置已拆 tap、裝置接著消失：拆之前已有 guard")
    func h1c() {
        let h = makeHarness()
        h.engine.setGain(0.5, bundleID: music)
        let mark = h.backend.events.count
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        #expect(h.backend.events.contains("silencer+:\(music)"))
        #expect(h.backend.sourceOutput(for: music) == nil)
        assertSilent(h.backend, mark: mark)
        takeAway(h, defaultFirst: true)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        #expect(h.backend.startedSilencers.count == 1)
        let silencerIdx = h.backend.events.firstIndex(of: "silencer+:\(music)")!
        let stopIdx = h.backend.events.firstIndex(of: "stop:\(music)")!
        #expect(silencerIdx < stopIdx)
        assertSilent(h.backend, mark: mark)
    }

    @Test("H1d UID 已有語音紀錄，回到 48 kHz 的重新配置也先建 guard")
    func h1d() {
        let h = makeHarness()
        h.engine.setGain(0.5, bundleID: music)
        h.backend.nominalRates[airpods] = rate(24000)
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        h.engine.audioDevicesChanged()
        let mark = h.backend.events.count
        #expect(h.backend.events.contains("silencer+:\(music)"))
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(48000))
        assertSilent(h.backend, mark: mark)
    }

    @Test("H2 原耳機回來：先接回路由，再自動播放 Chorus 暫停的")
    func h2() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1))
        h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2))
        h.engine.handoffPlaybackTick()
        let before = h.backend.startedSessions.filter { $0.kind == .playthrough && $0.target == music }.count
        restoreAirpods(h)
        let after = h.backend.startedSessions.filter { $0.kind == .playthrough && $0.target == music }.count
        #expect(after == before + 1)
        #expect(h.engine.activeOutputUID(bundleID: music) == airpods)
        #expect(h.playback?.commands.map(\.command) == [.pause, .play])
        #expect(h.engine.heldOutputUID(bundleID: music) == nil)
        #expect(h.backend.liveSessions[music]?.lastGain == 0.5)
        #expect(h.engine.setting(for: music).outputDeviceUID == nil)
        let playIdx = h.backend.events.firstIndex(of: "play:\(music)@\(airpods)")!
        // .play 送出時 events 已含 play:Music@airpods —— finishHold 在建 session 之後
        #expect(h.backend.events[playIdx...].contains(where: { $0.hasPrefix("play:") }))
    }

    @Test("H2b 回來時預設仍是 screen：仍建回原 UID")
    func h2b() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        restoreAirpods(h, defaultToAirpods: false)
        #expect(h.engine.activeOutputUID(bundleID: music) == airpods)
    }

    @Test("H2c 原 UID 回來時語音紀錄已過期：接回後解除武裝")
    func h2c() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(61))
        restoreAirpods(h)
        #expect(!h.engine.hasMuteGuard(bundleID: music))
        let playIdx = h.backend.events.lastIndex(of: "play:\(music)@\(airpods)")!
        let silencerMinus = h.backend.events.lastIndex(of: "silencer-:\(music)")!
        #expect(silencerMinus > playIdx)
    }

    @Test("H3 一般拔除（沒有語音取樣率）：退回系統預設")
    func h3() {
        let h = makeHarness()
        h.engine.setGain(0.5, bundleID: music)
        takeAway(h, defaultFirst: false)
        #expect(h.engine.activeOutputUID(bundleID: music) == screen)
        #expect(h.backend.startedSilencers.isEmpty)
        #expect(h.engine.heldOutputUID(bundleID: music) == nil)
        #expect(h.playback?.commands.isEmpty == true)
    }

    @Test("H3b 指定路由的一般拔除")
    func h3b() {
        let h = makeHarness()
        h.engine.setOutputDevice(airpods, bundleID: music)
        h.engine.setGain(0.5, bundleID: music)
        h.backend.availableOutputUIDs.removeAll { $0 == airpods }
        h.backend.defaultOutputUID = screen
        h.engine.audioDevicesChanged()
        #expect(h.engine.activeOutputUID(bundleID: music) == screen)
        #expect(h.engine.lastTapError != nil)
        #expect(h.engine.setting(for: music).outputDeviceUID == airpods)
        #expect(!h.engine.hasMuteGuard(bundleID: music))
    }

    @Test("H4 只有取樣率變化、裝置還在：延遲重建、不 hold")
    func h4() {
        let h = makeHarness()
        h.engine.setGain(0.5, bundleID: music)
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        #expect(h.engine.hasMuteGuard(bundleID: music))
        h.engine.audioDevicesChanged()
        #expect(h.engine.heldOutputUID(bundleID: music) == nil)
        #expect(h.playback?.commands.isEmpty == true)
        h.clock.advance(by: .seconds(60) + .milliseconds(1))
        h.engine.audioDevicesChanged()
        #expect(!h.engine.hasMuteGuard(bundleID: music))
        #expect(!h.backend.startedOutputs.contains(screen))
    }

    @Test("H4b 降噪切換（非語音頻段）完全是基線行為")
    func h4b() {
        let h = makeHarness()
        h.engine.setGain(0.5, bundleID: music)
        let session = h.backend.liveSessions[music]
        session?.simulateDeviceReconfigured(to: rate(44100))
        #expect(h.backend.startedSilencers.isEmpty)
        #expect(session?.stopped == true)
        // 延遲重建被設成 3600s；手動對帳重建
        h.engine.audioDevicesChanged()
        #expect(h.engine.activeOutputUID(bundleID: music) == airpods)
    }

    @Test("H5 語音紀錄超過 60 s 後的普通消失")
    func h5() {
        let h = makeHarness()
        // reproduce1440 已從最後一次 24 kHz 推進 11 s；再推到 60.001 s
        _ = reproduce1440(h)
        h.clock.advance(by: .seconds(49) + .milliseconds(1))
        h.engine.audioDevicesChanged()
        takeAway(h, defaultFirst: false)
        #expect(h.engine.activeOutputUID(bundleID: music) == screen)
        #expect(h.engine.heldOutputUID(bundleID: music) == nil)
    }

    @Test("H5b 剛好 60 s 仍算來電")
    func h5b() {
        let h = makeHarness()
        let mark = reproduce1440(h)
        // reproduce1440 已 +11 s；再 +49 s＝距最後一次 24 kHz 剛好 60.000 s
        h.clock.advance(by: .seconds(49))
        takeAway(h, defaultFirst: false)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        assertSilent(h.backend, mark: mark)
    }

    @Test("H6 語音紀錄撐過回到 48000 Hz（約 14 s）")
    func h6() {
        let h = makeHarness()
        _ = reproduce1440(h)
        h.clock.advance(by: .seconds(3))
        takeAway(h, defaultFirst: false)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
    }

    @Test("H7 等待中使用者指定 screen：結束等待、不自動播放")
    func h7() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.engine.setOutputDevice(screen, bundleID: music)
        #expect(h.engine.heldOutputUID(bundleID: music) == nil)
        #expect(h.engine.activeOutputUID(bundleID: music) == screen)
        let playIdx = h.backend.events.lastIndex(of: "play:\(music)@\(screen)")!
        let silencerMinus = h.backend.events.lastIndex(of: "silencer-:\(music)")!
        #expect(playIdx < silencerMinus)
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
        #expect(h.engine.setting(for: music).outputDeviceUID == screen)
    }

    @Test("H7b 等待中使用者選跟隨預設")
    func h7b() {
        let h = makeHarness()
        h.engine.setOutputDevice(airpods, bundleID: music)
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.engine.setOutputDevice(nil, bundleID: music)
        #expect(h.engine.heldOutputUID(bundleID: music) == nil)
        #expect(h.engine.activeOutputUID(bundleID: music) == screen)
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
    }

    @Test("H8 預設自動改到別的耳機：不結束等待、不播放")
    func h8() {
        let h = makeHarness()
        let mark = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        let playCount = h.backend.startedSessions.filter { $0.target == music }.count
        for uid in [airpods4, builtIn, screen] {
            h.backend.defaultOutputUID = uid
            if !h.backend.availableOutputUIDs.contains(uid) {
                h.backend.availableOutputUIDs.append(uid)
            }
            h.backend.simulateDefaultOutputChange()
            h.engine.audioDevicesChanged()
            #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
            #expect(h.backend.startedSessions.filter { $0.target == music }.count == playCount)
            #expect(h.backend.startedSilencers.count == 1)
            #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
            assertSilent(h.backend, mark: mark)
        }
    }

    @Test("H9 重跑對帳冪等")
    func h9() {
        let h = makeHarness()
        let mark = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        let playCount = h.backend.startedSessions.filter { $0.target == music }.count
        for _ in 0..<3 { h.engine.audioDevicesChanged() }
        for _ in 0..<2 { h.backend.simulateDefaultOutputChange() }
        h.engine.setGain(0.3, bundleID: music)
        h.engine.setMuted(true, bundleID: music)
        h.engine.setMuted(false, bundleID: music)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        for _ in 0..<3 { h.engine.handoffPlaybackTick() }
        #expect(h.backend.startedSessions.filter { $0.target == music }.count == playCount)
        #expect(h.backend.startedSilencers.count == 1)
        #expect(h.playback?.commands.filter { $0.command == .pause }.count == 1)
        assertSilent(h.backend, mark: mark)
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        restoreAirpods(h)
        let after = h.backend.startedSessions.filter { $0.target == music }.count
        #expect(after == playCount + 1)
        #expect(h.playback?.commands.filter { $0.command == .play }.count == 1)
        #expect(h.backend.liveSessions[music]?.initialGain == 0.3)
        for _ in 0..<3 { h.engine.audioDevicesChanged() }
        for _ in 0..<2 { h.engine.handoffPlaybackTick() }
        #expect(h.playback?.commands.filter { $0.command == .play }.count == 1)
    }

    @Test("H10 等待中的 App 從全域 tap 排除")
    func h10() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.engine.updateDeviceProcessing(deviceUID: screen, gain: 0.8, muted: false, eq: nil)
        #expect(h.backend.globalExclusions.contains(1001))
    }

    @Test("H11 reset、排除、停用會結束等待")
    func h11() {
        for mode in 0..<3 {
            let h = makeHarness()
            _ = reproduce1440(h)
            takeAway(h, defaultFirst: false)
            switch mode {
            case 0: h.engine.reset(bundleID: music)
            case 1: h.engine.setExcluded(true, bundleID: music)
            default: h.engine.setEnabled(false)
            }
            #expect(h.engine.heldOutputUID(bundleID: music) == nil)
            #expect(!h.engine.hasMuteGuard(bundleID: music))
            #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
            #expect(!h.backend.startedOutputs.suffix(2).contains(screen) || mode == 2)
        }
    }

    @Test("H12 guard 建不起來：不解除靜音、原生路徑不落到 screen")
    func h12() {
        let h = makeHarness()
        h.backend.silencerFailuresRemaining = 99
        h.engine.setGain(0.5, bundleID: music)
        let mark = h.backend.events.count
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        #expect(h.backend.liveSessions[music]?.stopped == false)
        takeAway(h, defaultFirst: true)
        for _ in 0..<2 { h.engine.audioDevicesChanged() }
        #expect(h.backend.liveSessions[music]?.stopped == false)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        #expect(!h.backend.startedOutputs.contains(screen))
        #expect(h.backend.sourceOutput(for: music) == nil)
        #expect(h.backend.muteGaps(for: music, since: mark).isEmpty)
        #expect(h.engine.lastTapError == nil)
    }

    @Test("H12b guard 之後建得起來：先建 guard、再收 stale session")
    func h12b() {
        let h = makeHarness()
        h.backend.silencerFailuresRemaining = 99
        h.engine.setGain(0.5, bundleID: music)
        let mark = h.backend.events.count
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        takeAway(h, defaultFirst: true)
        h.backend.silencerFailuresRemaining = 0
        h.engine.audioDevicesChanged()
        let silencerIdx = h.backend.events.firstIndex(of: "silencer+:\(music)")!
        let stopIdx = h.backend.events.firstIndex(of: "stop:\(music)")!
        #expect(silencerIdx < stopIdx)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        assertSilent(h.backend, mark: mark)
    }

    @Test("H13 回來時建 playthrough 失敗：維持 hold、不播放")
    func h13() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        h.backend.failingPlaythroughOutputs = [airpods]
        restoreAirpods(h)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        #expect(h.engine.hasMuteGuard(bundleID: music))
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
        h.backend.failingPlaythroughOutputs = []
        h.engine.audioDevicesChanged()
        #expect(h.engine.heldOutputUID(bundleID: music) == nil)
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) == true)
    }

    @Test("H14 指定路由到 airpods：hold、恢復，設定始終不變")
    func h14() {
        let h = makeHarness()
        h.engine.setOutputDevice(airpods, bundleID: music)
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        #expect(h.engine.heldOutputUID(bundleID: music) == airpods)
        #expect(h.engine.setting(for: music).outputDeviceUID == airpods)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        restoreAirpods(h)
        #expect(h.engine.setting(for: music).outputDeviceUID == airpods)
        #expect(h.engine.activeOutputUID(bundleID: music) == airpods)
    }

    @Test("H15 別的 UID 有語音紀錄，不影響這個 UID 的消失")
    func h15() {
        let h = makeHarness()
        h.engine.setGain(0.5, bundleID: safari)
        h.engine.setOutputDevice(airpods4, bundleID: safari)
        if !h.backend.availableOutputUIDs.contains(airpods4) {
            h.backend.availableOutputUIDs.append(airpods4)
        }
        h.engine.audioDevicesChanged()
        h.backend.nominalRates[airpods4] = rate(24000)
        h.backend.liveSessions[safari]?.simulateDeviceReconfigured(to: rate(24000))
        h.engine.setGain(0.5, bundleID: music)
        h.backend.availableOutputUIDs.removeAll { $0 == airpods }
        h.backend.defaultOutputUID = screen
        h.engine.audioDevicesChanged()
        #expect(h.engine.activeOutputUID(bundleID: music) == screen)
        #expect(!h.engine.hasMuteGuard(bundleID: music))
    }

    @Test("H16 先換預設、原耳機沒消失：寬限之後照常跟隨")
    func h16() {
        let h = makeHarness()
        _ = reproduce1440(h)
        h.backend.defaultOutputUID = screen
        h.backend.simulateDefaultOutputChange()
        #expect(h.engine.activeOutputUID(bundleID: music) == airpods)
        h.clock.advance(by: .seconds(3))
        h.engine.audioDevicesChanged()
        #expect(h.engine.activeOutputUID(bundleID: music) == screen)
        let silencerIdx = h.backend.events.firstIndex(of: "silencer+:\(music)")!
        let stopIdx = h.backend.events.lastIndex(of: "stop:\(music)")!
        #expect(silencerIdx < stopIdx)
    }

    @Test("N1 正式預設（Null）：只有靜音，不暫停也不播放")
    func n1() {
        let h = makeHarness(useNullPlayback: true)
        let mark = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1))
        h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: music) == .notAddressable)
        restoreAirpods(h)
        #expect(h.engine.activeOutputUID(bundleID: music) == airpods)
        assertSilent(h.backend, mark: mark)
    }

    // MARK: - Playback attribution

    @Test("P1 Now Playing 不是目標：不送暫停、不播放")
    func p1() {
        let h = makeHarness()
        h.playback?.addressable = [safari]
        let mark = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: music) == .notAddressable)
        #expect(h.playback?.commands.isEmpty == true)
        restoreAirpods(h)
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
        assertSilent(h.backend, mark: mark)
    }

    @Test("P2 等待中 Now Playing 換人：已暫停也不代按")
    func p2() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        h.playback?.addressable = [safari]
        restoreAirpods(h)
        #expect(h.playback?.commands.map(\.command) == [.pause])
    }

    @Test("P3 目標自己停下來：不是 Chorus 暫停的")
    func p3() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        setAudible(h.registry, music, false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: music) == .userAlreadyPaused)
        #expect(h.playback?.commands.isEmpty == true)
        restoreAirpods(h)
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
    }

    @Test("P3b 送出暫停後目標仍在發聲：視為失敗，不播")
    func p3b() {
        let h = makeHarness()
        h.playback?.onSend = nil
        let mark = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: music) == .failed)
        restoreAirpods(h)
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
        assertSilent(h.backend, mark: mark)
    }

    @Test("P3c 等待中使用者自己按了播放：不代按")
    func p3c() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(2)); h.engine.handoffPlaybackTick()
        setAudible(h.registry, music, true)
        restoreAirpods(h)
        #expect(h.playback?.commands.contains(where: { $0.command == .play }) != true)
    }

    @Test("P4 驗證到期前就回來：就地驗證後才決定")
    func p4() {
        let h = makeHarness()
        _ = reproduce1440(h)
        takeAway(h, defaultFirst: false)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: music) == .requested)
        restoreAirpods(h)
        #expect(h.playback?.commands.map(\.command) == [.pause, .play])
    }

    // MARK: - Deadlines

    @Test("D1 兩個 App 先後進入 hold：後進來的不讓先進來的提早驗證")
    func d1() {
        let h = makeHarness()
        h.playback?.addressable = [music, safari]
        h.engine.setGain(0.5, bundleID: music)
        h.engine.setGain(0.5, bundleID: safari)
        h.engine.setOutputDevice(headsetB, bundleID: safari)
        h.backend.nominalRates[airpods] = rate(24000)
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        h.backend.availableOutputUIDs.removeAll { $0 == airpods }
        h.backend.defaultOutputUID = screen
        h.engine.audioDevicesChanged()
        let t0 = h.clock.instant()
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: music) == .requested)
        h.clock.advance(by: .milliseconds(500))
        h.backend.nominalRates[headsetB] = rate(24000)
        h.backend.liveSessions[safari]?.simulateDeviceReconfigured(to: rate(24000))
        h.backend.availableOutputUIDs.removeAll { $0 == headsetB }
        h.engine.audioDevicesChanged()
        #expect(h.engine.heldOutputUID(bundleID: safari) == headsetB)
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: safari) == .requested)
        #expect(h.engine.handoffPauseState(bundleID: music) == .requested)
        h.clock.advance(by: .milliseconds(500)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: music) == .confirmed)
        #expect(h.engine.handoffPauseState(bundleID: safari) == .requested)
        h.clock.advance(by: .seconds(1) + .milliseconds(500)); h.engine.handoffPlaybackTick()
        #expect(h.engine.handoffPauseState(bundleID: safari) == .confirmed)
        _ = t0
    }

    @Test("D2 排程取最早的期限")
    func d2() {
        let h = makeHarness()
        h.playback?.addressable = [music, safari]
        h.engine.setGain(0.5, bundleID: music)
        h.engine.setGain(0.5, bundleID: safari)
        h.engine.setOutputDevice(headsetB, bundleID: safari)
        h.backend.nominalRates[airpods] = rate(24000)
        h.backend.liveSessions[music]?.simulateDeviceReconfigured(to: rate(24000))
        let t0 = h.clock.instant()
        h.backend.availableOutputUIDs.removeAll { $0 == airpods }
        h.backend.defaultOutputUID = screen
        h.engine.audioDevicesChanged()
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .milliseconds(500))
        h.backend.nominalRates[headsetB] = rate(24000)
        h.backend.liveSessions[safari]?.simulateDeviceReconfigured(to: rate(24000))
        h.backend.availableOutputUIDs.removeAll { $0 == headsetB }
        h.engine.audioDevicesChanged()
        #expect(h.engine.nextHandoffPlaybackDue() == t0.advanced(by: .seconds(2) + .milliseconds(500)))
        h.clock.advance(by: .seconds(1)); h.engine.handoffPlaybackTick()
        #expect(h.engine.nextHandoffPlaybackDue() == t0.advanced(by: .seconds(3)))
        h.clock.advance(by: .milliseconds(500)); h.engine.handoffPlaybackTick()
        h.clock.advance(by: .seconds(1) + .milliseconds(500)); h.engine.handoffPlaybackTick()
        #expect(h.engine.nextHandoffPlaybackDue() == nil)
    }
}
