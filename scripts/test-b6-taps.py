#!/usr/bin/env python3
"""B6-1／B6-2（tap 引擎＋逐 App 音量）自動化回歸：走 --fake-taps，
不需權限、不碰真硬體。

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


def tapped(data):
    return (data or {}).get("tapEngine", {}).get("tapped")


def app_settings(data):
    return (data or {}).get("tapEngine", {}).get("appSettings", {})


def app_gain_is(data, bundle, expected):
    """gain 是 Float 存的，dump 轉 Double 會帶 float32 的尾數——比對要留容差。"""
    value = app_settings(data).get(bundle, {}).get("gain")
    return value is not None and abs(value - expected) < 1e-6


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
    print("\n=== B6-1／B6-2：tap 引擎與逐 App 音量（--fake-taps）===\n", flush=True)
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

    record("active 時沒有任何 tap（沒調整就不建，DESIGN §2.3 規則 2）",
           tapped(dump()) == [])

    print("\n[4] B6-2：設定驅動的 session 對帳", flush=True)
    notify("appGain", "com.apple.Music|0.4")
    ok, _ = wait_for(lambda d: tapped(d) == ["com.apple.Music"], 10)
    record("調音量 → 自動建 session", ok)
    ok, _ = wait_for(lambda d: app_gain_is(d, "com.apple.Music", 0.4), 5)
    record("設定持久化（bundle id 為鍵）", ok)

    notify("appGain", "com.apple.Music|1")
    ok, _ = wait_for(lambda d: tapped(d) == [], 10)
    record("音量歸零回 100% → session 自動收掉", ok)

    notify("appMute", "com.apple.Safari|1")
    ok, _ = wait_for(lambda d: tapped(d) == ["com.apple.Safari"], 10)
    record("靜音也是一種調整 → 建 session", ok)

    notify("appGain", "com.apple.Music|2.5")
    ok, _ = wait_for(lambda d: tapped(d) == ["com.apple.Music", "com.apple.Safari"], 10)
    record("多個 App 各自一條 session", ok)

    notify("appGain", "com.apple.Music|99")
    ok, _ = wait_for(lambda d: app_gain_is(d, "com.apple.Music", 4.0), 5)
    record("gain 夾在 0–4x", ok)

    notify("appReset", "com.apple.Music")
    notify("appReset", "com.apple.Safari")
    ok, _ = wait_for(lambda d: tapped(d) == [] and app_settings(d) == {}, 10)
    record("reset 回到完全原生路徑", ok)

    # DESIGN §3.2 責任矩陣：per-app 增益絕不碰裝置音量（兩層相乘、各管一層）。
    # 這裡只驗「不互相污染」——50%×50%=25% 的實聽檢查點在 ACCEPTANCE
    before = {d["uid"]: (d["volume"], d["muted"]) for d in dump().get("audioDevices", [])}
    notify("appGain", "com.apple.Music|0.5")
    notify("appMute", "com.apple.Music|1")
    time.sleep(1.5)
    after = {d["uid"]: (d["volume"], d["muted"]) for d in dump().get("audioDevices", [])}
    record("per-app 調整不動裝置音量／靜音（責任矩陣 §3.2）", before == after)
    notify("appReset", "com.apple.Music")
    ok, _ = wait_for(lambda d: tapped(d) == [], 10)
    record("收掉後裝置層仍不受影響", ok and before == {
        d["uid"]: (d["volume"], d["muted"]) for d in dump().get("audioDevices", [])})

    notify("appGain", "com.hermes.Chorus|0.5")
    time.sleep(1.5)
    record("拒絕 tap 自己（回音紀律）", tapped(dump()) == [])
    notify("appReset", "com.hermes.Chorus")

    print("\n[5] 停用與重啟後恢復", flush=True)
    notify("appGain", "com.apple.Music|0.3")
    ok, _ = wait_for(lambda d: tapped(d) == ["com.apple.Music"], 10)
    record("重新調一個 App", ok)

    notify("tapEngine", "0")
    ok, _ = wait_for(lambda d: tap_state(d) == "off" and tapped(d) == [], 10)
    record("停用回 off、session 全收", ok)

    notify("tapEngine", "1")
    notify("tapTick")
    ok, _ = wait_for(lambda d: tap_state(d) == "active" and tapped(d) == ["com.apple.Music"], 10)
    record("重新啟用 → 依設定自動恢復（App 重啟走同一條路）", ok)

    notify("appReset", "com.apple.Music")
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
