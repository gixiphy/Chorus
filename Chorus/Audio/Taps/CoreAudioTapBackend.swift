import ChorusCore
import CoreAudio
import Foundation
import Synchronization

/// IOProc 與主執行緒之間的共享狀態。**跨執行緒的欄位只有 atomic**——
/// realtime 紀律（PLAN §8-2）：callback 內禁止 malloc／lock／ObjC 訊息。
final class TapRenderContext: @unchecked Sendable {
    let playthrough: Bool
    /// 主執行緒寫、render 讀：使用者要的增益（0–4x）。
    let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    let muted = Atomic<Bool>(false)
    let callbacks = Atomic<Int>(0)
    let nonZeroCallbacks = Atomic<Int>(0)

    /// **只有 render 執行緒碰**：斜坡目前走到的增益值。
    /// 不是 atomic，因為它不跨執行緒——加 atomic 只會讓 realtime 端
    /// 多付一次同步成本換取沒人需要的可見性。
    var currentGain: Float

    /// `initialGain` 讓 session **從正確的值起步**。若一律從 1 起步，
    /// 一個設定成 20% 的 App 每次重啟都會先響 10 ms 的全音量再滑下去。
    init(playthrough: Bool, initialGain: Float = 1) {
        self.playthrough = playthrough
        gainBits.store(initialGain.bitPattern, ordering: .relaxed)
        currentGain = initialGain
    }
}

/// 真實 CoreAudio 實作。呼叫路徑與 `scripts/spike-audio-tap.swift` 的實測
/// 一致：tap → private aggregate（掛 drift compensation）→ IOProc。
///
/// 殘留清理：aggregate 一律 `IsPrivate`，**由 coreaudiod 綁定建立行程的
/// 生命週期**——App 崩潰時系統自動回收，不需要 FineTune 的
/// OrphanedTapCleanup 類啟動掃除（他們的 aggregate 應是非 private）。
@MainActor
final class CoreAudioTapBackend: TapBackend {
    func defaultOutputDeviceUID() -> String? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return Self.stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    func startProbeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID]
    ) throws -> any TapSession {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludingProcessObjects)
        description.name = "Chorus permission probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted // 只讀不寫，來源照常播放
        return try makeSession(description: description, outputDeviceUID: outputDeviceUID, kind: .captureOnly)
    }

    func startPlaythroughSession(
        bundleID: String,
        outputDeviceUID: String,
        initialGain: Float
    ) throws -> any TapSession {
        guard bundleID != Bundle.main.bundleIdentifier else {
            throw TapBackendError.refusedSelfTap
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.bundleIDs = [bundleID]
        // App 退出重啟由系統重綁，我們不用輪詢 process 清單（macOS 26）
        description.isProcessRestoreEnabled = true
        description.name = "Chorus per-app (\(bundleID))"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped // 來源靜音，由我們寫回
        return try makeSession(
            description: description, outputDeviceUID: outputDeviceUID,
            kind: .playthrough, initialGain: initialGain
        )
    }

    func setDefaultOutputChangedHandler(_ handler: @escaping @MainActor () -> Void) {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    // MARK: - session 組裝

    private func makeSession(
        description: CATapDescription,
        outputDeviceUID: String,
        kind: TapSessionKind,
        initialGain: Float = 1
    ) throws -> any TapSession {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr else { throw TapBackendError.createTapFailed(createStatus) }

        guard let tapUID = Self.stringProperty(tapID, kAudioTapPropertyUID) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapBackendError.tapUIDUnavailable
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Chorus Tap",
            kAudioAggregateDeviceUIDKey: "com.hermes.Chorus.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapBackendError.createAggregateFailed(aggregateStatus)
        }

        let context = TapRenderContext(playthrough: kind == .playthrough, initialGain: initialGain)
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, nil, Self.makeRenderBlock(context: context)
        )
        guard procStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw TapBackendError.createIOProcFailed(procStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw TapBackendError.startFailed(startStatus)
        }

        return CoreAudioTapSession(
            kind: kind, context: context,
            tapID: tapID, aggregateID: aggregateID, procID: procID
        )
    }

    /// IOProc 的 render block。
    ///
    /// **必須是 `nonisolated static`**：若把 closure 直接寫在 `@MainActor` 的
    /// `makeSession` 裡，Swift 會讓它繼承 MainActor 隔離，於是每次回呼都在
    /// CoreAudio 的 realtime 執行緒上跑 `swift_task_isCurrentExecutor` 檢查
    /// ——斷言失敗、SIGTRAP，App 在第一個 buffer 就崩潰（實測驗到）。
    /// 這正是 PLAN §8-2「callback 內禁止 Swift 未確定 runtime 行為」的實例。
    ///
    /// 內容只有指標運算與 atomic：不配置、不上鎖、不呼叫 ObjC。
    /// 增益的斜坡與 soft-clip 都由 ChorusCore 的 `GainRamp`／`SoftClip`
    /// 提供（`@inlinable`，會內聯進來）——**realtime 走的就是被單元測試
    /// 測到的那份程式碼**，不是它的複製品。
    private nonisolated static func makeRenderBlock(context: TapRenderContext) -> AudioDeviceIOBlock {
        { _, inInputData, _, outOutputData, _ in
            context.callbacks.add(1, ordering: .relaxed)
            // 靜音＝目標增益 0，不是另一條旁路：兩者走同一條斜坡才不會喀噠
            let requested = Float(bitPattern: context.gainBits.load(ordering: .relaxed))
            let target = context.muted.load(ordering: .relaxed) ? 0 : requested
            let playthrough = context.playthrough

            let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outputList = UnsafeMutableAudioBufferListPointer(outOutputData)

            // frames ≠ 樣本數：立體聲一次回呼有兩倍樣本，但只走過一次時間。
            // 交錯（1 buffer × 2 ch）與分離（2 buffer × 1 ch）兩種佈局都要對，
            // 所以 frame 數一律由 mNumberChannels 推回去
            var frames = 0
            if let first = inputList.first {
                let channels = max(1, Int(first.mNumberChannels))
                frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            }
            let startGain = context.currentGain
            let endGain = GainRamp.advance(current: startGain, target: target, frames: frames)
            context.currentGain = endGain
            // 回呼「之間」由 GainRamp 限速，回呼「之內」由這條插值鋪平
            let gainStep = frames > 0 ? (endGain - startGain) / Float(frames) : 0
            // >1x 才過 limiter：增益 ≤ 1 時任何壓縮都是不請自來的染色
            let boosting = startGain > 1 || endGain > 1

            var sawNonZero = false
            for (index, inputBuffer) in inputList.enumerated() {
                guard let source = inputBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(inputBuffer.mNumberChannels))
                let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

                if playthrough, index < outputList.count,
                   let destination = outputList[index].mData?.assumingMemoryBound(to: Float.self) {
                    let writable = min(sampleCount, Int(outputList[index].mDataByteSize) / MemoryLayout<Float>.size)
                    let writableFrames = writable / channels
                    for frame in 0..<writableFrames {
                        let gain = startGain + gainStep * Float(frame)
                        for channel in 0..<channels {
                            let offset = frame * channels + channel
                            let raw = source[offset]
                            if raw != 0 { sawNonZero = true }
                            let amplified = raw * gain
                            destination[offset] = boosting ? SoftClip.apply(amplified) : amplified
                        }
                    }
                    // 通道數不整除時剩下的尾巴補零，別讓上一輪的內容漏出去
                    for offset in (writableFrames * channels)..<writable {
                        destination[offset] = 0
                    }
                } else {
                    // captureOnly：只讀不寫（HAL 已預先把輸出 buffer 清零）
                    for sample in 0..<sampleCount where source[sample] != 0 {
                        sawNonZero = true
                        break
                    }
                }
            }
            if sawNonZero {
                context.nonZeroCallbacks.add(1, ordering: .relaxed)
            }
        }
    }

    // MARK: - property 小工具

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated static func stringProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }
}

@MainActor
private final class CoreAudioTapSession: TapSession {
    let kind: TapSessionKind
    private let context: TapRenderContext
    private var tapID: AudioObjectID
    private var aggregateID: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    init(
        kind: TapSessionKind, context: TapRenderContext,
        tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID
    ) {
        self.kind = kind
        self.context = context
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
    }

    var stats: TapSessionStats {
        TapSessionStats(
            callbacks: context.callbacks.load(ordering: .relaxed),
            nonZeroCallbacks: context.nonZeroCallbacks.load(ordering: .relaxed)
        )
    }

    func setGain(_ gain: Float) {
        context.gainBits.store(max(0, gain).bitPattern, ordering: .relaxed)
    }

    func setMuted(_ muted: Bool) {
        context.muted.store(muted, ordering: .relaxed)
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        self.procID = nil
    }
}
