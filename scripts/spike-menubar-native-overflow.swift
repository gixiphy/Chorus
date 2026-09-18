// R1 spike — macOS 27 有限寬度原生溢出邊界（新路線，獨立於 MB-0a／MB-0b）。
//
// 假設（Ice MacOS27NativeMenuBarHiding）：
//   - length 超過原生 status 區域會被丟棄（解釋 10000pt 失敗）
//   - 寬度落在區域內時，左側鄰近圖示進入系統溢出
//   - 「恢復」= 撤回自有佔位（isVisible=false），不是代按原生 ≪
//
//     swiftc -O -o /tmp/spike-overflow scripts/spike-menubar-native-overflow.swift
//     /tmp/spike-overflow              # 互動
//     /tmp/spike-overflow --auto      # 自動量測並寫結論到 stdout
//
// 互動：space 收納/撤回  n 窄分界  w 撤回  1..4 寬度預設  f± filler  m 地圖  p 環境  q 退出

import ApplicationServices
import AppKit
import Foundation

private let runID = String(Int(Date().timeIntervalSince1970))
private let autosavePrefix = "Chorus.R1Overflow.\(runID)"
private let menuBarStripYTolerance: CGFloat = 8

final class SpikeNativeOverflowApp: NSObject, NSApplicationDelegate {
    private struct Marker {
        let name: String
        let item: NSStatusItem
    }

    private var leftA: Marker?
    private var leftB: Marker?
    private var boundary: Marker?
    private var right: Marker?
    private var fillers: [Marker] = []
    private var stdinSource: DispatchSourceRead?
    private var concealing = false
    private var currentLength: CGFloat = 0
    private var widthPreset: WidthPreset = .regionMinus32
    private let autoMode: Bool

    private enum WidthPreset: String, CaseIterable {
        case regionMinus32 = "region-32"
        case regionMinus96 = "region-96"
        case halfRegion = "region/2"
        case fixed400 = "400"
        case fixed200 = "200"
        case fixed100 = "100"
        case fixed32 = "32"
    }

    init(autoMode: Bool) {
        self.autoMode = autoMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Preferred Position = distance from right edge → larger = further left.
        leftA = makeMarker(name: "LEFT-A", title: "LA", preferredPosition: 120)
        leftB = makeMarker(name: "LEFT-B", title: "LB", preferredPosition: 110)
        // 預設撤回；整理時才露出窄分界，收納時才加寬（對齊 Ice）
        boundary = makeBoundary(preferredPosition: 100, initiallyVisible: false)
        right = makeMarker(name: "RIGHT", title: "RT", preferredPosition: 90)

        // 預先塞滿右側空間，逼出原生溢出（空選單列只會左移、不會進 overflow）
        addFillers(count: 8)

        print("R1 native-overflow spike  runID=\(runID) auto=\(autoMode)")
        printEnvironment(label: "啟動")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.printOwnGeometry(label: "啟動（boundary 已撤回）")
            if self.autoMode {
                self.runAutoSequence()
            } else {
                print("space=收納/撤回  n=窄分界  w=撤回  1..7=寬度  f=加filler  d=減filler  m=地圖  p=環境  q=退出")
                self.startStdin()
            }
        }
    }

    // MARK: - Construction

    private func makeMarker(name: String, title: String, preferredPosition: Double) -> Marker {
        let autosave = "\(autosavePrefix).\(name)"
        UserDefaults.standard.set(preferredPosition, forKey: "NSStatusItem Preferred Position \(autosave)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosave
        if let button = item.button {
            button.title = title
            button.toolTip = "Chorus R1 \(name)"
            button.setAccessibilityIdentifier(autosave)
            button.setAccessibilityLabel("Chorus R1 \(name)")
        }
        return Marker(name: name, item: item)
    }

    private func makeBoundary(preferredPosition: Double, initiallyVisible: Bool) -> Marker {
        let autosave = "\(autosavePrefix).BOUNDARY"
        UserDefaults.standard.set(preferredPosition, forKey: "NSStatusItem Preferred Position \(autosave)")
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = autosave
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.isEnabled = false
            button.toolTip = "Chorus R1 BOUNDARY"
            button.setAccessibilityIdentifier(autosave)
            button.setAccessibilityLabel("Chorus R1 BOUNDARY")
        }
        if !initiallyVisible {
            let key = "NSStatusItem Preferred Position \(autosave)"
            let saved = UserDefaults.standard.object(forKey: key)
            item.isVisible = false
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
        }
        currentLength = initiallyVisible ? 1 : 0
        return Marker(name: "BOUNDARY", item: item)
    }

    private func addFillers(count: Int) {
        let start = fillers.count
        for i in 0..<count {
            let idx = start + i
            // 插在 RIGHT 右側（更靠右、數字更小），佔用常駐區空間
            let pos = 80.0 - Double(idx)
            let marker = makeMarker(name: "FILL-\(idx)", title: "F\(idx)", preferredPosition: pos)
            fillers.append(marker)
        }
        print("fillers=\(fillers.count)")
    }

    private func removeFiller() {
        guard let last = fillers.popLast() else { return }
        NSStatusBar.system.removeStatusItem(last.item)
        print("fillers=\(fillers.count)")
    }

    // MARK: - Width

    private func regionWidth(for screen: NSScreen) -> CGFloat {
        if let area = screen.auxiliaryTopRightArea, area.width > 0 {
            return area.width
        }
        return max(64, screen.frame.width - 300)
    }

    private func statusRegionMinX(for screen: NSScreen) -> CGFloat {
        screen.auxiliaryTopRightArea?.minX ?? (screen.frame.maxX - regionWidth(for: screen))
    }

    private func length(for preset: WidthPreset, screen: NSScreen) -> CGFloat {
        let region = regionWidth(for: screen)
        switch preset {
        case .regionMinus32: return max(32, region - 32)
        case .regionMinus96: return max(32, region - 96)
        case .halfRegion: return max(32, region / 2)
        case .fixed400: return 400
        case .fixed200: return 200
        case .fixed100: return 100
        case .fixed32: return 32
        }
    }

    private func activeScreen() -> NSScreen {
        right?.item.button?.window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func menuBarStripY(for screen: NSScreen) -> CGFloat {
        // AppKit：選單列 window 通常貼 visibleFrame.maxY
        screen.visibleFrame.maxY
    }

    private func isOnMenuBarStrip(_ windowFrame: CGRect, screen: NSScreen) -> Bool {
        abs(windowFrame.minY - menuBarStripY(for: screen)) <= menuBarStripYTolerance
            || abs(windowFrame.maxY - screen.frame.maxY) <= menuBarStripYTolerance
    }

    // MARK: - Actions

    private func applyConceal(reason: String, preset: WidthPreset? = nil) {
        if let preset { widthPreset = preset }
        guard let item = boundary?.item else { return }
        let screen = activeScreen()
        let len = length(for: widthPreset, screen: screen)
        if item.length != len { item.length = len }
        if item.button?.isEnabled != false { item.button?.isEnabled = false }
        if !item.isVisible { item.isVisible = true }
        concealing = true
        currentLength = len
        printState(label: "\(reason) preset=\(widthPreset.rawValue) length=\(len)")
    }

    private func showNarrow(reason: String) {
        guard let item = boundary?.item else { return }
        if item.length != 1 { item.length = 1 }
        if item.button?.isEnabled != true { item.button?.isEnabled = true }
        if !item.isVisible { item.isVisible = true }
        concealing = false
        currentLength = 1
        printState(label: reason)
    }

    private func withdrawBoundary(reason: String) {
        guard let item = boundary?.item else { return }
        let key = "NSStatusItem Preferred Position \(item.autosaveName ?? "")"
        let saved = UserDefaults.standard.object(forKey: key)
        item.isVisible = false
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        if item.button?.isEnabled == true { item.button?.isEnabled = false }
        concealing = false
        currentLength = 0
        printState(label: "\(reason)（isVisible=false）")
    }

    // MARK: - Observation

    private struct ItemObservation {
        let name: String
        let visible: Bool
        let length: CGFloat
        let windowFrame: CGRect?
        let onStrip: Bool
        let leftOfStatusRegion: Bool
    }

    private func observe(_ marker: Marker, screen: NSScreen) -> ItemObservation {
        let item = marker.item
        let win = item.button?.window?.frame
        let onStrip = win.map { isOnMenuBarStrip($0, screen: screen) } ?? false
        let minX = statusRegionMinX(for: screen)
        let leftOf = win.map { $0.maxX < minX - 1 } ?? false
        return ItemObservation(
            name: marker.name,
            visible: item.isVisible,
            length: item.length,
            windowFrame: win,
            onStrip: onStrip,
            leftOfStatusRegion: leftOf
        )
    }

    private func printObservation(_ obs: ItemObservation) {
        let winStr = obs.windowFrame.map { NSStringFromRect($0) } ?? "nil"
        print("\(obs.name): visible=\(obs.visible) length=\(obs.length) win=\(winStr) onStrip=\(obs.onStrip) leftOfRegion=\(obs.leftOfStatusRegion)")
    }

    private func snapshot(label: String) -> [ItemObservation] {
        let screen = activeScreen()
        print("--- 幾何 \(label) screen=\(screen.localizedName) stripY≈\(menuBarStripY(for: screen)) regionMinX=\(statusRegionMinX(for: screen)) ---")
        var out: [ItemObservation] = []
        for marker in [leftA, leftB, boundary, right].compactMap({ $0 }) {
            let obs = observe(marker, screen: screen)
            printObservation(obs)
            out.append(obs)
        }
        // fillers 只印在 strip / 溢出的計數
        var fillerOn = 0
        var fillerOff = 0
        for f in fillers {
            let obs = observe(f, screen: screen)
            if obs.onStrip { fillerOn += 1 } else { fillerOff += 1 }
        }
        print("FILLERS: onStrip=\(fillerOn) offStrip=\(fillerOff) total=\(fillers.count)")
        fflush(stdout)
        return out
    }

    private func printOwnGeometry(label: String) {
        _ = snapshot(label: label)
    }

    /// 收納成功啟發式（仍須人工確認時鐘可點）：
    /// - RIGHT 仍在選單列 strip
    /// - LEFT-A 或 LEFT-B 不在 strip（進溢出／被推離可見列）
    /// - BOUNDARY 在 strip 且可見（佔位仍在，不是自己被丟棄）
    private func evaluateConceal(_ obs: [ItemObservation]) -> (pass: Bool, reason: String) {
        guard let right = obs.first(where: { $0.name == "RIGHT" }),
              let boundary = obs.first(where: { $0.name == "BOUNDARY" }),
              let leftA = obs.first(where: { $0.name == "LEFT-A" }),
              let leftB = obs.first(where: { $0.name == "LEFT-B" }) else {
            return (false, "missing markers")
        }
        if !right.onStrip {
            return (false, "RIGHT 離開選單列（入口不可達）")
        }
        if !boundary.visible || !boundary.onStrip {
            return (false, "BOUNDARY 未留在選單列（佔位被丟棄或移出）")
        }
        let leftConcealed = (!leftA.onStrip || leftA.leftOfStatusRegion)
            || (!leftB.onStrip || leftB.leftOfStatusRegion)
        if !leftConcealed {
            return (false, "LEFT 仍在可見選單列（僅左移、未進溢出）")
        }
        return (true, "RIGHT 可達、BOUNDARY 在列、至少一個 LEFT 離開可見列")
    }

    private func evaluateRestore(_ obs: [ItemObservation]) -> (pass: Bool, reason: String) {
        guard let right = obs.first(where: { $0.name == "RIGHT" }),
              let boundary = obs.first(where: { $0.name == "BOUNDARY" }),
              let leftA = obs.first(where: { $0.name == "LEFT-A" }),
              let leftB = obs.first(where: { $0.name == "LEFT-B" }) else {
            return (false, "missing markers")
        }
        if boundary.visible {
            return (false, "BOUNDARY 仍可見")
        }
        if !right.onStrip {
            return (false, "RIGHT 不在選單列")
        }
        if !leftA.onStrip || !leftB.onStrip {
            return (false, "LEFT 撤回後仍不在選單列")
        }
        return (true, "BOUNDARY 已撤回、LEFT/RIGHT 回到選單列")
    }

    // MARK: - Auto sequence

    private func runAutoSequence() {
        print("=== AUTO R1 開始 ===")
        var results: [(preset: String, conceal: Bool, restore: Bool, detail: String)] = []

        let presets: [WidthPreset] = [
            .fixed100, .fixed200, .fixed400, .halfRegion, .regionMinus96, .regionMinus32,
        ]

        func wait(_ seconds: Double, then work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }

        func runPreset(_ index: Int) {
            if index >= presets.count {
                finishAuto(results: results)
                return
            }
            let preset = presets[index]
            print("\n===== PRESET \(preset.rawValue) =====")
            withdrawBoundary(reason: "preset 前清理")
            wait(0.35) {
                let before = self.snapshot(label: "before \(preset.rawValue)")
                self.applyConceal(reason: "收納", preset: preset)
                wait(0.5) {
                    let concealed = self.snapshot(label: "concealed \(preset.rawValue)")
                    let cEval = self.evaluateConceal(concealed)
                    print("CONCEAL_EVAL \(preset.rawValue): \(cEval.pass ? "PASS" : "FAIL") — \(cEval.reason)")
                    self.withdrawBoundary(reason: "恢復")
                    wait(0.5) {
                        let restored = self.snapshot(label: "restored \(preset.rawValue)")
                        let rEval = self.evaluateRestore(restored)
                        print("RESTORE_EVAL \(preset.rawValue): \(rEval.pass ? "PASS" : "FAIL") — \(rEval.reason)")
                        results.append((
                            preset.rawValue,
                            cEval.pass,
                            rEval.pass,
                            "conceal=\(cEval.reason); restore=\(rEval.reason); beforeRightOn=\(before.first(where:{$0.name=="RIGHT"})?.onStrip ?? false)"
                        ))
                        runPreset(index + 1)
                    }
                }
            }
        }

        runPreset(0)
    }

    private func finishAuto(results: [(preset: String, conceal: Bool, restore: Bool, detail: String)]) {
        print("\n=== AUTO R1 總結 ===")
        print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let screen = activeScreen()
        print("screen=\(screen.localizedName) region=\(regionWidth(for: screen)) fillers=\(fillers.count)")
        var anyPass = false
        for r in results {
            let mark = (r.conceal && r.restore) ? "PASS" : "FAIL"
            if r.conceal && r.restore { anyPass = true }
            print("\(mark) preset=\(r.preset) conceal=\(r.conceal) restore=\(r.restore) | \(r.detail)")
        }
        print("R1_VERDICT=\(anyPass ? "CANDIDATE_PASS" : "FAIL")")
        print("註：CANDIDATE_PASS 仍需人工確認系統時鐘與 RIGHT 可點；幾何啟發式不能單獨算產品通過。")
        cleanup()
        NSApp.terminate(nil)
    }

    // MARK: - Env / map

    private func printEnvironment(label: String) {
        print("--- 環境 \(label) @ \(ISO8601DateFormatter().string(from: Date())) ---")
        print("OS = \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("AX trusted = \(AXIsProcessTrusted())")
        for (i, screen) in NSScreen.screens.enumerated() {
            let notch: String
            if #available(macOS 12.0, *) {
                notch = screen.safeAreaInsets.top > 0 ? "yes(\(screen.safeAreaInsets.top))" : "no"
            } else {
                notch = "?"
            }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? -1
            print("screen[\(i)] \(screen.localizedName) id=\(displayID) scale=\(screen.backingScaleFactor) notch=\(notch)")
            print("  frame=\(NSStringFromRect(screen.frame)) visible=\(NSStringFromRect(screen.visibleFrame))")
            print("  auxTopRight=\(screen.auxiliaryTopRightArea.map { NSStringFromRect($0) } ?? "nil")")
            print("  regionWidth=\(regionWidth(for: screen)) conceal[\(widthPreset.rawValue)]=\(length(for: widthPreset, screen: screen))")
        }
        fflush(stdout)
    }

    private func printState(label: String) {
        print("--- \(label) @ \(ISO8601DateFormatter().string(from: Date())) ---")
        print("concealing=\(concealing) currentLength=\(currentLength) preset=\(widthPreset.rawValue)")
        if let item = boundary?.item {
            print("boundary.isVisible=\(item.isVisible) length=\(item.length)")
        }
        fflush(stdout)
    }

    private func printMapSummary() {
        _ = snapshot(label: "地圖")
        guard AXIsProcessTrusted() else {
            print("AX 未信任：跳過 MenuBarAgent 地圖")
            return
        }
        guard let pid = menuBarAgentPID() else {
            print("找不到 MenuBarAgent")
            return
        }
        let appEl = AXUIElementCreateApplication(pid)
        var extrasRef: CFTypeRef?
        let extras: AXUIElement?
        if AXUIElementCopyAttributeValue(appEl, kAXExtrasMenuBarAttribute as CFString, &extrasRef) == .success {
            extras = extrasRef.map { ($0 as! AXUIElement) }
        } else {
            extras = nil
        }
        guard let extras else {
            print("MenuBarAgent 無 extras menu bar")
            return
        }
        var lines: [String] = []
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 6 else { return }
            let role = axString(el, kAXRoleAttribute as String) ?? "?"
            let desc = axString(el, kAXDescriptionAttribute as String) ?? ""
            let title = axString(el, kAXTitleAttribute as String) ?? ""
            let blob = (desc + " " + title).lowercased()
            if blob.contains("chorus r1") || blob.contains("時鐘") || blob.contains("clock")
                || (blob.contains("隱藏") && blob.contains("選單列"))
                || (blob.contains("hidden") && blob.contains("menu")) {
                let f = axFrame(el).map {
                    "(\(Int($0.origin.x)),\(Int($0.origin.y))) \(Int($0.size.width))×\(Int($0.size.height))"
                } ?? "?"
                lines.append("role=\(role) desc=\"\(desc)\" title=\"\(title)\" frame=\(f)")
            }
            for child in axChildren(el) {
                walk(child, depth: depth + 1)
            }
        }
        walk(extras, depth: 0)
        print("--- MenuBarAgent extras 摘要 \(lines.count) ---")
        for line in lines.prefix(60) { print(line) }
        fflush(stdout)
    }

    private func menuBarAgentPID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.controlcenter" || $0.localizedName == "MenuBarAgent" }
            .map { $0.processIdentifier }
            ?? {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                task.arguments = ["-x", "MenuBarAgent"]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                try? task.run()
                task.waitUntilExit()
                let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return pid_t(first)
            }()
    }

    private func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
              let v = value else { return nil }
        if CFGetTypeID(v) == CFStringGetTypeID() {
            return (v as! CFString) as String
        }
        return String(describing: v)
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              let posVal = posRef else { return nil }
        var pos = CGPoint.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos) else { return nil }
        var sizeRef: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let s = sizeRef, AXValueGetValue(s as! AXValue, .cgSize, &size) {
            return CGRect(origin: pos, size: size)
        }
        return CGRect(origin: pos, size: .zero)
    }

    // MARK: - Stdin

    private func startStdin() {
        let fd = FileHandle.standardInput.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.handleStdin() }
        source.resume()
        stdinSource = source
    }

    private func handleStdin() {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(FileHandle.standardInput.fileDescriptor, &buffer, buffer.count)
        guard n > 0 else { return }
        for i in 0..<n {
            switch buffer[i] {
            case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                quit()
            case UInt8(ascii: " "), 10, 13:
                if concealing { withdrawBoundary(reason: "恢復排列") }
                else { applyConceal(reason: "收納圖示") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.printOwnGeometry(label: "操作後")
                }
            case UInt8(ascii: "n"), UInt8(ascii: "N"):
                showNarrow(reason: "窄分界")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.printOwnGeometry(label: "窄分界後")
                }
            case UInt8(ascii: "w"), UInt8(ascii: "W"):
                withdrawBoundary(reason: "手動撤回")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.printOwnGeometry(label: "撤回後")
                }
            case UInt8(ascii: "1"): widthPreset = .regionMinus32; print("preset=\(widthPreset.rawValue)")
            case UInt8(ascii: "2"): widthPreset = .regionMinus96; print("preset=\(widthPreset.rawValue)")
            case UInt8(ascii: "3"): widthPreset = .halfRegion; print("preset=\(widthPreset.rawValue)")
            case UInt8(ascii: "4"): widthPreset = .fixed400; print("preset=\(widthPreset.rawValue)")
            case UInt8(ascii: "5"): widthPreset = .fixed200; print("preset=\(widthPreset.rawValue)")
            case UInt8(ascii: "6"): widthPreset = .fixed100; print("preset=\(widthPreset.rawValue)")
            case UInt8(ascii: "7"): widthPreset = .fixed32; print("preset=\(widthPreset.rawValue)")
            case UInt8(ascii: "f"), UInt8(ascii: "F"):
                addFillers(count: 2)
            case UInt8(ascii: "d"), UInt8(ascii: "D"):
                removeFiller()
            case UInt8(ascii: "m"), UInt8(ascii: "M"):
                printMapSummary()
            case UInt8(ascii: "p"), UInt8(ascii: "P"):
                printEnvironment(label: "手動")
            default:
                break
            }
        }
    }

    private func quit() {
        print("退出：清理")
        cleanup()
        NSApp.terminate(nil)
    }

    func cleanup() {
        stdinSource?.cancel()
        stdinSource = nil
        for marker in fillers {
            NSStatusBar.system.removeStatusItem(marker.item)
        }
        fillers.removeAll()
        for marker in [leftA, leftB, boundary, right].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(marker.item)
        }
        leftA = nil
        leftB = nil
        boundary = nil
        right = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
}

let autoMode = CommandLine.arguments.contains("--auto")
let app = NSApplication.shared
let delegate = SpikeNativeOverflowApp(autoMode: autoMode)
app.delegate = delegate

signal(SIGINT) { _ in
    DispatchQueue.main.async {
        if let d = NSApp.delegate as? SpikeNativeOverflowApp {
            d.cleanup()
        }
        fputs("\nSIGINT：已清理\n", stderr)
        exit(0)
    }
}

app.run()
