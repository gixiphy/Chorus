#!/usr/bin/env python3
"""B6-1（tap 引擎基礎設施）自動化回歸：走 --fake-taps，不需權限、不碰真硬體。

    python3 scripts/test-b6-taps.py
"""

import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".b6-work")
NOTIFY = os.path.join(WORK, "notify")

proc = None
results = []


def find_debug_app():
    newest, newest_time = None, 0
    for entry in os.listdir(DERIVED):
        if not entry.startswith("Chorus-"):
            continue
        candidate = os.path.join(DERIVED, entry, "Build/Products/Debug/Chorus.app/Contents/MacOS/Chorus")
        if os.path.exists(candidate) and os.path.getmtime(candidate) > newest_time:
            newest, newest_time = candidate, os.path.getmtime(candidate)
    if not newest:
        sys.exit("找不到 Debug build")
    return newest


def notify(action, value=None):
    subprocess.run([NOTIFY, "A", action] + ([value] if value else []), capture_output=True)


def dump():
    try:
        with open(os.path.join(WORK, "dump-A.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def wait_for(pred, timeout=15):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        data = dump()
        if data:
            last = data
            try:
                if pred(data):
                    return True, data
            except Exception:
                pass
        time.sleep(0.4)
    return False, last


def record(name, ok, detail=""):
    results.append((name, ok))
    print(("  ✅ " if ok else "  ❌ ") + name + (f"  — {detail}" if detail else ""), flush=True)


def tap_state(data):
    return (data or {}).get("tapEngine", {}).get("state")


def cleanup():
    if proc:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
    subprocess.run(["defaults", "delete", "com.hermes.Chorus.instance-A"], capture_output=True)
    subprocess.run(["rm", "-rf", os.path.expanduser("~/Library/Application Support/Chorus/instance-A")],
                   capture_output=True)
    subprocess.run(["rm", "-rf", WORK], capture_output=True)


def main():
    global proc
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["swiftc", "-o", NOTIFY, os.path.join(REPO, "scripts", "notify.swift")], check=True)
    subprocess.run(["pkill", "-f", "instance A"], capture_output=True)
    time.sleep(1)

    app = find_debug_app()
    print("\n=== B6-1：tap 引擎（--fake-taps）===\n", flush=True)
    proc = subprocess.Popen(
        [app, "--instance", "A", "--fake-als", "--fake-taps",
         "--state-dump", os.path.join(WORK, "dump-A.json")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    ok, _ = wait_for(lambda d: tap_state(d) == "off", 30)
    record("啟動：引擎預設關閉（權限功能紀律）", ok)

    print("\n[1] 權限被拒的形狀（發聲卻全零 → denied）", flush=True)
    notify("tapFakeMode", "zeros")
    notify("fakeAudioProcesses", "Music|com.apple.Music|1")
    notify("tapEngine", "1")
    ok, _ = wait_for(lambda d: tap_state(d) == "probing", 10)
    record("啟用後進入探測", ok)
    notify("tapTick"); notify("tapTick")
    ok, state = wait_for(lambda d: tap_state(d) == "denied", 10)
    record("兩格判讀後 → denied（不靠錯誤碼，靠靜默偵測）", ok, f"實得 {tap_state(state)}")

    print("\n[2] 沒有來源發聲時不誤判", flush=True)
    notify("tapEngine", "0")
    notify("fakeAudioProcesses", "Music|com.apple.Music|0")
    notify("tapEngine", "1")
    for _ in range(4):
        notify("tapTick")
    time.sleep(1.5)
    record("多格全零但無人發聲 → 維持 probing", tap_state(dump()) == "probing",
           f"實得 {tap_state(dump())}")

    print("\n[3] 權限正常 → active，per-app session 生命週期", flush=True)
    notify("tapEngine", "0")
    notify("tapFakeMode", "audio")
    notify("fakeAudioProcesses", "Music|com.apple.Music|1;Safari|com.apple.Safari|0")
    notify("tapEngine", "1")
    notify("tapTick")
    ok, _ = wait_for(lambda d: tap_state(d) == "active", 10)
    record("非零樣本 → active", ok)

    notify("tapApp", "com.apple.Music")
    ok, state = wait_for(lambda d: d.get("tapEngine", {}).get("tapped") == ["com.apple.Music"], 10)
    record("tap 指定 App", ok)
    notify("untapApp", "com.apple.Music")
    ok, _ = wait_for(lambda d: d.get("tapEngine", {}).get("tapped") == [], 10)
    record("untap 收掉 session", ok)

    notify("tapApp", "com.hermes.Chorus")
    time.sleep(1.5)
    record("拒絕 tap 自己（回音紀律）", dump().get("tapEngine", {}).get("tapped") == [])

    notify("tapEngine", "0")
    ok, _ = wait_for(lambda d: tap_state(d) == "off", 10)
    record("停用回 off", ok)

    print("\n=== 總結 ===", flush=True)
    passed = sum(1 for _, ok in results if ok)
    print(f"  {passed}/{len(results)} 通過\n", flush=True)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    code = 1
    try:
        code = main() or 0
    finally:
        cleanup()
    sys.exit(code)
