#!/usr/bin/env python3
"""B7-1（限時場景：快照 → 套用 → 自動還原）自動化回歸，單機段。

走 `--fake-taps`：不需要權限、不碰真硬體，也**不動使用者的螢幕或音訊路由**。
驗的是 executor 那條真路徑（讀現值 → 展開實體 → 還原），controller 的生命
週期另由 FocusSessionControllerTests 覆蓋。

    python3 scripts/test-b7-focus.py
"""

import json
import os
import subprocess
import sys
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".b7-work")
NOTIFY = os.path.join(WORK, "notify")
BUNDLE = "com.apple.Music"

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
    subprocess.run([NOTIFY, "A", action] + ([value] if value is not None else []),
                   capture_output=True)


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


def focus(data):
    return (data or {}).get("focus", {})


def app_setting(data, key):
    return ((data or {}).get("tapEngine", {}).get("appSettings", {}).get(BUNDLE) or {}).get(key)


def gain_is(data, expected):
    """gain 存的是 Float，dump 轉 Double 會帶 float32 尾數——比對要留容差。"""
    value = app_setting(data, "gain")
    return value is not None and abs(value - expected) < 1e-6


def save_scene(name, requests):
    notify("saveScene", json.dumps(
        {"id": str(uuid.uuid4()), "name": name, "requests": requests},
        ensure_ascii=False,
    ))


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
    print("\n=== B7-1：限時場景（快照 → 套用 → 自動還原，--fake-taps）===\n", flush=True)
    proc = subprocess.Popen(
        [app, "--instance", "A", "--fake-als", "--fake-taps",
         "--state-dump", os.path.join(WORK, "dump-A.json")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    ok, _ = wait_for(lambda d: tap_state(d) == "off", 30)
    record("啟動：引擎預設關閉", ok)

    # 引擎到 active，per-app 目標才可用（動詞層對 app 目標會擋非 active）
    notify("tapFakeMode", "audio")
    notify("fakeAudioProcesses", f"Music|{BUNDLE}|1")
    notify("tapEngine", "1")
    notify("tapTick")
    ok, _ = wait_for(lambda d: tap_state(d) == "active", 15)
    record("引擎就緒", ok, f"實得 {tap_state(dump())}")

    print("\n[1] 快照 → 套用 → 到期還原", flush=True)
    # 原始狀態刻意用 **2.0 倍增益**：值 > 1 會走 snapshotString 的百分比路徑，
    # 而寫成裸數字的話收值規則會把它讀回 0.02——還原完音量剩五十分之一。
    # 這條 E2E 守的就是那個地雷在真路徑上不會踩到
    notify("appGain", f"{BUNDLE}|2.0")
    notify("appMute", f"{BUNDLE}|0")
    ok, _ = wait_for(lambda d: gain_is(d, 2.0), 10)
    record("原始狀態：增益 2.0（> 1，走百分比路徑）", ok, f"實得 {app_setting(dump(), 'gain')}")

    save_scene("專注", [
        {"verb": "set", "target": f"app:{BUNDLE}", "property": "volume", "value": "20%"},
        {"verb": "set", "target": f"app:{BUNDLE}", "property": "mute", "value": "on"},
    ])
    ok, _ = wait_for(lambda d: any(s["name"] == "專注" for s in d.get("scenes", [])), 10)
    record("建立場景「專注」", ok)

    notify("focusStart", "專注|600")
    ok, data = wait_for(lambda d: focus(d).get("scene") == "專注", 10)
    record("限時場景啟動，倒數開始", ok, f"剩餘 {focus(data).get('remaining')}")
    record("快照涵蓋兩項（音量＋靜音，由場景內容決定）",
           focus(data).get("snapshotCount") == 2, f"實得 {focus(data).get('snapshotCount')}")
    ok, _ = wait_for(lambda d: gain_is(d, 0.2) and app_setting(d, "muted") is True, 10)
    record("場景已套用：增益 20%、靜音", ok,
           f"gain={app_setting(dump(), 'gain')} muted={app_setting(dump(), 'muted')}")

    notify("focusAdvance", "600")
    ok, _ = wait_for(lambda d: focus(d).get("scene") is None, 10)
    record("倒數走完 → session 結束", ok)
    ok, data = wait_for(lambda d: gain_is(d, 2.0) and app_setting(d, "muted") is False, 10)
    record("還原到套用前：增益回 2.0、解除靜音", ok,
           f"gain={app_setting(dump(), 'gain')} muted={app_setting(dump(), 'muted')}")
    outcome = focus(data).get("lastOutcome") or {}
    record("結果記成 elapsed，還原 2 項",
           outcome.get("reason") == "elapsed" and outcome.get("restored") == 2,
           f"{outcome.get('reason')} / {outcome.get('restored')}")

    print("\n[2] 提前結束走同一條還原路", flush=True)
    notify("focusStart", "專注|600")
    ok, _ = wait_for(lambda d: gain_is(d, 0.2), 10)
    record("再次套用", ok)
    notify("focusEnd")
    ok, data = wait_for(lambda d: gain_is(d, 2.0) and focus(d).get("scene") is None, 10)
    record("提前結束 → 同樣還原", ok)
    record("結果記成 manual", (focus(data).get("lastOutcome") or {}).get("reason") == "manual")

    print("\n[3] 沒正常結束時接續倒數（不重跑場景）", flush=True)
    notify("focusStart", "專注|600")
    ok, _ = wait_for(lambda d: focus(d).get("scene") == "專注", 10)
    record("第三次套用", ok)
    notify("focusAdvance", "100")
    time.sleep(1.4)
    notify("focusRelaunch")
    ok, data = wait_for(lambda d: focus(d).get("scene") == "專注", 10)
    remaining = focus(data).get("remaining") or 0
    record("重新啟動後接續：session 仍在、剩餘約 500 秒", ok and abs(remaining - 500) < 5,
           f"剩餘 {remaining}")
    record("接續不重跑場景：值仍是場景值，沒有被套第二次",
           gain_is(dump(), 0.2), f"gain={app_setting(dump(), 'gain')}")
    notify("focusEnd")
    ok, _ = wait_for(lambda d: gain_is(d, 2.0), 10)
    record("收尾還原", ok)

    print("\n[4] 錯誤路徑", flush=True)
    notify("focusStart", "不存在的場景|600")
    time.sleep(1.6)
    error = ((dump() or {}).get("lastControl") or {}).get("error") or {}
    record("場景不存在 → targetNotFound（帶 hint）",
           error.get("code") == "targetNotFound" and bool(error.get("hint")),
           f"{error.get('code')}")
    record("失敗不會留下 session", focus(dump()).get("scene") is None)

    notify("focusStart", "專注|0")
    time.sleep(1.6)
    error = ((dump() or {}).get("lastControl") or {}).get("error") or {}
    record("時長為 0 → badValue", error.get("code") == "badValue", f"{error.get('code')}")

    notify("appReset", BUNDLE)
    notify("tapEngine", "0")
    ok, _ = wait_for(lambda d: tap_state(d) == "off", 10)
    record("收尾回 off", ok)

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
