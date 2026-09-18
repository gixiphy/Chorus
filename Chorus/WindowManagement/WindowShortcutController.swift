import AppKit
import Carbon.HIToolbox
import ChorusCore

/// 視窗指令的全域快捷鍵，走 Carbon `RegisterEventHotKey`。
///
/// 不用 `NSEvent` 全域監聽的原因：
/// - 監聽看得到按鍵但攔不下來，`⌃⌥D` 這類字母組合會同時送進前景 App。
/// - 方向鍵事件自帶 `.numericPad`／`.function` 旗標，拿 `modifierFlags` 做相等比對會永遠不中
///   ——M1 的四個半屏快捷鍵就是這樣失效的。
/// - 註冊失敗拿得到 `OSStatus`，設定頁才能逐項標示「不可用」。
@MainActor
final class WindowShortcutController {
    private static let signature: OSType = 0x4348_574D // 'CHWM'

    private var hotKeys: [WindowCommand: EventHotKeyRef] = [:]
    private var commandsByID: [UInt32: WindowCommand] = [:]
    private var handler: EventHandlerRef?
    private let onCommand: (WindowCommand) -> Void

    init(onCommand: @escaping (WindowCommand) -> Void) {
        self.onCommand = onCommand
    }

    var isActive: Bool { handler != nil }

    /// 以 `bindings` 取代目前註冊的整組快捷鍵。回傳註冊失敗的指令。
    @discardableResult
    func register(_ bindings: ShortcutBindings) -> Set<WindowCommand> {
        unregisterHotKeys()
        installHandlerIfNeeded()

        var failed: Set<WindowCommand> = []
        for command in WindowCommand.allCases {
            guard let chord = bindings[command] else { continue }
            let id = UInt32(command.order + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(chord.keyCode),
                Self.carbonModifiers(chord.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeys[command] = ref
                commandsByID[id] = command
            } else {
                failed.insert(command)
                ChorusLog.window.notice(
                    "快捷鍵註冊失敗：\(command.rawValue) \(chord.displayString) status=\(status)"
                )
            }
        }
        return failed
    }

    func stop() {
        unregisterHotKeys()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func unregisterHotKeys() {
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
        commandsByID.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let id = hotKeyID.id
                // Carbon 事件在主執行緒的 run loop 派送
                MainActor.assumeIsolated {
                    Unmanaged<WindowShortcutController>.fromOpaque(userData)
                        .takeUnretainedValue()
                        .fire(id: id)
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        if status != noErr {
            ChorusLog.window.notice("快捷鍵事件處理器安裝失敗 status=\(status)")
        }
    }

    private func fire(id: UInt32) {
        guard let command = commandsByID[id] else { return }
        onCommand(command)
    }

    private static func carbonModifiers(_ modifiers: KeyChord.Modifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        return UInt32(result)
    }
}

extension KeyChord {
    /// 從錄製到的 keyDown 建立；鍵帽字元留作非 ANSI 鍵盤的顯示後備。
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let label = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.init(
            keyCode: event.keyCode,
            modifiers: modifiers,
            keyLabel: (label?.isEmpty ?? true) ? nil : label
        )
    }
}

extension ChorusLog {
    /// 視窗排列：快捷鍵註冊、指令結果。
    static let window = ChorusLog(category: "window")
}
