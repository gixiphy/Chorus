// B6-3 spike — 「內建 drift compensation 的品質夠不夠」。
//
// 這是 PLAN §2-B6-3 唯一還沒有答案的問題。DESIGN §1.1② 已經證實
// `kAudioSubTapDriftCompensationKey` 存在、能設定，所以要驗的**不是
// 「能不能補償」而是「補得夠不夠好」**——兩個獨立時鐘的實體裝置同時
// 出聲，長時間下來會不會爆音、掉樣本、或慢慢走開。
//
// 這個問題**沒有辦法用 fake 驗**：drift 是兩顆石英振盪器的差，
// 只有真的插兩個實體裝置、跑夠久才量得到。因此 B6-3 只出「路由」，
// 多裝置同時輸出等這支腳本的結論。
//
//     swiftc -O scripts/spike-multi-device-drift.swift -o /tmp/driftspike
//     /tmp/driftspike                      # 列出可用裝置
//     /tmp/driftspike <UID-A> <UID-B> 30   # 跑 30 分鐘
//
// 判讀（跑完會印在結尾）：
//   - **glitch 次數**：IOProc 間隔超出正常值一倍以上的次數。0 才算過。
//   - **補償量漂移**：兩裝置實際消化的 frame 數差。內建補償有作用時，
//     這個差會在一個小範圍內來回，而不是單調累積。
//   - **人耳**：整段期間要有音樂在放，聽有沒有週期性的喀噠或相位飄移。
//
// 三項全過 → 多裝置同時輸出可以做；任一項不過 → 維持只出路由，
// 把結論與數字寫進 DESIGN-M12 §7 的 B6-3 列。

import CoreAudio
import Foundation

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value as String?
}

func hasOutputStreams(_ device: AudioObjectID) -> Bool {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, buffer) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
    return list.contains { $0.mNumberChannels > 0 }
}

func outputDevices() -> [(uid: String, name: String)] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
    ) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects
    ) == noErr else { return [] }
    return objects.compactMap { device in
        guard hasOutputStreams(device),
              let uid = stringProperty(device, kAudioDevicePropertyDeviceUID)
        else { return nil }
        return (uid, stringProperty(device, kAudioObjectPropertyName) ?? "?")
    }
}

let devices = outputDevices()
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("可用的輸出裝置：")
    for device in devices { print("  \(device.name)\n    \(device.uid)") }
    print("\n用法：driftspike <UID-A> <UID-B> [分鐘，預設 30]")
    exit(devices.isEmpty ? 1 : 0)
}
let uidA = arguments[0]
let uidB = arguments[1]
let minutes = arguments.count > 2 ? (Double(arguments[2]) ?? 30) : 30
guard devices.contains(where: { $0.uid == uidA }), devices.contains(where: { $0.uid == uidB }) else {
    print("找不到指定的裝置 UID。不帶引數執行可列出清單。")
    exit(1)
}
guard uidA != uidB else {
    print("兩個 UID 相同——drift 要兩個獨立時鐘才量得到。")
    exit(1)
}

// 全域 tap（unmuted，原本的播放完全不受影響）＋兩個 sub-device 的 aggregate。
// 兩個 sub-device 各自開 drift compensation，這正是要驗的東西。
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.name = "Chorus B6-3 drift spike"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(tapDescription, &tapID) == noErr else {
    print("建立 tap 失敗"); exit(1)
}
let tapUID = stringProperty(tapID, kAudioTapPropertyUID) ?? ""

let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Chorus Drift Spike",
    kAudioAggregateDeviceUIDKey: "com.hermes.Chorus.driftspike.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: uidA,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: true, // 多裝置同時輸出＝stacked
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: uidA, kAudioSubDeviceDriftCompensationKey: 1],
        [kAudioSubDeviceUIDKey: uidB, kAudioSubDeviceDriftCompensationKey: 1],
    ],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapUID,
    ]],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
let aggregateStatus = AudioHardwareCreateAggregateDevice(
    aggregateDescription as CFDictionary, &aggregateID
)
guard aggregateStatus == noErr else {
    print("建立 aggregate 失敗：\(aggregateStatus)")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

// 回呼統計。realtime 端只做加法，判讀留到最後
final class Stats: @unchecked Sendable {
    var callbacks = 0
    var frames = 0
    var glitches = 0
    var maxIntervalMicros: Double = 0
    var lastHostTime: UInt64 = 0
    var nominalMicros: Double = 0
}
let stats = Stats()

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let hostToMicros = Double(timebase.numer) / Double(timebase.denom) / 1000

var procID: AudioDeviceIOProcID?
let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { now, input, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    var frames = 0
    if let first = list.first {
        frames = Int(first.mDataByteSize) / 4 / Int(max(1, first.mNumberChannels))
    }
    stats.callbacks += 1
    stats.frames += frames
    let hostTime = now.pointee.mHostTime
    if stats.lastHostTime != 0 {
        let interval = Double(hostTime - stats.lastHostTime) * hostToMicros
        if stats.nominalMicros == 0 { stats.nominalMicros = interval }
        // 間隔超過正常值一倍＝丟了一個 buffer，人耳聽得到
        if interval > stats.nominalMicros * 2 { stats.glitches += 1 }
        stats.maxIntervalMicros = max(stats.maxIntervalMicros, interval)
    }
    stats.lastHostTime = hostTime
}
guard procStatus == noErr, let procID else {
    print("建立 IOProc 失敗：\(procStatus)")
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

let startStatus = AudioDeviceStart(aggregateID, procID)
guard startStatus == noErr else {
    print("啟動失敗：\(startStatus)（缺少系統音訊錄製權限時這裡仍會回 0——見 DESIGN §1.2）")
    AudioDeviceDestroyIOProcID(aggregateID, procID)
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

print("跑 \(Int(minutes)) 分鐘。**請保持音樂播放**，並在整段期間留意有沒有喀噠聲。")
print("裝置 A：\(uidA)\n裝置 B：\(uidB)\n")

let deadline = Date().addingTimeInterval(minutes * 60)
var lastReport = Date()
var lastFrames = 0
while Date() < deadline {
    Thread.sleep(forTimeInterval: 1)
    if Date().timeIntervalSince(lastReport) >= 60 {
        let delta = stats.frames - lastFrames
        // 48 kHz 下一分鐘應該是 2,880,000 frames。偏離量就是補償後的殘餘誤差
        let expected = 48_000 * 60
        let ppm = (Double(delta) - Double(expected)) / Double(expected) * 1_000_000
        print(String(
            format: "  +%.0f 分鐘：frames %d（誤差 %.1f ppm）、glitch %d、最大間隔 %.1f ms",
            Date().timeIntervalSince(deadline.addingTimeInterval(-minutes * 60)) / 60,
            delta, ppm, stats.glitches, stats.maxIntervalMicros / 1000
        ))
        lastFrames = stats.frames
        lastReport = Date()
    }
}

AudioDeviceStop(aggregateID, procID)
AudioDeviceDestroyIOProcID(aggregateID, procID)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)

print("""

=== 結論素材 ===
  回呼次數      \(stats.callbacks)
  總 frames     \(stats.frames)
  glitch 次數   \(stats.glitches)      ← 0 才算過
  正常間隔      \(String(format: "%.2f", stats.nominalMicros / 1000)) ms
  最大間隔      \(String(format: "%.2f", stats.maxIntervalMicros / 1000)) ms  ← 超過正常值兩倍就是掉過 buffer

判讀寫回 docs/DESIGN-M12-audio-taps.md §7 的 B6-3 列。
glitch > 0 或人耳聽到週期性喀噠 → 維持「只出路由、不出多裝置」。
""")
