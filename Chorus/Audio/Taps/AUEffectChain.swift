import AudioToolbox
import ChorusCore
import Foundation
import Synchronization

/// 一層 AU 效果鏈的共享狀態（App 層／裝置層各一份，B6-8 AU-2b）。
/// 與 `EQLayerState` 同構：主執行緒建好整條鏈後一次 atomic store 交出
/// 指標，render 端只做「讀指標 → C 呼叫」；換鏈時舊的延後退休。
final class AUChainLayer: @unchecked Sendable {
    /// `AUChainBlock` 的指標位元（0＝沒有鏈）。主執行緒寫、render 讀。
    let chain = Atomic<UInt>(0)

    deinit {
        let raw = chain.load(ordering: .relaxed)
        if raw != 0, let pointer = UnsafeMutableRawPointer(bitPattern: raw) {
            // deinit 時 session 已 stop（IOProc 已拆），同步處置是安全的
            AUChainBlock.dispose(pointer)
        }
    }
}

/// 交給 realtime 執行緒的一條 AU 鏈。
///
/// 與 `EQCoefficientBlock` 同一套生命週期紀律：主執行緒配置、寫完不再
/// 更動結構（feed 槽與時戳例外——它們是 render 執行緒獨佔的工作格）、
/// atomic 交出、換鏈延後退休（可能正有一個回呼在用舊鏈）。
///
/// 佈局（全 POD，render 端零配置）：
///
///     Header | units: [AudioUnit] × count | ABL 工作區（2 buffer）
///
/// scratch 樣本緩衝**不在**這裡——它與鏈的內容無關、換鏈不該重配，
/// 放在 `TapRenderContext`（見 `auScratch`）。
enum AUChainBlock {
    struct Header {
        var count: UInt32
        /// AU 的 maxFramesPerSlice——render 收到更大的 buffer 就整段旁通
        ///（防呆；實務上 tap 回呼固定 512 frames）。
        var maxFrames: UInt32
        /// 遞增的 render 時戳。**render 執行緒獨佔**。
        var sampleTime: Float64
        /// 本次 AudioUnitRender 的輸入（feed callback 讀）。**render 獨佔**。
        var feedL: UnsafeMutablePointer<Float>?
        var feedR: UnsafeMutablePointer<Float>?
        var feedFrames: UInt32
    }

    static let unitsOffset = MemoryLayout<Header>.stride
    static let retirementDelay = Duration.seconds(1)
    static let maxFrames: UInt32 = 4096

    private static func ablOffset(count: Int) -> Int {
        unitsOffset + count * MemoryLayout<AudioUnit>.stride
    }

    private static func totalBytes(count: Int) -> Int {
        // ABL 工作區：mNumberBuffers ＋ 2 × AudioBuffer（deinterleaved 立體聲）
        ablOffset(count: count) + MemoryLayout<UInt32>.stride + 2 * MemoryLayout<AudioBuffer>.stride
            + MemoryLayout<AudioBufferList>.alignment
    }

    /// 主執行緒：把已實例化的 AU 打包成 render 可用的鏈。
    static func allocate(units: [AudioUnit]) -> UnsafeMutableRawPointer {
        let block = UnsafeMutableRawPointer.allocate(
            byteCount: totalBytes(count: units.count),
            alignment: max(MemoryLayout<Header>.alignment, MemoryLayout<AudioUnit>.alignment)
        )
        block.bindMemory(to: Header.self, capacity: 1).initialize(to: Header(
            count: UInt32(units.count), maxFrames: maxFrames,
            sampleTime: 0, feedL: nil, feedR: nil, feedFrames: 0
        ))
        let slots = (block + unitsOffset).bindMemory(to: AudioUnit.self, capacity: max(units.count, 1))
        for (index, unit) in units.enumerated() {
            slots[index] = unit
        }
        return block
    }

    /// 鏈上的 AU 實例（拆解／render 用）。
    static func units(_ block: UnsafeMutableRawPointer) -> UnsafeMutableBufferPointer<AudioUnit> {
        let header = block.assumingMemoryBound(to: Header.self).pointee
        return UnsafeMutableBufferPointer(
            start: (block + unitsOffset).assumingMemoryBound(to: AudioUnit.self),
            count: Int(header.count)
        )
    }

    /// 同步處置：Uninitialize ＋ Dispose 每個實例，釋放區塊。
    /// 只能在確定 render 不會再碰它之後呼叫（延後退休或 session 已 stop）。
    static func dispose(_ block: UnsafeMutableRawPointer) {
        for unit in units(block) {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        block.deallocate()
    }

    /// 換鏈時的延後退休（與 EQCoefficientBlock.retirementDelay 同理：
    /// 回呼約 10 ms 一次，一秒是三個數量級的餘裕）。
    @MainActor
    static func retire(_ block: UnsafeMutableRawPointer) {
        let bits = UInt(bitPattern: block)
        Task { @MainActor in
            try? await Task.sleep(for: retirementDelay)
            if let pointer = UnsafeMutableRawPointer(bitPattern: bits) {
                dispose(pointer)
            }
        }
    }

    // MARK: - render 端（nonisolated、零配置）

    /// feed callback：把 header 裡的 feed 槽餵給 AU。所有 AU 共用這一個
    /// （refCon＝區塊基址）；render 執行緒在每次 AudioUnitRender 前先
    /// 寫好 feed 槽，所以它永遠讀到本級的正確輸入。
    nonisolated static let feedCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        guard let ioData else { return noErr }
        let header = refCon.assumingMemoryBound(to: Header.self).pointee
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = Int(min(frameCount, header.feedFrames))
        for (index, buffer) in buffers.enumerated() {
            let source: UnsafeMutablePointer<Float>? = index == 0 ? header.feedL : header.feedR
            guard let source else { continue }
            if let destination = buffer.mData {
                destination.assumingMemoryBound(to: Float.self).update(from: source, count: frames)
            } else {
                // 有些 AU 給 NULL mData 要宿主提供緩衝——直接把 feed 借給它
                //（AU 只在本次 render 內讀它，而 feed 在下一級前不會變）
                var mutable = buffer
                mutable.mData = UnsafeMutableRawPointer(source)
                buffers[index] = mutable
            }
        }
        return noErr
    }

    /// render 執行緒：把 in（L/R deinterleaved）走完整條鏈、寫進 out。
    /// 任何一級失敗就把那一級當旁通（輸入原樣交給下一級）。
    /// 回傳 false ＝ 整條鏈旁通（frames 超過 maxFrames 的防呆）。
    @discardableResult
    nonisolated static func render(
        _ block: UnsafeMutableRawPointer,
        inL: UnsafeMutablePointer<Float>, inR: UnsafeMutablePointer<Float>,
        outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
        frames: Int
    ) -> Bool {
        let header = block.assumingMemoryBound(to: Header.self)
        guard frames <= Int(header.pointee.maxFrames) else { return false }

        // ABL 工作區（配置在區塊裡，render 只填指標——零配置）
        let ablBase = (block + ablOffset(count: Int(header.pointee.count)))
            .alignedUp(toMultipleOf: MemoryLayout<AudioBufferList>.alignment)
        let abl = ablBase.assumingMemoryBound(to: AudioBufferList.self)

        var currentInL = inL
        var currentInR = inR
        var currentOutL = outL
        var currentOutR = outR
        var timeStamp = AudioTimeStamp()
        timeStamp.mFlags = .sampleTimeValid
        timeStamp.mSampleTime = header.pointee.sampleTime

        for unit in units(block) {
            header.pointee.feedL = currentInL
            header.pointee.feedR = currentInR
            header.pointee.feedFrames = UInt32(frames)

            abl.pointee.mNumberBuffers = 2
            let bufferBytes = UInt32(frames * MemoryLayout<Float>.stride)
            let bufferSlots = UnsafeMutableAudioBufferListPointer(abl)
            bufferSlots[0] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: bufferBytes, mData: UnsafeMutableRawPointer(currentOutL)
            )
            bufferSlots[1] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: bufferBytes, mData: UnsafeMutableRawPointer(currentOutR)
            )

            var flags = AudioUnitRenderActionFlags()
            let status = AudioUnitRender(unit, &flags, &timeStamp, 0, UInt32(frames), abl)
            if status == noErr {
                // 下一級的輸入＝這一級的輸出（ping-pong）
                swap(&currentInL, &currentOutL)
                swap(&currentInR, &currentOutR)
            }
            // 失敗＝這一級旁通：currentIn 不動，直接餵下一級
        }
        header.pointee.sampleTime += Float64(frames)

        // 走完之後結果在 currentIn（最後一次成功 render 後被 swap 進來）。
        // 不在呼叫端期望的 out 就補一次搬運。
        if currentInL != outL {
            outL.update(from: currentInL, count: frames)
            outR.update(from: currentInR, count: frames)
        }
        return true
    }
}

/// 主執行緒的鏈建造者：實例化、掛 feed、還原 ClassInfo、配隔離閂。
@MainActor
enum AUChainBuilder {
    struct BuildResult {
        var block: UnsafeMutableRawPointer?
        /// 建不起來的格（外掛不在、實例化失敗）——UI 誠實說明用。
        var failures: [String] = []
        /// 成功建進鏈的條目 id，**與鏈上實例同序**——部分失敗時
        /// entries 與 units 的索引會錯位，用 id 對應才不會編輯到別格。
        var builtIDs: [UUID] = []
    }

    /// 活實例目前的參數（標準 aupreset 內容）。generic 面板編輯後
    /// 存檔走這裡讀回。
    static func classInfoData(of unit: AudioUnit) -> Data? {
        var classInfo: CFPropertyList?
        var size = UInt32(MemoryLayout<CFPropertyList?>.size)
        guard AudioUnitGetProperty(
            unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &classInfo, &size
        ) == noErr, let info = classInfo else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
    }

    /// 把存檔的參數就地套進活實例（換 preset／跨 session 同步用）。
    static func applyClassInfo(_ data: Data, to unit: AudioUnit) {
        guard let restored = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) else { return }
        var classInfo = restored as CFPropertyList?
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0,
            &classInfo, UInt32(MemoryLayout<CFPropertyList?>.size)
        )
    }

    /// `latch`：實例化**前**以元件 key 呼叫、成功後以 nil 呼叫（隔離閂，
    /// DESIGN §1.1）。App 在載入期間崩潰的話，下次啟動由 SettingsStore
    /// 的收養流程把殘留 key 併進隔離名單。
    static func build(
        entries: [AUEffectEntry],
        sampleRate: Double,
        latch: (String?) -> Void
    ) -> BuildResult {
        var result = BuildResult()
        let active = entries.filter(\.enabled)
        guard !active.isEmpty else { return result }

        var units: [AudioUnit] = []
        // 先配置區塊（feed callback 的 refCon 要指向它），實例掛好再回填。
        // count 先用上限，實際數寫在 header——區塊多幾個空槽無妨。
        // 先以佔位指標配置區塊（feed callback 的 refCon 要指向它），
        // 實例掛好後回填實際內容與數量；發布前沒有任何人讀這些槽。
        let block = AUChainBlock.allocate(
            units: Array(repeating: AudioUnit(bitPattern: 1)!, count: active.count)
        )

        for entry in active {
            var description = AudioComponentDescription(
                componentType: entry.component.type,
                componentSubType: entry.component.subtype,
                componentManufacturer: entry.component.manufacturer,
                componentFlags: 0, componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &description) else {
                result.failures.append("找不到「\(entry.name)」——外掛可能已移除")
                continue
            }

            latch(entry.component.key)
            var maybeUnit: AudioUnit?
            var status = AudioComponentInstanceNew(component, &maybeUnit)
            guard status == noErr, let unit = maybeUnit else {
                latch(nil)
                result.failures.append("「\(entry.name)」實例化失敗（\(status)）")
                continue
            }

            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
            )
            let formatSize = UInt32(MemoryLayout.size(ofValue: format))
            status = AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize
            )
            if status == noErr {
                status = AudioUnitSetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize
                )
            }
            var maxFrames = AUChainBlock.maxFrames
            if status == noErr {
                status = AudioUnitSetProperty(
                    unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4
                )
            }
            var callback = AURenderCallbackStruct(
                inputProc: AUChainBlock.feedCallback,
                inputProcRefCon: block
            )
            if status == noErr {
                status = AudioUnitSetProperty(
                    unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                    &callback, UInt32(MemoryLayout.size(ofValue: callback))
                )
            }
            if status == noErr {
                status = AudioUnitInitialize(unit)
            }
            guard status == noErr else {
                latch(nil)
                AudioComponentInstanceDispose(unit)
                result.failures.append("「\(entry.name)」初始化失敗（\(status)）")
                continue
            }

            // 參數存檔（標準 aupreset 內容）。還原失敗不是致命——外掛
            // 回到預設狀態，比整格消失誠實
            if let data = entry.classInfo,
               let restored = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                var classInfo = restored as CFPropertyList?
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0,
                    &classInfo, UInt32(MemoryLayout<CFPropertyList?>.size)
                )
            }
            latch(nil)
            units.append(unit)
            result.builtIDs.append(entry.id)
        }

        guard !units.isEmpty else {
            block.deallocate() // 只有空槽，沒有任何實例——不用走 dispose
            return result
        }
        // 回填實際實例數與內容
        block.assumingMemoryBound(to: AUChainBlock.Header.self).pointee.count = UInt32(units.count)
        let slots = (block + AUChainBlock.unitsOffset)
            .assumingMemoryBound(to: AudioUnit.self)
        for (index, unit) in units.enumerated() {
            slots[index] = unit
        }
        result.block = block
        return result
    }
}

extension UnsafeMutableRawPointer {
    func alignedUp(toMultipleOf alignment: Int) -> UnsafeMutableRawPointer {
        let address = UInt(bitPattern: self)
        let aligned = (address + UInt(alignment) - 1) & ~(UInt(alignment) - 1)
        return UnsafeMutableRawPointer(bitPattern: aligned)!
    }
}
