// MB-0b spike — Accessibility 代按原生選單列 ≪（收合／展開）。
//
// 對 MenuBarAgent 建 AXUIElement，遞迴列印 menu bar 子樹，嘗試找到 ≪
// 並執行 kAXPressAction。另試訂閱 kAXValueChangedNotification／
// kAXLayoutChangedNotification，觀察收合狀態是否可事件驅動（否則需輪詢）。
//
// 人工觀察工具，不進 App target、不呼叫帶 prompt 的信任 API。跑法：
//
//     swiftc -O -o /tmp/spike-ax scripts/spike-menubar-ax-collapse.swift && /tmp/spike-ax
//
// 需已授予「輔助使用」。未信任時印提示並 exit(1)。

import ApplicationServices
import AppKit
import Foundation

private let maxDepth = 6
private let observeSeconds: TimeInterval = 8

// MARK: - Helpers

func axString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value else { return nil }
    if CFGetTypeID(v) == CFStringGetTypeID() {
        return (v as! CFString) as String
    }
    return String(describing: v)
}

func axBool(_ element: AXUIElement, _ attr: String) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue((v as! CFBoolean))
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
          let posRef = value else { return nil }
    var pos = CGPoint.zero
    guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) else { return nil }

    var sizeRef: CFTypeRef?
    var size = CGSize.zero
    if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
       let s = sizeRef, AXValueGetValue(s as! AXValue, .cgSize, &size) {
        return CGRect(origin: pos, size: size)
    }
    return CGRect(origin: pos, size: .zero)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let arr = value as? [AXUIElement] else { return [] }
    return arr
}

struct NodeInfo: Equatable {
    let path: String
    let role: String
    let subrole: String
    let description: String
    let title: String
    let frame: String
}

func collectTree(_ element: AXUIElement, path: String, depth: Int, into out: inout [NodeInfo]) {
    let role = axString(element, kAXRoleAttribute as String) ?? "?"
    let subrole = axString(element, kAXSubroleAttribute as String) ?? ""
    let desc = axString(element, kAXDescriptionAttribute as String) ?? ""
    let title = axString(element, kAXTitleAttribute as String) ?? ""
    let frameStr: String
    if let f = axFrame(element) {
        frameStr = "(\(Int(f.origin.x)),\(Int(f.origin.y))) \(Int(f.size.width))×\(Int(f.size.height))"
    } else {
        frameStr = "?"
    }
    out.append(NodeInfo(path: path, role: role, subrole: subrole, description: desc, title: title, frame: frameStr))

    guard depth < maxDepth else { return }
    let kids = axChildren(element)
    for (i, child) in kids.enumerated() {
        collectTree(child, path: "\(path)/\(i)", depth: depth + 1, into: &out)
    }
}

func printTree(_ nodes: [NodeInfo], header: String) {
    print("=== \(header)（\(nodes.count) nodes, depth≤\(maxDepth)）===")
    for n in nodes {
        let indent = String(repeating: "  ", count: max(0, n.path.split(separator: "/").count - 1))
        var line = "\(indent)[\(n.path)] role=\(n.role)"
        if !n.subrole.isEmpty { line += " subrole=\(n.subrole)" }
        if !n.description.isEmpty { line += " desc=\"\(n.description)\"" }
        if !n.title.isEmpty { line += " title=\"\(n.title)\"" }
        line += " frame=\(n.frame)"
        print(line)
    }
    fflush(stdout)
}

func treeFingerprint(_ nodes: [NodeInfo]) -> String {
    nodes.map { "\($0.path)|\($0.role)|\($0.subrole)|\($0.description)|\($0.frame)" }.joined(separator: "\n")
}

func findCollapseCandidates(_ nodes: [NodeInfo], elementsByPath: [String: AXUIElement]) -> [(path: String, reason: String, element: AXUIElement)] {
    var hits: [(String, String, AXUIElement)] = []
    for n in nodes {
        guard let el = elementsByPath[n.path] else { continue }
        let blob = (n.description + " " + n.title + " " + n.subrole).lowercased()
        var reasons: [String] = []
        // description / title 常見：Extra、collapse、chevron、disclose、menu bar extras…
        if blob.contains("≪") || blob.contains("«") || blob.contains("<<") {
            reasons.append("glyph-in-text")
        }
        if blob.contains("collapse") || blob.contains("expand") || blob.contains("extra")
            || blob.contains("disclose") || blob.contains("chevron") || blob.contains("hidden")
            || blob.contains("顯示更多") || blob.contains("隐藏") || blob.contains("收合")
            || blob.contains("展開") || blob.contains("更多") {
            reasons.append("keyword")
        }
        // 位置啟發式：選單列右側、矮且窄的按鈕（≪ 通常在常駐區左緣）
        if let f = axFrame(el), f.size.height > 0, f.size.width > 0, f.size.width <= 40, f.size.height <= 40 {
            if let screen = NSScreen.main {
                let midX = screen.frame.midX
                if f.origin.x > midX {
                    reasons.append("small-control-right-half")
                }
            }
        }
        if !reasons.isEmpty {
            hits.append((n.path, reasons.joined(separator: "+"), el))
        }
    }
    return hits
}

func indexElements(_ element: AXUIElement, path: String, depth: Int, into map: inout [String: AXUIElement]) {
    map[path] = element
    guard depth < maxDepth else { return }
    for (i, child) in axChildren(element).enumerated() {
        indexElements(child, path: "\(path)/\(i)", depth: depth + 1, into: &map)
    }
}

// MARK: - MenuBarAgent pid

func menuBarAgentPID() -> pid_t? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "MenuBarAgent"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        print("pgrep 失敗：\(error)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    // 可能多行；取第一個
    let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    return pid_t(first)
}

// MARK: - Observer

final class AXObserverBox {
    var observer: AXObserver?
    let lock = NSLock()
    var events: [(String, String)] = [] // (notification, elementDesc)

    func append(_ note: String, _ desc: String) {
        lock.lock()
        events.append((note, desc))
        lock.unlock()
        print("AX notify: \(note)  element=\(desc)")
        fflush(stdout)
    }

    func snapshot() -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

func installObservers(pid: pid_t, root: AXUIElement, box: AXObserverBox) -> Bool {
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let box = Unmanaged<AXObserverBox>.fromOpaque(refcon).takeUnretainedValue()
        let note = notification as String
        let desc = axString(element, kAXDescriptionAttribute as String)
            ?? axString(element, kAXRoleAttribute as String)
            ?? "?"
        box.append(note, desc)
    }
    let createStatus = AXObserverCreate(pid, callback, &observer)
    guard createStatus == .success, let observer else {
        print("AXObserverCreate 失敗：\(createStatus.rawValue)")
        return false
    }
    box.observer = observer
    let refcon = Unmanaged.passUnretained(box).toOpaque()

    let notes = [
        kAXValueChangedNotification as String,
        kAXLayoutChangedNotification as String,
        kAXUIElementDestroyedNotification as String,
        "AXMenuBarItemAddedNotification",
        "AXMenuBarItemRemovedNotification",
    ]
    for note in notes {
        let st = AXObserverAddNotification(observer, root, note as CFString, refcon)
        print("AXObserverAddNotification \(note) → \(st.rawValue)")
    }
    // 也掛在應用程式根，擴大覆蓋
    let app = AXUIElementCreateApplication(pid)
    for note in [kAXValueChangedNotification as String, kAXLayoutChangedNotification as String] {
        _ = AXObserverAddNotification(observer, app, note as CFString, refcon)
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    return true
}

// MARK: - Main

guard AXIsProcessTrusted() else {
    fputs("""
    輔助使用未授予（AXIsProcessTrusted() == false）。
    請到「系統設定 → 隱私權與安全性 → 輔助使用」啟用目前終端機（或 Cursor），
    然後重跑。本腳本不會呼叫 AXIsProcessTrustedWithOptions prompt。

    """, stderr)
    exit(1)
}

print("AXIsProcessTrusted = true")

guard let pid = menuBarAgentPID() else {
    fputs("找不到 MenuBarAgent（pgrep -x MenuBarAgent）。\n", stderr)
    exit(1)
}
print("MenuBarAgent pid = \(pid)")

let appEl = AXUIElementCreateApplication(pid)

// 找 extras / menu bar
var menuBarRef: CFTypeRef?
var extrasBar: AXUIElement?
if AXUIElementCopyAttributeValue(appEl, kAXExtrasMenuBarAttribute as CFString, &menuBarRef) == .success,
   let mb = menuBarRef {
    extrasBar = (mb as! AXUIElement)
    print("取得 kAXExtrasMenuBarAttribute")
}
if extrasBar == nil {
    var mbRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef) == .success,
       let mb = mbRef {
        extrasBar = (mb as! AXUIElement)
        print("fallback：使用 kAXMenuBarAttribute")
    }
}

let root = extrasBar ?? appEl
if extrasBar == nil {
    print("警告：無 extras／menu bar attribute，改列印整個 MenuBarAgent 應用程式樹")
}

var before: [NodeInfo] = []
var beforeMap: [String: AXUIElement] = [:]
indexElements(root, path: "root", depth: 0, into: &beforeMap)
collectTree(root, path: "root", depth: 0, into: &before)
printTree(before, header: "按壓前")

let candidates = findCollapseCandidates(before, elementsByPath: beforeMap)
print("=== ≪ 候選（\(candidates.count)）===")
if candidates.isEmpty {
    print("未依 description／關鍵字／位置啟發式找到候選。請從上方樹手動辨識。")
} else {
    for (i, c) in candidates.enumerated() {
        let n = before.first { $0.path == c.path }
        print("  #\(i) path=\(c.path) reason=\(c.reason) desc=\"\(n?.description ?? "")\" frame=\(n?.frame ?? "?")")
    }
}

let box = AXObserverBox()
_ = installObservers(pid: pid, root: root, box: box)

let target: AXUIElement?
let targetLabel: String
if let first = candidates.first {
    target = first.element
    targetLabel = "\(first.path) (\(first.reason))"
} else {
    target = nil
    targetLabel = "無"
}

if let target {
    print("=== 執行 kAXPressAction → \(targetLabel) ===")
    let press = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print("AXUIElementPerformAction(kAXPressAction) → \(press.rawValue)")
} else {
    print("=== 跳過按壓（無候選）===")
}

// 等一下讓 layout／notification 進來
RunLoop.main.run(until: Date().addingTimeInterval(1.0))

var after: [NodeInfo] = []
collectTree(root, path: "root", depth: 0, into: &after)
printTree(after, header: "按壓後（+1s）")

let beforeFP = treeFingerprint(before)
let afterFP = treeFingerprint(after)
if beforeFP == afterFP {
    print("子樹指紋：無差異（按壓可能無效，或選到錯誤元素，或狀態未反映在 AX 樹上）")
} else {
    print("子樹指紋：有差異")
    let beforeSet = Set(before.map { "\($0.path)|\($0.description)|\($0.frame)" })
    let afterSet = Set(after.map { "\($0.path)|\($0.description)|\($0.frame)" })
    let removed = beforeSet.subtracting(afterSet)
    let added = afterSet.subtracting(beforeSet)
    print("  移除／改變前：\(removed.count)  新增／改變後：\(added.count)")
    for line in removed.prefix(12) { print("  - \(line)") }
    for line in added.prefix(12) { print("  + \(line)") }
}

print("=== 繼續聽 AX notification \(Int(observeSeconds))s（可手動再點 ≪ 對照）===")
RunLoop.main.run(until: Date().addingTimeInterval(observeSeconds))
let events = box.snapshot()
print("=== notification 總結：\(events.count) 筆 ===")
if events.isEmpty {
    print("期間無 ValueChanged／LayoutChanged 等通知 → 收合狀態可能需要輪詢，或通知名／掛載點不對。")
} else {
    var counts: [String: Int] = [:]
    for (note, _) in events { counts[note, default: 0] += 1 }
    for (note, n) in counts.sorted(by: { $0.key < $1.key }) {
        print("  \(note): \(n)")
    }
}

print("MB-0b 結束。請把「找不找得到 ≪／按了有無效應／要不要輪詢」寫回 DESIGN §4.1。")
exit(0)
