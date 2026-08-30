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
    # `is not None` 而不是真值判斷：空字串是有意義的值（「拆掉 EQ」、
    # 「跟隨系統預設」都靠它），用真值判斷會把它整個吞掉
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


def tapped(data):
    return (data or {}).get("tapEngine", {}).get("tapped")


def control(request):
    """送出一個 ControlRequest 走完整動詞層（驗證 → 解析 → 執行），回 lastControl。"""
    notify("control", json.dumps(request, ensure_ascii=False, sort_keys=True))
    time.sleep(1.6)  # state dump 每秒寫一次
    return (dump() or {}).get("lastControl")


def device_tap(data):
    return (data or {}).get("tapEngine", {}).get("deviceTap")


AUTOEQ_SAMPLE = (
    "Preamp: -6.8 dB\n"
    "Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70\n"
    "Filter 2: ON PK Fc 1050 Hz Gain -2.4 dB Q 1.20\n"
    "Filter 3: ON HSC Fc 10000 Hz Gain -1.2 dB Q 0.70"
)


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

    print("\n[5] B6-3：逐 App 路由", flush=True)
    notify("fakeOutputDevices", "fake-output-uid;fake-headphones")
    notify("appRoute", "com.apple.Music|fake-headphones")
    ok, _ = wait_for(
        lambda d: app_settings(d).get("com.apple.Music", {}).get("activeOutput") == "fake-headphones", 10)
    record("指定輸出裝置 → session 建在該裝置上", ok)
    record("只指定路由也算調整（有 session）", tapped(dump()) == ["com.apple.Music"])

    notify("fakeOutputDevices", "fake-output-uid")  # 耳機拔掉
    ok, _ = wait_for(
        lambda d: app_settings(d).get("com.apple.Music", {}).get("activeOutput") == "fake-output-uid", 10)
    record("指定裝置被拔掉 → 暫時退回系統預設", ok)
    record("設定沒有被清掉（插回去要接得回來）",
           app_settings(dump()).get("com.apple.Music", {}).get("output") == "fake-headphones")

    notify("fakeOutputDevices", "fake-output-uid;fake-headphones")  # 插回去
    ok, _ = wait_for(
        lambda d: app_settings(d).get("com.apple.Music", {}).get("activeOutput") == "fake-headphones", 10)
    record("裝置插回來 → session 自動接回原目標", ok)

    notify("appGain", "com.apple.Music|0.5")
    notify("appRoute", "com.apple.Music|")
    ok, _ = wait_for(
        lambda d: app_settings(d).get("com.apple.Music", {}).get("activeOutput") == "fake-output-uid", 10)
    record("改回跟隨系統預設（其他調整還在，session 留著）", ok)

    notify("appGain", "com.apple.Music|1")
    ok, _ = wait_for(lambda d: tapped(d) == [], 10)
    record("路由與音量都歸零 → 完全回到原生路徑", ok)
    notify("appReset", "com.apple.Music")

    print("\n[6] B6-4：裝置級軟體音量（三後端矩陣第三條）", flush=True)
    notify("softwareVolume", "fake-headphones|0.5|0")
    ok, _ = wait_for(lambda d: device_tap(d) == "fake-headphones", 10)
    record("開啟 → 一條全域 session 跑在該裝置上", ok)

    notify("softwareVolume", "gone-uid|0.5|0")
    ok, _ = wait_for(lambda d: device_tap(d) is None, 10)
    record("目標裝置不在 → 不建（不在錯的裝置上默默衰減）", ok)

    notify("softwareVolume", "fake-headphones|0.5|0")
    ok, _ = wait_for(lambda d: device_tap(d) == "fake-headphones", 10)
    record("重新指定回存在的裝置", ok)

    print("\n[7] B6-5：裝置級等化（與軟體音量共用同一條 tap）", flush=True)
    notify("deviceEQ", AUTOEQ_SAMPLE)
    ok, _ = wait_for(lambda d: d.get("tapEngine", {}).get("deviceEQBands") == 3, 10)
    record("貼上 AutoEq 校正檔 → 解析出三段", ok)
    ok, _ = wait_for(
        lambda d: abs(d.get("tapEngine", {}).get("deviceEQPreamp", 0) + 6.8) < 1e-6, 5)
    record("套用檔案給的 negative preamp（-6.8 dB）", ok)
    record("EQ 與軟體音量共用同一條 tap（沒有第二條）", device_tap(dump()) == "fake-headphones")

    notify("deviceEQ", "")
    ok, _ = wait_for(lambda d: d.get("tapEngine", {}).get("deviceEQBands") == 0, 10)
    record("拆掉 EQ，軟體音量的 tap 留著", ok and device_tap(dump()) == "fake-headphones")

    notify("softwareVolume", "||0")
    ok, _ = wait_for(lambda d: device_tap(d) is None, 10)
    record("兩者都關 → 一個 tap 都不留", ok)

    print("\n[8] B6-6：動詞層的 app: 定位（跨機遙控走同一條）", flush=True)
    response = control({"verb": "set", "target": "app:com.apple.Music",
                        "property": "volume", "value": "40%"})
    record("set app:<bundle> volume 走到引擎",
           (response or {}).get("ok") is True
           and app_gain_is(dump(), "com.apple.Music", 0.4))

    response = control({"verb": "set", "target": "app:com.apple.Music",
                        "property": "volume", "value": "250%"})
    record("per-app 收得下 250%（裝置音量的 0–1 上限不套在這裡）",
           app_gain_is(dump(), "com.apple.Music", 2.5))

    response = control({"verb": "toggle", "target": "appLike:Music", "property": "mute"})
    record("appLike 以顯示名稱比對 → toggle mute",
           app_settings(dump()).get("com.apple.Music", {}).get("muted") is True)

    response = control({"verb": "get", "target": "app:com.apple.Music", "property": "volume"})
    values = [r.get("value") for r in (response or {}).get("results", [])]
    record("get 回讀現值", bool(values) and abs(values[0] - 2.5) < 1e-6)

    response = control({"verb": "get", "target": "allApps"})
    bundles = sorted(r.get("value") for r in (response or {}).get("results", [])
                     if r.get("property") == "bundleID")
    record("allApps 列舉（遙控端不必猜 bundle id）",
           bundles == ["com.apple.Music", "com.apple.Safari"])

    response = control({"verb": "set", "target": "appLike:Photoshop",
                        "property": "volume", "value": "40%"})
    error = (response or {}).get("error") or {}
    record("找不到的 App → targetNotFound，hint 列出可選的",
           error.get("code") == "targetNotFound" and "Music" in (error.get("hint") or ""))

    response = control({"verb": "set", "target": "app:com.apple.Music",
                        "property": "brightness", "value": "50%"})
    record("app 不吃亮度（相容性矩陣擋在驗證階段）",
           ((response or {}).get("error") or {}).get("code") == "targetKindMismatch")

    notify("appReset", "com.apple.Music")
    notify("appReset", "com.apple.Safari")

    # 歸組（2026-08-30 bug 批）：helper 併入主 App、daemon 與 Apple 的
    # accessory 不列——選單塞滿 audiomxd／assistantd／helper 的那張截圖
    # helper 刻意標 accessory——Chromium/Electron 的 helper 帶 LSUIElement，
    # 系統就是這樣回報的（2026-08-30 實機截圖的回歸）
    notify("fakeAudioProcesses",
           "Music|com.apple.Music|0|regular;"
           "Vivaldi|com.vivaldi.Vivaldi|0|regular;"
           "helper|com.vivaldi.Vivaldi.helper|1|accessory;"
           "audiomxd|com.apple.audio.audiomxd|1|other;"
           "ControlCenter|com.apple.controlcenter|1|accessory")
    response = control({"verb": "get", "target": "allApps"})
    bundles = sorted(r.get("value") for r in (response or {}).get("results", [])
                     if r.get("property") == "bundleID")
    record("歸組：helper 併入主 App、daemon 與 Apple accessory 不列",
           bundles == ["com.apple.Music", "com.vivaldi.Vivaldi"])
    notify("fakeAudioProcesses", "Music|com.apple.Music|1;Safari|com.apple.Safari|0")

    print("\n[9] 權限未到手時 app: 整組不可用（降級表）", flush=True)
    notify("tapEngine", "0")
    ok, _ = wait_for(lambda d: tap_state(d) == "off", 10)
    response = control({"verb": "set", "target": "app:com.apple.Music",
                        "property": "volume", "value": "40%"})
    error = (response or {}).get("error") or {}
    record("回 unsupported 並說明怎麼開啟",
           ok and error.get("code") == "unsupported" and "App 音訊接管" in (error.get("message") or ""))

    response = control({"verb": "get", "target": "allDevices"})
    record("同一時間裝置音量完全不受影響（降級表最後兩列）",
           (response or {}).get("ok") is True)

    notify("tapEngine", "1")
    notify("tapTick")
    ok, _ = wait_for(lambda d: tap_state(d) == "active", 10)
    record("重新啟用回 active", ok)

    print("\n[10] B6-7：提示音音量走動詞層（場景要用到）", flush=True)
    original = (dump() or {}).get("alertVolume")
    response = control({"verb": "get", "target": "system", "property": "alertVolume"})
    values = [r.get("value") for r in (response or {}).get("results", [])]
    record("get alertVolume 讀得到系統現值",
           bool(values) and original is not None and abs(values[0] - original) < 1e-6)

    # 這是 NSGlobalDomain 的系統設定——測完一定要還原，別把使用者的機器改掉
    try:
        response = control({"verb": "set", "target": "system",
                            "property": "alertVolume", "value": "30%"})
        ok, _ = wait_for(lambda d: abs(d.get("alertVolume", -1) - 0.3) < 1e-6, 10)
        record("set alertVolume 生效", ok and (response or {}).get("ok") is True)
        record("與輸出音量分開（裝置音量沒被動到）",
               (control({"verb": "get", "target": "allDevices"}) or {}).get("ok") is True)
    finally:
        if original is not None:
            control({"verb": "set", "target": "system", "property": "alertVolume",
                     "value": f"{original}"})
    ok, _ = wait_for(lambda d: abs(d.get("alertVolume", -1) - original) < 0.01, 10)
    record("測完還原使用者原本的提示音音量", ok)

    print("\n[11] 停用與重啟後恢復", flush=True)
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
