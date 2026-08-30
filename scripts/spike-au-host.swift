// spike-au-host — AU 掛載（B6-8）的假設驗證。
//
// 驗三件事（DESIGN-20260830-au-hosting §2 AU-0）：
// 1. 掃描：AVAudioUnitComponentManager 列出 v2 effect（不實例化，永遠安全）
// 2. 同步實例化：AudioComponentInstanceNew + AudioUnitInitialize 不需要 async
// 3. ClassInfo（aupreset 內容）get/set 往返
// 外加：SetRenderCallback + AudioUnitRender 的 pull 在離線跑一個 buffer。
//
// 建置：swiftc -O scripts/spike-au-host.swift -o /tmp/auspike && /tmp/auspike
import AudioToolbox
import AVFoundation
import Foundation

// 1. 掃描
let manager = AVAudioUnitComponentManager.shared()
var description = AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: 0,
    componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0
)
let effects = manager.components(matching: description)
print("effect AU 共 \(effects.count) 個：")
for component in effects.prefix(12) {
    let arch = component.hasCustomView ? "custom+generic" : "generic"
    print("  \(component.manufacturerName) — \(component.name) v\(component.versionString) [\(arch)]")
}

// 2. 同步實例化：Apple 的 AUDelay（一定在、一定安全）
var delayDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: kAudioUnitSubType_Delay,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0
)
guard let component = AudioComponentFindNext(nil, &delayDescription) else {
    print("找不到 AUDelay"); exit(1)
}
var maybeUnit: AudioUnit?
var status = AudioComponentInstanceNew(component, &maybeUnit)
guard status == noErr, let unit = maybeUnit else {
    print("實例化失敗：\(status)"); exit(1)
}
print("同步實例化 AUDelay：noErr")

// 格式：deinterleaved Float32 stereo 48k（DESIGN §1.5）
var format = AudioStreamBasicDescription(
    mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
)
for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
    status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0,
                                  &format, UInt32(MemoryLayout.size(ofValue: format)))
    guard status == noErr else { print("設格式失敗（scope \(scope)）：\(status)"); exit(1) }
}
var maxFrames: UInt32 = 4096
AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                     kAudioUnitScope_Global, 0, &maxFrames, 4)

// input callback：餵 1kHz 正弦
final class Feed { var phase: Double = 0 }
let feed = Feed()
var callback = AURenderCallbackStruct(
    inputProc: { context, _, _, _, frameCount, bufferList -> OSStatus in
        let feed = Unmanaged<Feed>.fromOpaque(context).takeUnretainedValue()
        guard let bufferList else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(feed.phase) * 0.5)
            feed.phase += 2 * .pi * 1000 / 48000
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
        return noErr
    },
    inputProcRefCon: Unmanaged.passUnretained(feed).toOpaque()
)
status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                              kAudioUnitScope_Input, 0, &callback,
                              UInt32(MemoryLayout.size(ofValue: callback)))
guard status == noErr else { print("SetRenderCallback 失敗：\(status)"); exit(1) }

status = AudioUnitInitialize(unit)
guard status == noErr else { print("Initialize 失敗：\(status)"); exit(1) }
print("同步 Initialize：noErr")

// 3. ClassInfo 往返
var classInfo: CFPropertyList?
var size = UInt32(MemoryLayout<CFPropertyList?>.size)
status = AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo,
                              kAudioUnitScope_Global, 0, &classInfo, &size)
guard status == noErr, let info = classInfo else { print("ClassInfo 讀取失敗：\(status)"); exit(1) }
let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
print("ClassInfo 讀取：\(data.count) bytes（aupreset 內容）")
let restored = try! PropertyListSerialization.propertyList(from: data, options: [], format: nil)
var restoredCF = restored as CFPropertyList?
status = AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo,
                              kAudioUnitScope_Global, 0, &restoredCF,
                              UInt32(MemoryLayout<CFPropertyList?>.size))
print("ClassInfo 寫回：\(status == noErr ? "noErr" : "失敗 \(status)")")

// 4. pull 一個 buffer
var timeStamp = AudioTimeStamp()
timeStamp.mFlags = .sampleTimeValid
let frameCount: UInt32 = 512
let bufferBytes = Int(frameCount) * 4
var channelData = [UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: 16),
                   UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: 16)]
var list = AudioBufferList.allocate(maximumBuffers: 2)
for (index, pointer) in channelData.enumerated() {
    list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bufferBytes), mData: pointer)
}
var flags = AudioUnitRenderActionFlags()
status = AudioUnitRender(unit, &flags, &timeStamp, 0, frameCount, list.unsafeMutablePointer)
if status == noErr {
    let out = channelData[0].assumingMemoryBound(to: Float.self)
    var peak: Float = 0
    for i in 0..<Int(frameCount) { peak = max(peak, abs(out[i])) }
    print(String(format: "AudioUnitRender pull：noErr，輸出 peak %.3f", peak))
} else {
    print("AudioUnitRender 失敗：\(status)")
}
AudioUnitUninitialize(unit)
AudioComponentInstanceDispose(unit)
print("收尾完成")
