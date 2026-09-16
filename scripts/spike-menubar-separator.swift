// MB-0a spike — 選單列分隔項目加寬（永遠隱藏區可行性）。
//
// 在 macOS 27 建一個可辨識的 NSStatusItem，stdin 讀一字元切換
// length：variableLength ↔ 10000。觀察加寬後左側圖示是否被擠出可見範圍，
// 以及分隔項目放在原生 ≪ 收合區內時的行為。
//
// 人工觀察工具，不進 App target。跑法：
//
//     swiftc -O -o /tmp/spike-sep scripts/spike-menubar-separator.swift && /tmp/spike-sep
//
// 操作：空白鍵或 Enter 切換寬度；q 退出。SIGINT 也會清理。
// 請在三種狀態各觀察並截圖：≪ 收合時、≪ 展開時、展開後再切寬度。

import AppKit
import Foundation

final class SpikeSeparatorApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var expanded = false
    private let narrowLength = NSStatusItem.variableLength
    private let wideLength: CGFloat = 10_000
    private var stdinSource: DispatchSourceRead?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: narrowLength)
        if let button = item.button {
            button.title = "⋮"
            button.toolTip = "Chorus MB-0a separator spike"
        }
        statusItem = item

        print("MB-0a separator spike")
        print("空白鍵／Enter：切換 variableLength ↔ 10000；q：退出")
        printState(label: "啟動（窄）")
        startStdin()
    }

    private func startStdin() {
        let fd = FileHandle.standardInput.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleStdin()
        }
        source.setCancelHandler {}
        source.resume()
        stdinSource = source
    }

    private func handleStdin() {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(FileHandle.standardInput.fileDescriptor, &buffer, buffer.count)
        guard n > 0 else { return }
        for i in 0..<n {
            let c = buffer[i]
            switch c {
            case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                quit()
            case UInt8(ascii: " "), 10, 13: // space / LF / CR
                toggle()
            default:
                break
            }
        }
    }

    private func toggle() {
        guard let item = statusItem else { return }
        expanded.toggle()
        item.length = expanded ? wideLength : narrowLength
        printState(label: expanded ? "加寬 (10000)" : "還原 (variableLength)")
    }

    private func printState(label: String) {
        print("--- \(label) @ \(ISO8601DateFormatter().string(from: Date())) ---")
        guard let item = statusItem else {
            print("statusItem = nil")
            return
        }
        print("length = \(item.length)")
        if let button = item.button {
            print("button.frame = \(NSStringFromRect(button.frame))")
            if let window = button.window {
                print("button.window.frame = \(NSStringFromRect(window.frame))")
                print("button.window.screen = \(window.screen?.localizedName ?? "nil")")
            } else {
                print("button.window = nil")
            }
        } else {
            print("button = nil")
        }
        if let screen = NSScreen.main {
            print("NSScreen.main.frame = \(NSStringFromRect(screen.frame))  width=\(screen.frame.width)")
            print("NSScreen.main.visibleFrame = \(NSStringFromRect(screen.visibleFrame))")
        } else {
            print("NSScreen.main = nil")
        }
        // NSStatusBar 沒有公開列舉鄰近 items 的 API；印出系統列厚度與自身 window 作為鄰近 proxy。
        print("NSStatusBar.system.thickness = \(NSStatusBar.system.thickness)")
        if let win = statusItem?.button?.window {
            let peers = NSApp.windows.filter { $0 !== win && $0.level == win.level }
            print("同 level 的 NSApp.windows 數（不含自己）= \(peers.count)")
            for (idx, w) in peers.prefix(8).enumerated() {
                print("  peer[\(idx)].frame = \(NSStringFromRect(w.frame)) title=\(w.title)")
            }
        }
        fflush(stdout)
    }

    private func quit() {
        print("退出：removeStatusItem")
        cleanup()
        NSApp.terminate(nil)
    }

    func cleanup() {
        stdinSource?.cancel()
        stdinSource = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
}

let app = NSApplication.shared
let delegate = SpikeSeparatorApp()
app.delegate = delegate

signal(SIGINT) { _ in
    DispatchQueue.main.async {
        if let d = NSApp.delegate as? SpikeSeparatorApp {
            d.cleanup()
        }
        fputs("\nSIGINT：已 removeStatusItem\n", stderr)
        exit(0)
    }
}

app.run()
