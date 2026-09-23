#!/usr/bin/env python3
"""把 Chorus 的診斷 JSON（diagnostics/*.json）或系統 .ips 用 dSYM 符號化。

    python3 scripts/symbolicate-diagnostics.py ~/Library/Logs/Chorus/diagnostics/20260923-032744-000-crash.json \
        --dsym dist/dsyms/Chorus-1.11.0-b116.dSYMs.zip
    python3 scripts/symbolicate-diagnostics.py ~/Library/Logs/DiagnosticReports/Chorus-2026-09-23-112744.ips \
        --dsym dist/dsyms/

對得上 dSYM UUID 的格才符號化，其餘原樣印出（系統框架沒有 dSYM 是正常的）。
只用標準庫；需要 Xcode command line tools 的 atos 與 dwarfdump。
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import zipfile


def load_dsym_index(path):
    """uuid(小寫) → (DWARF 檔路徑, arch)。path 可以是 zip、.dSYM 或含 .dSYM 的目錄。"""
    if path.endswith(".zip"):
        extracted = tempfile.mkdtemp(prefix="chorus-dsym-")
        with zipfile.ZipFile(path) as archive:
            archive.extractall(extracted)
        path = extracted
    index = {}
    for root, dirs, _ in os.walk(path):
        for name in dirs:
            if not name.endswith(".dSYM"):
                continue
            dwarf_dir = os.path.join(root, name, "Contents", "Resources", "DWARF")
            if not os.path.isdir(dwarf_dir):
                continue
            for binary in os.listdir(dwarf_dir):
                dwarf = os.path.join(dwarf_dir, binary)
                out = subprocess.run(["dwarfdump", "--uuid", dwarf], capture_output=True, text=True).stdout
                # 形如：UUID: 9F8E…-… (arm64) /path
                for line in out.splitlines():
                    parts = line.split()
                    if len(parts) >= 3 and parts[0] == "UUID:":
                        index[parts[1].lower()] = (dwarf, parts[2].strip("()"))
    return index


def frames_from_metrickit(diagnostic):
    """每條 callStack 攤平成 [(binaryName, uuid, offset)]，root 在前、crash 點在後。"""
    stacks = []
    for stack in diagnostic.get("callStackTree", {}).get("callStacks", []):
        chain = []
        level = stack.get("callStackRootFrames", [])
        while level:
            frame = level[0]
            chain.append((frame.get("binaryName", "?"), str(frame.get("binaryUUID", "")).lower(),
                          int(frame.get("offsetIntoBinaryTextSegment", 0))))
            level = frame.get("subFrames", [])
        stacks.append((bool(stack.get("threadAttributed")), chain))
    return stacks


def frames_from_ips(text):
    header, _, body = text.partition("\n")
    report = json.loads(body)
    images = report.get("usedImages", [])
    faulting = report.get("faultingThread", 0)
    stacks = []
    for index, thread in enumerate(report.get("threads", [])):
        chain = []
        for frame in thread.get("frames", []):
            image = images[frame["imageIndex"]] if 0 <= frame.get("imageIndex", -1) < len(images) else {}
            chain.append((image.get("name", "?"), str(image.get("uuid", "")).lower(), int(frame.get("imageOffset", 0))))
        stacks.append((index == faulting, chain))
    return stacks


def symbolicate(stacks, index):
    for attributed, chain in stacks:
        print("=== thread" + (" (crashed)" if attributed else ""))
        # crash 點在前，跟 Xcode / Console 的排法一致
        for number, (name, uuid, offset) in enumerate(reversed(chain)):
            entry = index.get(uuid)
            if entry is None:
                print(f"#{number:<3} {name:<28} +0x{offset:x}")
                continue
            dwarf, arch = entry
            out = subprocess.run(["atos", "-o", dwarf, "-arch", arch, "-offset", f"0x{offset:x}"],
                                 capture_output=True, text=True).stdout.strip()
            print(f"#{number:<3} {name:<28} +0x{offset:x}  {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", help="diagnostics/*.json 或 .ips")
    parser.add_argument("--dsym", required=True, help="dSYMs zip、.dSYM 或含 .dSYM 的目錄")
    args = parser.parse_args()

    index = load_dsym_index(args.dsym)
    if not index:
        print("找不到任何 dSYM UUID", file=sys.stderr)
        return 1
    with open(args.report, encoding="utf-8") as handle:
        text = handle.read()

    if args.report.endswith(".ips"):
        stacks = frames_from_ips(text)
    else:
        envelope = json.loads(text)
        diagnostic = envelope.get("diagnostic") or envelope
        summary = envelope.get("summary", {})
        if summary:
            print(f"{summary.get('kind')} {summary.get('occurredAt')} build={summary.get('appVersion')} {summary.get('exception') or ''}")
        if not diagnostic.get("callStackTree"):
            print("這份沒有 callStackTree（.ips 摘要或 uncleanExit）；請改拿 sourcePath 指到的 .ips", file=sys.stderr)
            return 1
        stacks = frames_from_metrickit(diagnostic)
    symbolicate(stacks, index)
    return 0


if __name__ == "__main__":
    sys.exit(main())
