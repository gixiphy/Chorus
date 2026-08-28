// B6-0 spike — CoreAudio process tap 可行性驗證（結論見
// docs/DESIGN-M12-audio-taps.md §1）。
//
// 建立 private aggregate device 掛上一個全域 tap，跑 IOProc 5 秒，
// 量測回呼節奏並確認真的抓到音訊。**全程 CATapUnmuted：原本的播放完全
// 不受影響。**改動 tap 相關程式碼時可重跑此檔驗證環境仍然可行：
//
//     swiftc -O scripts/spike-audio-tap.swift -o /tmp/tapspike && /tmp/tapspike
//
// 注意輸出的「frames」：buffer 是交錯立體聲，位元組數 ÷ 4 得到的是**樣本數**，
// 除以聲道數才是 frames。實測 1024 樣本 = 512 frames ≈ 10.7 ms。

import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value as String?
}

// 預設輸出裝置的 UID（aggregate 需要一個 clock 來源）
var defaultAddr = address(kAudioHardwarePropertyDefaultOutputDevice)
var outputID = AudioObjectID(kAudioObjectUnknown)
var idSize = UInt32(MemoryLayout<AudioObjectID>.size)
_ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &idSize, &outputID)
let outputUID = stringProperty(outputID, kAudioDevicePropertyDeviceUID) ?? ""
print("預設輸出：\(stringProperty(outputID, kAudioObjectPropertyName) ?? "?") (\(outputUID))")

// 1. 建 tap
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.name = "Chorus B6 capture spike"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(tapDescription, &tapID) == noErr else {
    print("建立 tap 失敗"); exit(1)
}
let tapUID = stringProperty(tapID, kAudioTapPropertyUID) ?? ""
defer { AudioHardwareDestroyProcessTap(tapID) }

// 2. 建 private aggregate device，掛上 tap
let aggregateUID = "com.hermes.Chorus.b6spike.\(UUID().uuidString)"
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Chorus B6 Spike",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapUID,
    ]],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
print("建立 aggregate device → \(aggStatus)")
guard aggStatus == noErr else { exit(1) }
defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

// 3. 跑 IOProc，統計回呼與樣本
final class Stats: @unchecked Sendable {
    let lock = NSLock()
    var callbacks = 0
    var frames = 0
    var peak: Float = 0
    var firstBufferFrames: UInt32 = 0
}
let stats = Stats()

var procID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInputData, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    stats.lock.lock()
    stats.callbacks += 1
    for buffer in list {
        let frames = buffer.mDataByteSize / 4
        stats.frames += Int(frames)
        if stats.firstBufferFrames == 0 { stats.firstBufferFrames = frames }
        if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
            for index in 0..<Int(frames) {
                stats.peak = max(stats.peak, abs(data[index]))
            }
        }
    }
    stats.lock.unlock()
}
print("建立 IOProc → \(status)")
guard status == noErr, let procID else { exit(1) }
defer { AudioDeviceDestroyIOProcID(aggregateID, procID) }

let startStatus = AudioDeviceStart(aggregateID, procID)
print("AudioDeviceStart → \(startStatus)")
guard startStatus == noErr else { exit(1) }

let began = Date()
Thread.sleep(forTimeInterval: 5)
let elapsed = Date().timeIntervalSince(began)
AudioDeviceStop(aggregateID, procID)

stats.lock.lock()
let callbacks = stats.callbacks, frames = stats.frames, peak = stats.peak, bufferFrames = stats.firstBufferFrames
stats.lock.unlock()

print("\n== 5 秒擷取結果 ==")
print("  回呼次數：\(callbacks)（約 \(String(format: "%.0f", Double(callbacks) / elapsed)) 次/秒）")
print("  取得樣本：\(frames) frames")
print("  每次回呼 frames：\(bufferFrames) → 約 \(String(format: "%.1f", Double(bufferFrames) / 48000 * 1000)) ms 一個 buffer")
print("  峰值振幅：\(String(format: "%.4f", peak))")
print("  \(peak > 0.0001 ? "✅ 抓到真實音訊（非靜音）" : "⚠️ 全靜音——可能是沒有播放，或權限被擋")")
