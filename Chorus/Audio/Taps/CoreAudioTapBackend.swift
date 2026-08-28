import CoreAudio
import Foundation
import Synchronization

/// IOProc 與主執行緒之間的共享狀態。**只有 atomic**——realtime 紀律
/// （PLAN §8-2）：callback 內禁止 malloc／lock／ObjC 訊息。
final class TapRenderContext: @unchecked Sendable {
    let playthrough: Bool
    let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    let muted = Atomic<Bool>(false)
    let callbacks = Atomic<Int>(0)
    let nonZeroCallbacks = Atomic<Int>(0)

    init(playthrough: Bool) {
        self.playthrough = playthrough
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
        outputDeviceUID: String
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
        return try makeSession(description: description, outputDeviceUID: outputDeviceUID, kind: .playthrough)
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
        kind: TapSessionKind
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

        let context = TapRenderContext(playthrough: kind == .playthrough)
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
    private nonisolated static func makeRenderBlock(context: TapRenderContext) -> AudioDeviceIOBlock {
        { _, inInputData, _, outOutputData, _ in
            context.callbacks.add(1, ordering: .relaxed)
            let gain = Float(bitPattern: context.gainBits.load(ordering: .relaxed))
            let muted = context.muted.load(ordering: .relaxed)
            let playthrough = context.playthrough

            let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outputList = UnsafeMutableAudioBufferListPointer(outOutputData)
            var sawNonZero = false
            for (index, inputBuffer) in inputList.enumerated() {
                guard let source = inputBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

                if playthrough, index < outputList.count,
                   let destination = outputList[index].mData?.assumingMemoryBound(to: Float.self) {
                    let writable = min(sampleCount, Int(outputList[index].mDataByteSize) / MemoryLayout<Float>.size)
                    if muted {
                        for sample in 0..<writable { destination[sample] = 0 }
                    } else {
                        for sample in 0..<writable {
                            let value = source[sample] * gain
                            if value != 0 { sawNonZero = true }
                            destination[sample] = value
                        }
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
