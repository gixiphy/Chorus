#!/usr/bin/env python3
"""把 build 抽出的字串同步進 String Catalog（取代「在 Xcode IDE 裡按 build」）。

Xcode 只有在 IDE 內建置時才會把 `SWIFT_EMIT_LOC_STRINGS` 產出的 `.stringsdata`
寫回 `.xcstrings`；`xcodebuild` 不會。這支腳本補上那一步，讓
build → sync → translate 三段都能在終端機／CI 跑。

    xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Debug build
    scripts/strings-sync.py            # 自動找最新的 DerivedData
    scripts/strings-sync.py --intermediates <…/Chorus.build/Debug/Chorus.build>

行為對齊 Xcode：
- 新 key 加進 catalog，`extractionState` 省略（＝自動抽取）。
- 程式裡已不存在的 key 標 `extractionState: stale`，翻譯保留，不刪。
- 只動 `Localizable` 表；手動加的 key（`extractionState: manual`）不碰。
- `InfoPlist.xcstrings` 的 key 是 Info.plist 的 key 名，原文取自 project.yml
  寫進 Info.plist 的值。
- ChorusCore 套件沒有自己的 catalog（CLI 也連結它，Bundle.module 在命令列工具裡
  會直接 crash），它的 `String(localized:)` 走 `Bundle.main`，key 由這支腳本用
  正規式從套件原始碼抽出、併進 App 的 Localizable。**套件裡的插值一律視為 `%@`**，
  所以那邊只能插 String；要插整數請先轉成字串。
"""

import argparse
import glob
import json
import os
import plistlib
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE_SOURCES = os.path.join(ROOT, "Packages", "ChorusCore", "Sources")
RESOURCES = os.path.join(ROOT, "Chorus", "Resources")
LOCALIZABLE = os.path.join(RESOURCES, "Localizable.xcstrings")
INFOPLIST = os.path.join(RESOURCES, "InfoPlist.xcstrings")
INFO_PLIST_SOURCE = os.path.join(ROOT, "Chorus", "Support", "Info.plist")

# Info.plist 裡會被系統顯示給使用者看的 key
INFOPLIST_KEYS = [
    "NSLocalNetworkUsageDescription",
    "NSAudioCaptureUsageDescription",
]


def load_catalog(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_catalog(path, catalog):
    # Xcode 的序列化：兩格縮排、key 排序、冒號前有空格。保持一致，diff 才乾淨。
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True)
    text = text.replace('": ', '" : ')
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + "\n")


def find_intermediates():
    pattern = os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/Chorus-*/Build/Intermediates.noindex/"
        "Chorus.build/Debug/Chorus.build"
    )
    candidates = glob.glob(pattern)
    if not candidates:
        sys.exit("找不到 DerivedData 裡的 Chorus.build；先跑一次 xcodebuild")
    return max(candidates, key=os.path.getmtime)


def collect_keys(intermediates):
    """回傳 {table: {key: comment}}。"""
    tables = {}
    files = glob.glob(os.path.join(intermediates, "**", "*.stringsdata"), recursive=True)
    if not files:
        sys.exit(f"{intermediates} 底下沒有 .stringsdata；確認 SWIFT_EMIT_LOC_STRINGS=YES")
    for path in files:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for table, entries in data.get("tables", {}).items():
            bucket = tables.setdefault(table, {})
            for entry in entries:
                key = entry["key"]
                comment = entry.get("comment", "")
                if key not in bucket or (comment and not bucket[key]):
                    bucket[key] = comment
    return tables


def scan_literal(text, start):
    """從 text[start]（開頭引號之後）掃到字串結尾，回傳 (catalog key, 結尾 index)。
    `\\(…)` 插值換成 %@（括號可巢狀），`\\"` 與 `\\\\` 還原成字元。"""
    out = []
    i = start
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            nxt = text[i + 1]
            if nxt == "(":
                depth = 1
                i += 2
                while depth and i < len(text):
                    if text[i] == "(":
                        depth += 1
                    elif text[i] == ")":
                        depth -= 1
                    elif text[i] == '"':  # 插值內的字串字面值：整段跳過
                        i += 1
                        while text[i] != '"':
                            i += 2 if text[i] == "\\" else 1
                    i += 1
                out.append("%@")
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            i += 2
            continue
        if ch == '"':
            return "".join(out), i
        out.append(ch)
        i += 1
    raise ValueError("unterminated string literal")


def collect_core_keys():
    """ChorusCore 原始碼裡的 `String(localized: "…")` → {key: comment}。"""
    keys = {}
    marker = 'String(localized: "'
    for root, _, files in os.walk(CORE_SOURCES):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            pos = text.find(marker)
            while pos != -1:
                key, end = scan_literal(text, pos + len(marker))
                keys.setdefault(key, "")
                pos = text.find(marker, end)
    return keys


def sync_localizable(keys):
    catalog = load_catalog(LOCALIZABLE)
    strings = catalog.setdefault("strings", {})
    added = revived = staled = 0

    for key, comment in keys.items():
        entry = strings.get(key)
        if entry is None:
            entry = {}
            if comment:
                entry["comment"] = comment
            strings[key] = entry
            added += 1
        else:
            if entry.get("extractionState") == "stale":
                del entry["extractionState"]
                revived += 1
            if comment and not entry.get("comment"):
                entry["comment"] = comment

    for key, entry in strings.items():
        if key in keys or entry.get("extractionState") == "manual":
            continue
        if entry.get("extractionState") != "stale":
            entry["extractionState"] = "stale"
            staled += 1

    save_catalog(LOCALIZABLE, catalog)
    return added, revived, staled, len(strings)


def sync_infoplist():
    with open(INFO_PLIST_SOURCE, "rb") as f:
        plist = plistlib.load(f)
    catalog = load_catalog(INFOPLIST)
    strings = catalog.setdefault("strings", {})
    source_lang = catalog.get("sourceLanguage", "zh-Hant")
    added = 0
    for key in INFOPLIST_KEYS:
        value = plist.get(key)
        if not value:
            continue
        entry = strings.setdefault(key, {})
        localizations = entry.setdefault("localizations", {})
        unit = localizations.setdefault(source_lang, {}).setdefault("stringUnit", {})
        if unit.get("value") != value:
            unit["value"] = value
            unit["state"] = "translated"
            added += 1
    save_catalog(INFOPLIST, catalog)
    return added


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--intermediates", help="…/Chorus.build/Debug/Chorus.build 的路徑")
    args = parser.parse_args()

    intermediates = args.intermediates or find_intermediates()
    tables = collect_keys(intermediates)
    localizable = tables.get("Localizable", {})
    core = collect_core_keys()
    for key, comment in core.items():
        localizable.setdefault(key, comment)
    added, revived, staled, total = sync_localizable(localizable)
    print(f"Localizable: 新增 {added}、復活 {revived}、標 stale {staled}，共 {total} 個 key（ChorusCore 抽到 {len(core)}）")
    for table in tables:
        if table != "Localizable":
            print(f"（略過表 {table}：{len(tables[table])} 個 key，目前只同步 Localizable）", file=sys.stderr)
    plist_updated = sync_infoplist()
    print(f"InfoPlist: 更新原文 {plist_updated} 個 key")


if __name__ == "__main__":
    main()
