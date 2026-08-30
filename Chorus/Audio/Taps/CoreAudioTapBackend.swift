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

    /// EQ 係數區塊的指標位元（0 ＝ 沒有 EQ）。見 `EQCoefficientBlock`。
    let eqBlock = Atomic<UInt>(0)

    /// **只有 render 執行緒碰**：斜坡目前走到的增益值。
    /// 不是 atomic，因為它不跨執行緒——加 atomic 只會讓 realtime 端
    /// 多付一次同步成本換取沒人需要的可見性。
    var currentGain: Float
    /// **只有 render 執行緒碰**：biquad 狀態（channel × band，預先配置）。
    /// realtime 端不能配置記憶體，所以上限在這裡就吃掉。
    let eqStates: UnsafeMutableBufferPointer<BiquadState>
    /// render 端看過的 EQ 版本號。與區塊裡的不同就把狀態歸零。
    var eqGeneration: UInt32 = 0

    static let maxChannels = 8

    /// `initialGain` 讓 session **從正確的值起步**。若一律從 1 起步，
    /// 一個設定成 20% 的 App 每次重啟都會先響 10 ms 的全音量再滑下去。
    init(playthrough: Bool, initialGain: Float = 1) {
        self.playthrough = playthrough
        gainBits.store(initialGain.bitPattern, ordering: .relaxed)
        currentGain = initialGain
        eqStates = UnsafeMutableBufferPointer<BiquadState>.allocate(
            capacity: Self.maxChannels * EQSettings.maxBands
        )
        eqStates.initialize(repeating: BiquadState())
    }

    deinit {
        eqStates.deallocate()
        let raw = eqBlock.load(ordering: .relaxed)
        if raw != 0, let block = UnsafeMutableRawPointer(bitPattern: raw) {
            EQCoefficientBlock.deallocate(block)
        }
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

    /// 有輸出串流的裝置。輸入裝置（麥克風）與純輸入的 aggregate 不算——
    /// 把它們列進路由選單只會讓使用者選到一個沒有聲音出來的目標。
    func outputDeviceUIDs() -> [String] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }
        return objects.compactMap { device in
            guard Self.hasOutputStreams(device) else { return nil }
            return Self.stringProperty(device, kAudioDevicePropertyDeviceUID)
        }
    }

    private nonisolated static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
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
        memberBundleIDs: [String],
        outputDeviceUID: String,
        initialGain: Float
    ) throws -> any TapSession {
        if let own = Bundle.main.bundleIdentifier,
           bundleID == own || memberBundleIDs.contains(own) {
            throw TapBackendError.refusedSelfTap
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.bundleIDs = memberBundleIDs.isEmpty ? [bundleID] : memberBundleIDs
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

    func startGlobalVolumeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID],
        initialGain: Float
    ) throws -> any TapSession {
        // 與探測用的全域 tap 是同一組初始化器，差在 muteBehavior：
        // 探測只讀（unmuted），這裡要接管（mutedWhenTapped），
        // 否則來源與我們寫回的會同時響＝音量加倍且相位打架
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludingProcessObjects)
        description.name = "Chorus device volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
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
            // EQ 係數：只讀一次指標，之後全是指標運算
            var eqCount = 0
            var preamp: Float = 1
            var eqCoefficients: UnsafePointer<BiquadCoefficients>?
            let rawBlock = context.eqBlock.load(ordering: .acquiring)
            if rawBlock != 0, let base = UnsafeRawPointer(bitPattern: rawBlock) {
                let header = base.assumingMemoryBound(to: EQCoefficientBlock.Header.self).pointee
                eqCount = min(Int(header.count), EQSettings.maxBands)
                preamp = header.preamp
                eqCoefficients = UnsafePointer((base + EQCoefficientBlock.coefficientOffset)
                    .assumingMemoryBound(to: BiquadCoefficients.self))
                // 換了一組係數 → 舊的濾波器狀態要歸零，否則會拖出一聲。
                // 主執行緒不能安全地碰 render 擁有的狀態，所以由這裡比對版本號
                if header.generation != context.eqGeneration {
                    context.eqGeneration = header.generation
                    for index in context.eqStates.indices { context.eqStates[index].reset() }
                }
            }

            // >1x 才過 limiter：增益 ≤ 1 時任何壓縮都是不請自來的染色。
            // EQ 開著時一律過——正增益的段即使配了 negative preamp，
            // 疊在本來就接近滿刻度的素材上仍可能過頂
            let boosting = startGain > 1 || endGain > 1 || eqCount > 0
            var channelBase = 0

            var sawNonZero = false
            for (index, inputBuffer) in inputList.enumerated() {
                guard let source = inputBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(inputBuffer.mNumberChannels))
                let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

                if playthrough, index < outputList.count,
                   let destination = outputList[index].mData?.assumingMemoryBound(to: Float.self) {
                    let writable = min(sampleCount, Int(outputList[index].mDataByteSize) / MemoryLayout<Float>.size)
                    let writableFrames = writable / channels
                    let states = context.eqStates.baseAddress
                    for frame in 0..<writableFrames {
                        let gain = (startGain + gainStep * Float(frame)) * preamp
                        for channel in 0..<channels {
                            let offset = frame * channels + channel
                            let raw = source[offset]
                            if raw != 0 { sawNonZero = true }
                            var value = raw * gain
                            // 每個聲道有自己的一整條 cascade 狀態
                            if let eqCoefficients, let states,
                               channelBase + channel < TapRenderContext.maxChannels {
                                let slot = (channelBase + channel) * EQSettings.maxBands
                                for band in 0..<eqCount {
                                    value = states[slot + band].process(value, eqCoefficients[band])
                                }
                            }
                            destination[offset] = boosting ? SoftClip.apply(value) : value
                        }
                    }
                    // 通道數不整除時剩下的尾巴補零，別讓上一輪的內容漏出去
                    for offset in (writableFrames * channels)..<writable {
                        destination[offset] = 0
                    }
                    channelBase += channels
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

    nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated static func doubleProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> Double? {
        var addr = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              value > 0 else { return nil }
        return value
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
    /// EQ 版本號：每換一組係數 +1，render 端靠它決定要不要歸零濾波器狀態。
    private var eqGeneration: UInt32 = 0
    /// 上次真正推進 render 端的 EQ（nil＝旁通）與當時的取樣率。
    /// 相同內容的重複推送在 `setEQ` 就地擋掉，見該處註解。
    private var lastPushedEQ: EQSettings?
    private var lastPushedSampleRate: Double = 0
    var onDeviceReconfigured: (@MainActor () -> Void)?
    private var rateListener: AudioObjectPropertyListenerBlock?

    init(
        kind: TapSessionKind, context: TapRenderContext,
        tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID
    ) {
        self.kind = kind
        self.context = context
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
        listenForRateChanges()
    }

    /// 藍牙耳機切降噪／通透會讓裝置中途改取樣率，aggregate 的格式綁在
    /// 建立時——不重建輕則雜音、重則卡在無聲。這裡只負責通知，
    /// 收舊建新由擁有者（TapEngine）做。
    private func listenForRateChanges() {
        var address = CoreAudioTapBackend.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onDeviceReconfigured?() }
        }
        rateListener = block
        AudioObjectAddPropertyListenerBlock(aggregateID, &address, .main, block)
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

    /// 換一組 EQ 係數。
    ///
    /// 配置新區塊 → 一次 atomic store 交出去 → **延後**釋放舊的那塊。
    /// 立刻釋放是不行的：可能正好有一個回呼在讀它，而 realtime 端沒有
    /// 任何辦法告訴我們「我讀完了」。詳見 `EQCoefficientBlock`。
    func setEQ(_ settings: EQSettings?) {
        // 內容沒變就不換區塊：generation 一變 render 端就把濾波器狀態歸零
        // （換 preset 不拖尾音的機制），對帳每次都重推同一份 EQ 的話，
        // 每一次歸零都是一聲短暫雜訊（場次 D14 實聽回報，2026-08-30）
        let effective = (settings?.isActive == true) ? settings : nil
        // 係數必須用裝置的實際取樣率算——AirPods 這類裝置會跑在 24k，
        // 用參考 48k 算出來的 EQ 整條頻率都是錯的
        let sampleRate = CoreAudioTapBackend.doubleProperty(
            aggregateID, kAudioDevicePropertyNominalSampleRate
        ) ?? EQSettings.referenceSampleRate
        guard effective != lastPushedEQ || sampleRate != lastPushedSampleRate else { return }
        lastPushedEQ = effective
        lastPushedSampleRate = sampleRate

        let previous = context.eqBlock.load(ordering: .relaxed)
        guard let settings = effective else {
            context.eqBlock.store(0, ordering: .releasing)
            retire(previous)
            return
        }
        eqGeneration &+= 1
        let block = EQCoefficientBlock.allocate(
            coefficients: settings.coefficients(sampleRate: sampleRate),
            preamp: settings.preampGain,
            generation: eqGeneration
        )
        context.eqBlock.store(UInt(bitPattern: block), ordering: .releasing)
        retire(previous)
    }

    private func retire(_ raw: UInt) {
        guard raw != 0, let block = UnsafeMutableRawPointer(bitPattern: raw) else { return }
        Task {
            try? await Task.sleep(for: EQCoefficientBlock.retirementDelay)
            EQCoefficientBlock.deallocate(block)
        }
    }

    func stop() {
        guard let procID else { return }
        if let rateListener {
            var address = CoreAudioTapBackend.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address, .main, rateListener)
            self.rateListener = nil
        }
        // AudioDeviceStop 是同步的：回來之後不會再有回呼在跑，
        // 這時候釋放 EQ 區塊不需要延遲（context 的 deinit 會收尾）
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        self.procID = nil
    }
}
