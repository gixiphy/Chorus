// observe-audio-devices — 場次 A（BV 音訊）的 CoreAudio 觀測／驗證小工具。
//
// 唯讀為主，會改狀態的動作都要明確指定子指令。A6／A7 的睡醒測試就是
// 一邊跑 `watch`、一邊 `pmset displaysleepnow`，看端點消失／回來時
// 轉送目標怎麼動（轉送目標本身讀
// /Library/Preferences/Audio/com.apple.audio.SystemSettings.plist 的
// Plug-In.com.hermes.ChorusAudioDevice → outputDeviceUID）。
//
// 建置：swiftc -O scripts/observe-audio-devices.swift -o /tmp/caobserve
//
// 用法：
//   caobserve list                 列出所有輸出裝置＋預設輸出
//   caobserve watch <秒數>          每 0.5 秒取樣，只印出變動
//   caobserve setdefault <UID>     切換預設輸出
//   caobserve vol <UID> [0..1]     讀／寫裝置主音量
//   caobserve rate <UID> <Hz>      切換 nominal sample rate
import CoreAudio
import Foundation

let sysObj = AudioObjectID(kAudioObjectSystemObject)

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ elem: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
}

func dataSize(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
    var a = a, size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return nil }
    return size
}

func get<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = a, value = initial, size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func getString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
    var a = a, cf: CFString? = nil, size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    guard st == noErr, let cf else { return nil }
    return cf as String
}

func fourCC(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "?"
}

func allDevices() -> [AudioObjectID] {
    let a = addr(kAudioHardwarePropertyDevices)
    guard let size = dataSize(sysObj, a), size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    var aa = a, s = size
    guard AudioObjectGetPropertyData(sysObj, &aa, 0, nil, &s, &ids) == noErr else { return [] }
    return ids
}

func outputChannels(_ id: AudioObjectID) -> Int {
    let a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    guard let size = dataSize(id, a), size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    var aa = a, s = size
    guard AudioObjectGetPropertyData(id, &aa, 0, nil, &s, raw) == noErr else { return 0 }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

struct Dev {
    var id: AudioObjectID
    var name: String
    var uid: String
    var transport: String
    var rate: Double
    var channels: Int
    var hasVolume: Bool
    var volumeSettable: Bool
    var volume: Float?
    var hasMute: Bool
    var running: Bool
}

func volumeAddress(_ id: AudioObjectID) -> AudioObjectPropertyAddress? {
    // 先看 master(main) element，再退到 channel 1 —— 兩者都算「有硬體音量」
    for elem in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
        let a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, elem)
        var aa = a
        if AudioObjectHasProperty(id, &aa) { return a }
    }
    return nil
}

func describe(_ id: AudioObjectID) -> Dev? {
    guard let name = getString(id, addr(kAudioObjectPropertyName)) else { return nil }
    let uid = getString(id, addr(kAudioDevicePropertyDeviceUID)) ?? "?"
    let transport = fourCC(get(id, addr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0)
    let rate = get(id, addr(kAudioDevicePropertyNominalSampleRate), Double(0)) ?? 0
    let ch = outputChannels(id)
    var hasVol = false, settable = false, vol: Float? = nil
    if let va = volumeAddress(id) {
        hasVol = true
        var vaa = va
        var s: DarwinBoolean = false
        if AudioObjectIsPropertySettable(id, &vaa, &s) == noErr { settable = s.boolValue }
        vol = get(id, va, Float(0))
    }
    var ma = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
    let hasMute = AudioObjectHasProperty(id, &ma)
    let running = (get(id, addr(kAudioDevicePropertyDeviceIsRunning), UInt32(0)) ?? 0) != 0
    return Dev(id: id, name: name, uid: uid, transport: transport, rate: rate, channels: ch,
               hasVolume: hasVol, volumeSettable: settable, volume: vol, hasMute: hasMute, running: running)
}

func defaultOutput() -> AudioObjectID {
    get(sysObj, addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
}

func outputs() -> [Dev] {
    allDevices().compactMap(describe).filter { $0.channels > 0 }
}

func snapshotText() -> String {
    let def = defaultOutput()
    var lines: [String] = []
    for d in outputs().sorted(by: { $0.name < $1.name }) {
        let mark = d.id == def ? "*" : " "
        let v = d.volume.map { String(format: "%.3f", $0) } ?? "—"
        lines.append("\(mark) \(d.name) [\(d.uid)] \(d.transport) \(Int(d.rate))Hz ch=\(d.channels) "
            + "vol=\(v)\(d.hasVolume ? (d.volumeSettable ? "(可寫)" : "(唯讀)") : "(無)") "
            + "mute=\(d.hasMute ? "有" : "無") running=\(d.running ? "是" : "否")")
    }
    return lines.joined(separator: "\n")
}

func findByUID(_ uid: String) -> Dev? { outputs().first { $0.uid == uid || $0.name == uid } }

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "list"

switch cmd {
case "list":
    print("＝＝ 輸出裝置（* ＝ 目前預設輸出）＝＝")
    print(snapshotText())

case "watch":
    let seconds = Double(args.dropFirst().first ?? "30") ?? 30
    let deadline = Date().addingTimeInterval(seconds)
    var last = ""
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    while Date() < deadline {
        let now = snapshotText()
        if now != last {
            print("── \(fmt.string(from: Date())) ──")
            print(now)
            print("")
            fflush(stdout)
            last = now
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

case "setdefault":
    guard let uid = args.dropFirst().first, let d = findByUID(uid) else {
        FileHandle.standardError.write(Data("找不到裝置\n".utf8)); exit(1)
    }
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = d.id
    let st = AudioObjectSetPropertyData(sysObj, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    print(st == noErr ? "已切換預設輸出 → \(d.name)" : "失敗 status=\(st)")
    exit(st == noErr ? 0 : 1)

case "vol":
    guard let uid = args.dropFirst().first, let d = findByUID(uid) else {
        FileHandle.standardError.write(Data("找不到裝置\n".utf8)); exit(1)
    }
    guard let va = volumeAddress(d.id) else { print("\(d.name)：沒有音量屬性"); exit(1) }
    if let target = args.dropFirst(2).first.flatMap(Float.init) {
        var a = va, v = target
        let st = AudioObjectSetPropertyData(d.id, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
        let readback = get(d.id, va, Float(0)) ?? -1
        print(String(format: "寫入 %.3f status=%d 讀回 %.3f", target, st, readback))
        exit(st == noErr ? 0 : 1)
    } else {
        print(String(format: "%@ 音量 %.3f", d.name, get(d.id, va, Float(0)) ?? -1))
    }

case "rate":
    guard let uid = args.dropFirst().first, let d = findByUID(uid) else {
        FileHandle.standardError.write(Data("找不到裝置\n".utf8)); exit(1)
    }
    guard let target = args.dropFirst(2).first.flatMap(Double.init) else {
        print(String(format: "%@ 目前 %.0f Hz", d.name, d.rate)); exit(0)
    }
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var v = target
    let st = AudioObjectSetPropertyData(d.id, &a, 0, nil, UInt32(MemoryLayout<Double>.size), &v)
    Thread.sleep(forTimeInterval: 0.6)
    let readback = get(d.id, addr(kAudioDevicePropertyNominalSampleRate), Double(0)) ?? -1
    print(String(format: "寫入 %.0f Hz status=%d 讀回 %.0f Hz", target, st, readback))
    exit(st == noErr && abs(readback - target) < 1 ? 0 : 1)

default:
    print("用法：caobserve list|watch <秒>|setdefault <UID>|vol <UID> [0..1]|rate <UID> <Hz>")
    exit(2)
}
