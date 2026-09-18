// MB-0b spike — Accessibility 代按原生選單列 ≪（收合／展開）。
//
// 對 MenuBarAgent 建 AXUIElement，遞迴列印 extras menu bar 子樹，以 AXButton
// 「顯示隱藏的選單列項目」為最高優先找 ≪，並執行 kAXPressAction。另試訂閱
// kAXValueChangedNotification／kAXLayoutChangedNotification，觀察收合狀態
// 是否可事件驅動（否則需輪詢）。
//
// 人工觀察工具，不進 App target、不呼叫帶 prompt 的信任 API。跑法：
//
//     swiftc -O -o /tmp/spike-ax scripts/spike-menubar-ax-collapse.swift
//     /tmp/spike-ax                 # 找 ≪、按一次、聽 notification
//     /tmp/spike-ax --restore       # 同上，觀察後再按一次還原收合狀態
//     /tmp/spike-ax --map           # 只讀：跨 App 列印整條選單列 status item 地圖
//
// 需已授予「輔助使用」。未信任時印提示並 exit(1)。

import ApplicationServices
import AppKit
import Foundation

private let maxDepth = 6
private let observeSeconds: TimeInterval = 8

enum Mode {
    case press
    case pressAndRestore
    case mapOnly
}

func parseMode(_ args: [String]) -> Mode {
    if args.contains("--map") { return .mapOnly }
    if args.contains("--restore") { return .pressAndRestore }
    return .press
}

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

func axActionNames(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    guard AXUIElementCopyActionNames(element, &value) == .success,
          let arr = value as? [String] else { return [] }
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

struct Candidate {
    let path: String
    let score: Int
    let reason: String
    let element: AXUIElement
}

func scoreCollapseCandidate(_ n: NodeInfo) -> (score: Int, reason: String)? {
    // 容器與一般圖示不是 ≪
    let excludedRoles: Set<String> = ["AXMenuBar", "AXGroup", "AXMenuExtra", "AXMenuBarItem"]
    if excludedRoles.contains(n.role) {
        // AXMenuBarItem 若剛好是 ≪ 按鈕的父層會被排除；真正的 ≪ 是 AXButton
        return nil
    }

    let blob = (n.description + " " + n.title).lowercased()
    var score = 0
    var reasons: [String] = []

    let exactPhrases = [
        "顯示隱藏的選單列項目",
        "隐藏的菜单栏项目",
        "hidden menu bar items",
        "show hidden menu bar items",
        "hide menu bar items",
    ]
    if exactPhrases.contains(where: { blob.contains($0.lowercased()) })
        || (blob.contains("隱藏") && blob.contains("選單列"))
        || (blob.contains("隐藏") && blob.contains("菜单栏"))
        || (blob.contains("hidden") && blob.contains("menu bar")) {
        score += 100
        reasons.append("exact-collapse-label")
    }

    if n.role == "AXButton" {
        score += 40
        reasons.append("role-button")
    }

    if blob.contains("≪") || blob.contains("«") || blob.contains("<<") {
        score += 30
        reasons.append("glyph-in-text")
    }

    // 避開「Menu Extras」這類含 extra 的容器描述；只留較窄關鍵字
    if blob.contains("collapse") || blob.contains("disclose") || blob.contains("chevron")
        || blob.contains("收合") || blob.contains("展開") {
        score += 10
        reasons.append("keyword")
    }

    // 位置啟發式：矮且窄、在螢幕右半
    if let f = axFrameForPath(n), f.size.height > 0, f.size.width > 0,
       f.size.width <= 40, f.size.height <= 40,
       let screen = NSScreen.main, f.origin.x > screen.frame.midX {
        score += 5
        reasons.append("small-control-right-half")
    }

    guard score > 0 else { return nil }
    return (score, reasons.joined(separator: "+"))
}

/// frame 字串已在 NodeInfo；位置啟發式改從字串解析避免再查 AX
func axFrameForPath(_ n: NodeInfo) -> CGRect? {
    // "(x,y) w×h"
    let s = n.frame
    guard s.hasPrefix("("), let close = s.firstIndex(of: ")") else { return nil }
    let coords = s[s.index(after: s.startIndex)..<close].split(separator: ",")
    guard coords.count == 2,
          let x = Double(coords[0]),
          let y = Double(coords[1]) else { return nil }
    let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
    let parts = rest.split(separator: "×")
    guard parts.count == 2,
          let w = Double(parts[0]),
          let h = Double(parts[1]) else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

func findCollapseCandidates(_ nodes: [NodeInfo], elementsByPath: [String: AXUIElement]) -> [Candidate] {
    var hits: [Candidate] = []
    for n in nodes {
        guard let el = elementsByPath[n.path],
              let scored = scoreCollapseCandidate(n) else { continue }
        hits.append(Candidate(path: n.path, score: scored.score, reason: scored.reason, element: el))
    }
    return hits.sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.path < rhs.path
    }
}

func indexElements(_ element: AXUIElement, path: String, depth: Int, into map: inout [String: AXUIElement]) {
    map[path] = element
    guard depth < maxDepth else { return }
    for (i, child) in axChildren(element).enumerated() {
        indexElements(child, path: "\(path)/\(i)", depth: depth + 1, into: &map)
    }
}

func describeElementState(_ element: AXUIElement, label: String) {
    let role = axString(element, kAXRoleAttribute as String) ?? "?"
    let desc = axString(element, kAXDescriptionAttribute as String) ?? ""
    let frame = axFrame(element).map {
        "(\(Int($0.origin.x)),\(Int($0.origin.y))) \(Int($0.size.width))×\(Int($0.size.height))"
    } ?? "?"
    let actions = axActionNames(element)
    print("\(label): role=\(role) desc=\"\(desc)\" frame=\(frame) actions=\(actions)")
}

@discardableResult
func clickAtAXFrame(_ frame: CGRect) -> Bool {
    // AX frame：主螢幕左上為原點、y 向下；CGEvent：左下為原點、y 向上。
    let displayH = CGDisplayBounds(CGMainDisplayID()).height
    let point = CGPoint(x: frame.midX, y: displayH - frame.midY)
    print("  AX mid=(\(Int(frame.midX)),\(Int(frame.midY))) → Quartz=(\(Int(point.x)),\(Int(point.y))) displayH=\(Int(displayH))")

    // 先把游標移到螢幕頂讓自動隱藏的選單列現身（AutoHideMenuBarOption）
    let top = CGPoint(x: point.x, y: displayH - 1)
    if let move = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: top,
        mouseButton: .left
    ) {
        move.post(tap: .cghidEventTap)
        usleep(400_000)
    }

    guard let down = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: point,
        mouseButton: .left
    ), let up = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else { return false }
    down.post(tap: .cghidEventTap)
    usleep(40_000)
    up.post(tap: .cghidEventTap)
    return true
}

@discardableResult
func press(_ element: AXUIElement, label: String) -> AXError {
    print("=== 執行 kAXPressAction → \(label) ===")
    let actions = axActionNames(element)
    print("目標支援的 actions：\(actions)")
    if !actions.contains(kAXPressAction as String) {
        print("警告：目標不含 AXPress")
    }
    let press = AXUIElementPerformAction(element, kAXPressAction as CFString)
    print("AXUIElementPerformAction(kAXPressAction) → \(press.rawValue)")
    if press != .success {
        // MenuBarAgent 的 ≪ 在 26A428：actions=[]、Press → -25206。
        // System Events `click` 對同一按鈕有效；CGEvent 座標點擊則不一定。
        print("fallback：osascript System Events click（by description）")
        let ok = systemEventsClickCollapseButton()
        print("System Events click → \(ok ? "ok" : "failed")")
        if !ok, let f = axFrame(element), f.size.width > 0, f.size.height > 0 {
            print("fallback2：CGEvent 左鍵點擊 AX frame")
            let cgOk = clickAtAXFrame(f)
            print("CGEvent click → \(cgOk ? "ok" : "failed")")
        }
    }
    return press
}

func systemEventsClickCollapseButton() -> Bool {
    let script = """
    tell application "System Events"
      tell process "MenuBarAgent"
        repeat with b in buttons of menu bar 1
          try
            set d to description of b
            if d contains "選單列項目" or d contains "菜单栏项目" or d contains "menu bar items" then
              click b
              return "ok:" & d
            end if
          end try
        end repeat
        return "not-found"
      end tell
    end tell
    """
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        print("osascript 失敗：\(error)")
        return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    print("  osascript → \(text)")
    return text.hasPrefix("ok:") && task.terminationStatus == 0
}

func summarizeTreeDiff(before: [NodeInfo], after: [NodeInfo]) {
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
    let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    return pid_t(first)
}

func extrasMenuBar(for pid: pid_t) -> AXUIElement? {
    let appEl = AXUIElementCreateApplication(pid)
    var menuBarRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, kAXExtrasMenuBarAttribute as CFString, &menuBarRef) == .success,
       let mb = menuBarRef {
        return (mb as! AXUIElement)
    }
    var mbRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef) == .success,
       let mb = mbRef {
        return (mb as! AXUIElement)
    }
    return nil
}

// MARK: - --map：跨 App 選單列地圖

struct MappedItem {
    let owner: String
    let pid: pid_t
    let role: String
    let subrole: String
    let description: String
    let title: String
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

func collectExtrasItems(pid: pid_t, owner: String, into out: inout [MappedItem]) {
    guard let extras = extrasMenuBar(for: pid) else { return }
    func walk(_ element: AXUIElement, depth: Int) {
        let role = axString(element, kAXRoleAttribute as String) ?? "?"
        let subrole = axString(element, kAXSubroleAttribute as String) ?? ""
        let desc = axString(element, kAXDescriptionAttribute as String) ?? ""
        let title = axString(element, kAXTitleAttribute as String) ?? ""
        if let f = axFrame(element),
           role == "AXMenuBarItem" || role == "AXButton" || role == "AXMenuExtra"
            || subrole == "AXMenuExtra" || (!desc.isEmpty && depth <= 3) {
            // 只收有實際尺寸、高度像選單列的節點
            if f.size.height > 0, f.size.width > 0, f.size.height <= 40 {
                out.append(MappedItem(
                    owner: owner, pid: pid, role: role, subrole: subrole,
                    description: desc, title: title,
                    x: Int(f.origin.x), y: Int(f.origin.y),
                    w: Int(f.size.width), h: Int(f.size.height)
                ))
            }
        }
        guard depth < 4 else { return }
        for child in axChildren(element) {
            walk(child, depth: depth + 1)
        }
    }
    walk(extras, depth: 0)
}

func printMenuBarMap() {
    print("=== 選單列地圖（跨 App kAXExtrasMenuBarAttribute，依 x 排序）===")
    var items: [MappedItem] = []
    for app in NSWorkspace.shared.runningApplications {
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
        collectExtrasItems(pid: app.processIdentifier, owner: name, into: &items)
    }
    // 去重：同 owner+frame+desc
    var seen = Set<String>()
    let unique = items.filter { item in
        let key = "\(item.owner)|\(item.x)|\(item.y)|\(item.w)|\(item.h)|\(item.description)|\(item.title)"
        if seen.contains(key) { return false }
        seen.insert(key)
        return true
    }.sorted { $0.x < $1.x }

    print("共 \(unique.count) 個項目；螢幕主寬 = \(Int(NSScreen.main?.frame.width ?? 0))")
    for item in unique {
        var line = "x=\(String(format: "%4d", item.x))  \(item.w)×\(item.h)  \(item.owner)"
        line += " role=\(item.role)"
        if !item.subrole.isEmpty { line += "/\(item.subrole)" }
        if !item.description.isEmpty { line += " desc=\"\(item.description)\"" }
        if !item.title.isEmpty { line += " title=\"\(item.title)\"" }
        if item.x < 0 { line += "  ← OFFSCREEN" }
        print(line)
    }
    fflush(stdout)
}

// MARK: - Observer

final class AXObserverBox {
    var observer: AXObserver?
    let lock = NSLock()
    var events: [(String, String)] = []

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
    let app = AXUIElementCreateApplication(pid)
    for note in [kAXValueChangedNotification as String, kAXLayoutChangedNotification as String] {
        _ = AXObserverAddNotification(observer, app, note as CFString, refcon)
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    return true
}

// MARK: - Main

let mode = parseMode(CommandLine.arguments)
setbuf(stdout, nil) // 管線／tee 時立刻可見

guard AXIsProcessTrusted() else {
    fputs("""
    輔助使用未授予（AXIsProcessTrusted() == false）。
    請到「系統設定 → 隱私權與安全性 → 輔助使用」啟用目前終端機（或 Cursor），
    然後重跑。本腳本不會呼叫 AXIsProcessTrustedWithOptions prompt。

    """, stderr)
    exit(1)
}

print("AXIsProcessTrusted = true")
print("mode = \(mode)")

if case .mapOnly = mode {
    printMenuBarMap()
    print("MB-0b --map 結束。")
    exit(0)
}

guard let pid = menuBarAgentPID() else {
    fputs("找不到 MenuBarAgent（pgrep -x MenuBarAgent）。\n", stderr)
    exit(1)
}
print("MenuBarAgent pid = \(pid)")

guard let extrasBar = extrasMenuBar(for: pid) else {
    fputs("無法取得 kAXExtrasMenuBarAttribute／kAXMenuBarAttribute。\n", stderr)
    exit(1)
}
print("取得 extras menu bar")

let root = extrasBar

var before: [NodeInfo] = []
var beforeMap: [String: AXUIElement] = [:]
indexElements(root, path: "root", depth: 0, into: &beforeMap)
collectTree(root, path: "root", depth: 0, into: &before)
printTree(before, header: "按壓前")

let candidates = findCollapseCandidates(before, elementsByPath: beforeMap)
print("=== ≪ 候選（\(candidates.count)，依分數排序）===")
if candidates.isEmpty {
    print("未找到候選。請從上方樹手動辨識。")
} else {
    for (i, c) in candidates.enumerated() {
        let n = before.first { $0.path == c.path }
        print("  #\(i) score=\(c.score) path=\(c.path) reason=\(c.reason) desc=\"\(n?.description ?? "")\" frame=\(n?.frame ?? "?")")
    }
}

let box = AXObserverBox()
_ = installObservers(pid: pid, root: root, box: box)

guard let best = candidates.first else {
    print("=== 跳過按壓（無候選）===")
    print("MB-0b 結束。")
    exit(0)
}

describeElementState(best.element, label: "選定目標")
_ = press(best.element, label: "\(best.path) score=\(best.score) (\(best.reason))")

RunLoop.main.run(until: Date().addingTimeInterval(1.0))

var after: [NodeInfo] = []
collectTree(root, path: "root", depth: 0, into: &after)
printTree(after, header: "按壓後（+1s）")
describeElementState(best.element, label: "按壓後目標")
print("extras children 數：前 \(before.count) → 後 \(after.count)")
summarizeTreeDiff(before: before, after: after)

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

if case .pressAndRestore = mode {
    print("=== --restore：再按一次 ≪ 還原 ===")
    // 重新找目標（展開後 description 可能變）
    var restoreMap: [String: AXUIElement] = [:]
    var restoreNodes: [NodeInfo] = []
    indexElements(root, path: "root", depth: 0, into: &restoreMap)
    collectTree(root, path: "root", depth: 0, into: &restoreNodes)
    let restoreCandidates = findCollapseCandidates(restoreNodes, elementsByPath: restoreMap)
    if let again = restoreCandidates.first {
        describeElementState(again.element, label: "還原目標")
        _ = press(again.element, label: "\(again.path) score=\(again.score)")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        var finalNodes: [NodeInfo] = []
        collectTree(root, path: "root", depth: 0, into: &finalNodes)
        printTree(finalNodes, header: "還原後（+1s）")
        describeElementState(again.element, label: "還原後目標")
    } else {
        print("還原時找不到 ≪ 候選")
    }
}

print("MB-0b 結束。請把「找不找得到 ≪／按了有無效應／要不要輪詢」寫回 DESIGN §4.1。")
exit(0)
