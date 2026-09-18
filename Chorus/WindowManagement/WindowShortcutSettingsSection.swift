import AppKit
import ChorusCore
import Observation
import SwiftUI

/// 設定頁的「快捷鍵」：單一一組預設按鍵，可逐項錄製／清除、一鍵恢復預設。
struct WindowShortcutSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var recorder = ShortcutRecorder()
    @State private var pendingConflict: PendingConflict?
    @State private var resultMessage: String?

    private struct PendingConflict: Equatable {
        var command: WindowCommand
        var chord: KeyChord
        var owner: WindowCommand
    }

    private var bindings: ShortcutBindings { appState.settings.windowArrangementShortcuts }

    var body: some View {
        Section("快捷鍵") {
            HStack {
                Text(bindings.isDefault ? "使用預設按鍵" : "已自訂")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢復預設") {
                    endRecording()
                    pendingConflict = nil
                    commit(ShortcutBindings())
                }
                .controlSize(.small)
                .disabled(bindings.isDefault)
            }
            // 錄到一半切走分頁或關掉設定：把全域快捷鍵接回去
            .onDisappear { endRecording() }
            if let resultMessage {
                Label(resultMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("可以只用選單而不綁快捷鍵。同一組按鍵只能給一個動作；其他 App 自己的快捷鍵無法完整偵測，撞鍵時請換一組。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ForEach(visibleGroups, id: \.self) { group in
            Section(group.title) {
                ForEach(WindowCommand.commands(in: group), id: \.self) { command in
                    row(command)
                }
            }
        }
    }

    /// 「鍵盤選區」只對超寬螢幕有意義：沒接超寬螢幕就不列，除非先前已綁過（要留得下清除的入口）。
    private var visibleGroups: [WindowCommand.Group] {
        let hasUltrawide = ScreenTopology.capture(generation: 0).screens.contains(where: \.isUltrawide)
        return WindowCommand.Group.allCases.filter { group in
            group != .advanced || hasUltrawide || bindings[.selectZone] != nil
        }
    }

    // MARK: - 逐項

    @ViewBuilder
    private func row(_ command: WindowCommand) -> some View {
        let chord = bindings[command]
        let isRecording = recorder.recording == command
        let unavailable = appState.windowManager.unavailableShortcuts.contains(command)

        HStack(spacing: 8) {
            WindowCommandGlyph(command: command)
            Text(command.title)
            Spacer()
            if isRecording {
                Text("請按下快捷鍵…（Esc 取消）")
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else if let chord {
                if unavailable {
                    Label("不可用", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("系統拒絕註冊這組按鍵，可能已被其他程式占用")
                }
                Text(chord.displayString)
                    .foregroundStyle(unavailable ? .secondary : .primary)
            } else {
                Text("未綁定")
                    .foregroundStyle(.tertiary)
            }
            Button(isRecording ? String(localized: "取消") : String(localized: "錄製")) {
                isRecording ? endRecording() : beginRecording(command)
            }
            .controlSize(.small)
            Button {
                endRecording()
                var next = bindings
                next.clear(command)
                commit(next)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(chord == nil)
            .help("清除快捷鍵")
            .accessibilityLabel("清除「\(command.title)」的快捷鍵")
        }

        if let conflict = pendingConflict, conflict.command == command {
            HStack {
                Text("\(conflict.chord.displayString) 已被「\(conflict.owner.title)」使用。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("換一組") {
                    pendingConflict = nil
                    beginRecording(command)
                }
                Button("移轉給這個動作") {
                    var next = bindings
                    next.assign(conflict.chord, to: command, transferring: true)
                    commit(next)
                    pendingConflict = nil
                }
            }
            .controlSize(.small)
        }
    }

    private func beginRecording(_ command: WindowCommand) {
        pendingConflict = nil
        resultMessage = nil
        appState.windowManager.setShortcutRecording(true)
        recorder.begin(command) { chord in
            endRecording()
            guard let chord else { return }
            var next = bindings
            switch next.assign(chord, to: command) {
            case .assigned:
                commit(next)
            case .conflict(let owner):
                pendingConflict = PendingConflict(command: command, chord: chord, owner: owner)
            case .invalid:
                resultMessage = String(localized: "快捷鍵至少要包含 ⌃、⌥ 或 ⌘ 其中一個修飾鍵。")
            }
        }
    }

    private func endRecording() {
        recorder.cancel()
        appState.windowManager.setShortcutRecording(false)
    }

    private func commit(_ next: ShortcutBindings) {
        switch appState.windowManager.updateShortcuts(next) {
        case .applied:
            resultMessage = nil
        case .rolledBack(let failed):
            let names = failed.sorted { $0.order < $1.order }.map(\.title).joined(separator: "、")
            resultMessage = String(localized: "系統拒絕註冊「\(names)」的按鍵，已撤回這次變更並恢復原本的快捷鍵。")
        case .degraded(let unavailable):
            let names = unavailable.sorted { $0.order < $1.order }.map(\.title).joined(separator: "、")
            resultMessage = String(localized: "新的按鍵註冊失敗，原本的也無法完整恢復。目前不可用：\(names)。")
        }
    }
}

/// 錄製一組按鍵：只聽設定視窗自己的 keyDown，錄到就吃掉，不讓它變成文字輸入。
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var recording: WindowCommand?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var completion: ((KeyChord?) -> Void)?

    /// `completion(nil)`＝使用者按 Esc 取消。
    func begin(_ command: WindowCommand, completion: @escaping (KeyChord?) -> Void) {
        cancel()
        recording = command
        self.completion = completion
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        completion = nil
    }

    private func handle(_ event: NSEvent) {
        let chord = KeyChord(event: event)
        if event.keyCode == 53, chord.modifiers.isEmpty {
            finish(nil)
        } else if chord.isBindable {
            finish(chord)
        } else {
            NSSound.beep()
        }
    }

    private func finish(_ chord: KeyChord?) {
        let completion = completion
        cancel()
        completion?(chord)
    }
}
