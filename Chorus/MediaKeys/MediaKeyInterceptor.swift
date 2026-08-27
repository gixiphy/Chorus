import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// 媒體鍵接管（BK）：CGEvent tap 攔截亮度／音量鍵，**只在 macOS 原生處理
/// 走不通的情境接手**，其餘一律放行原生行為：
/// - 音量鍵：預設輸出是螢幕喇叭（無 CoreAudio 音量）且已橋接 DDC 時接手
///   （否則 macOS 只會顯示打叉喇叭）。
/// - 亮度鍵：本機沒有任何 DisplayServices 顯示器（如 Mac mini 全外接）時
///   接手調整所有顯示器（否則 macOS 原生會處理內建螢幕，poller 接手學習）。
///
/// 需輔助使用權限。降級紀律：未授權、tap 被系統停用（逾時）時絕不吃掉按鍵；
/// 收到 tapDisabled 事件立即重新啟用。
@MainActor
@Observable
final class MediaKeyInterceptor {
    /// tap 已建立並掛上 run loop。
    private(set) var tapActive = false
    /// 最近一次啟動嘗試時的輔助使用權限狀態（設定頁顯示用）。
    private(set) var lastTrusted = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private weak var audioManager: AudioDeviceManager?
    @ObservationIgnored private let osd = KeyOSDController()
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// NX_SYSDEFINED（IOKit ev_keymap 的特殊鍵事件型別）。
    private static let systemDefinedEventType: UInt32 = 14
    /// 一格 = 1/16，與 macOS 原生 OSD 同刻度。
    nonisolated static let step = 1.0 / 16.0

    // NX_KEYTYPE_*（IOKit/hidsystem/ev_keymap.h）
    nonisolated static let keySoundUp: Int32 = 0
    nonisolated static let keySoundDown: Int32 = 1
    nonisolated static let keyBrightnessUp: Int32 = 2
    nonisolated static let keyBrightnessDown: Int32 = 3
    nonisolated static let keyMute: Int32 = 7

    init(settings: SettingsStore, displayManager: DisplayManager, audioManager: AudioDeviceManager) {
        self.settings = settings
        self.displayManager = displayManager
        self.audioManager = audioManager
    }

    // MARK: - 生命週期

    /// 設定開關變更或啟動時呼叫。`promptIfNeeded`：使用者剛打開開關時
    /// 才彈系統授權提示，App 啟動時靜默嘗試。
    func updateActivation(promptIfNeeded: Bool = false) {
        guard settings.mediaKeyCaptureEnabled else {
            stopTap()
            retryTask?.cancel()
            retryTask = nil
            return
        }
        if promptIfNeeded, !AXIsProcessTrusted() {
            // kAXTrustedCheckOptionPrompt 全域在 Swift 6 視為非併發安全；用字面值
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        startTapIfPossible()
        startRetryLoopIfNeeded()
    }

    private func startTapIfPossible() {
        guard tap == nil else { return }
        lastTrusted = AXIsProcessTrusted()
        guard lastTrusted else { return }

        let mask = CGEventMask(1 << Self.systemDefinedEventType)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: selfPointer
        ) else { return }

        tap = created
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tapActive = true
    }

    private func stopTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        tapActive = false
    }

    /// 開關開著但權限還沒給：每 3 秒重試，授權完成即自動生效。
    private func startRetryLoopIfNeeded() {
        guard tap == nil, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                guard self.settings.mediaKeyCaptureEnabled else { break }
                self.startTapIfPossible()
                if self.tapActive { break }
            }
            self?.retryTask = nil
        }
    }

    // MARK: - 事件處理（tap 掛在 main run loop，callback 於主執行緒進入）

    /// 回傳 true = 事件已由 Chorus 處理（吞掉）；false = 放行給 macOS。
    func processTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 系統停用 tap（callback 逾時／使用者輸入保護）：立即重啟，事件放行
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == Self.systemDefinedEventType,
              settings.mediaKeyCaptureEnabled,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8,
              let key = Self.parse(data1: nsEvent.data1)
        else { return false }
        return route(key)
    }

    /// 判斷是否接手；接手時 keyDown（含重複）執行動作、keyUp 只吞不動作
    /// （up/down 必須成對吞，否則 macOS 收到孤兒事件）。
    private func route(_ key: ParsedKey) -> Bool {
        switch key.keyCode {
        case Self.keySoundUp, Self.keySoundDown, Self.keyMute:
            guard let audioManager, let device = audioManager.defaultDevice,
                  Self.shouldInterceptVolume(
                      canSetVolume: device.canSetVolume,
                      bridged: device.bridgedDisplayID != nil
                  )
            else { return false }
            if key.isDown { handleVolume(key.keyCode, device: device, manager: audioManager) }
            return true

        case Self.keyBrightnessUp, Self.keyBrightnessDown:
            guard let displayManager,
                  Self.shouldInterceptBrightness(backends: displayManager.displays.map(\.backend))
            else { return false }
            if key.isDown { handleBrightness(up: key.keyCode == Self.keyBrightnessUp, manager: displayManager) }
            return true

        default:
            return false
        }
    }

    private func handleVolume(_ keyCode: Int32, device: AudioDeviceModel, manager: AudioDeviceManager) {
        if keyCode == Self.keyMute {
            manager.setMuted(!device.muted, for: device)
            osd.show(
                icon: device.muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                level: device.muted ? 0 : device.volume,
                title: device.name
            )
            return
        }
        if device.muted { manager.setMuted(false, for: device) }
        let value = Self.stepped(device.volume, up: keyCode == Self.keySoundUp)
        manager.setVolume(value, for: device)
        osd.show(icon: "speaker.wave.3.fill", level: value, title: device.name)
    }

    private func handleBrightness(up: Bool, manager: DisplayManager) {
        let displays = manager.displays
        guard !displays.isEmpty else { return }
        for model in displays {
            manager.setBrightness(Self.stepped(model.brightness, up: up), for: model)
        }
        let title = displays.count == 1 ? displays[0].name : "所有顯示器（\(displays.count)）"
        osd.show(icon: "sun.max.fill", level: displays[0].brightness, title: title)
    }

    #if DEBUG
    /// TestHooks：直接走路由（keyDown），驗證接管條件與套用路徑。
    /// 回傳是否接手。
    func debugSimulate(keyCode: Int32) -> Bool {
        route(ParsedKey(keyCode: keyCode, isDown: true, isRepeat: false))
    }
    #endif

    // MARK: - 純邏輯（可測）

    struct ParsedKey: Equatable {
        let keyCode: Int32
        let isDown: Bool
        let isRepeat: Bool
    }

    /// NX_SYSDEFINED subtype 8 的 data1 佈局：
    /// bits 16–31 = keyCode；bits 8–15 = 0x0A(down)/0x0B(up)；bit 0 = repeat。
    nonisolated static func parse(data1: Int) -> ParsedKey? {
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let state = (keyFlags & 0xFF00) >> 8
        guard state == 0x0A || state == 0x0B else { return nil }
        return ParsedKey(keyCode: keyCode, isDown: state == 0x0A, isRepeat: (keyFlags & 0x1) == 1)
    }

    /// 音量鍵只在「無 CoreAudio 音量但已橋接 DDC」時接手。
    nonisolated static func shouldInterceptVolume(canSetVolume: Bool, bridged: Bool) -> Bool {
        !canSetVolume && bridged
    }

    /// 亮度鍵只在「沒有任何 DisplayServices 顯示器」時接手
    /// （有內建螢幕時 macOS 原生處理，poller 負責學習與同步）。
    nonisolated static func shouldInterceptBrightness(backends: [BrightnessBackend]) -> Bool {
        !backends.isEmpty && !backends.contains(.displayServices)
    }

    nonisolated static func stepped(_ current: Double, up: Bool) -> Double {
        let next = current + (up ? step : -step)
        return min(max(next, 0), 1)
    }
}

/// C convention callback：tap 掛在 main run loop，於主執行緒進入。
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    // CGEvent 非 Sendable，但 tap source 掛在 main run loop、callback 必在主執行緒，
    // 事件不會跨執行緒——以 unsafe 標注通過 region 檢查。
    nonisolated(unsafe) let unsafeEvent = event
    let swallowed = MainActor.assumeIsolated {
        interceptor.processTapEvent(type: type, event: unsafeEvent)
    }
    return swallowed ? nil : Unmanaged.passUnretained(event)
}
