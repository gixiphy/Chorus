#!/usr/bin/env python3
"""B4-1（M10 動詞層）自動化回歸：走 TestHooks 的 control 入口，
不需要 HTTP server、token 或任何權限。

    python3 scripts/test-b4-automation.py
"""

import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".b4-work")
NOTIFY = os.path.join(WORK, "notify")
PROD_APP = "/Applications/Chorus.app"

procs = {}
results = []
prod_was_running = False


def find_debug_app():
    newest, newest_time = None, 0
    for entry in os.listdir(DERIVED):
        if not entry.startswith("Chorus-"):
            continue
        candidate = os.path.join(DERIVED, entry, "Build/Products/Debug/Chorus.app/Contents/MacOS/Chorus")
        if os.path.exists(candidate) and os.path.getmtime(candidate) > newest_time:
            newest, newest_time = candidate, os.path.getmtime(candidate)
    if not newest:
        sys.exit("找不到 Debug build。先執行："
                 "xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Debug build")
    return newest


APP = find_debug_app()


def build_notify():
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(REPO, "scripts", "notify.swift")
    if not os.path.exists(NOTIFY) or os.path.getmtime(src) > os.path.getmtime(NOTIFY):
        subprocess.run(["swiftc", "-o", NOTIFY, src], check=True)


def notify(inst, action, value=None):
    subprocess.run([NOTIFY, inst, action] + ([value] if value else []), capture_output=True)


def dump(inst="A"):
    try:
        with open(os.path.join(WORK, f"dump-{inst}.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def launch(inst, listen_port=None, pair_port=None):
    args = [APP, "--instance", inst, "--fake-als", "--state-dump", os.path.join(WORK, f"dump-{inst}.json")]
    if listen_port:
        args += ["--listen-port", str(listen_port), "--pair-port", str(pair_port)]
    procs[inst] = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_for(pred, inst="A", timeout=15):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        data = dump(inst)
        if data:
            last = data
            try:
                if pred(data):
                    return True, data
            except Exception:
                pass
        time.sleep(0.3)
    return False, last


def control(request, inst="A"):
    """送出一個 ControlRequest，回傳 lastControl 回應。"""
    marker = json.dumps(request, ensure_ascii=False, sort_keys=True)
    notify(inst, "control", marker)
    # state dump 每秒寫一次；等到 lastControl 反映這次請求
    time.sleep(1.6)
    data = dump(inst) or {}
    return data.get("lastControl")


def record(name, ok, detail=""):
    results.append((name, ok))
    print(("  ✅ " if ok else "  ❌ ") + name + (f"  — {detail}" if detail else ""), flush=True)


def stop_production_app():
    global prod_was_running
    running = subprocess.run(["pgrep", "-f", f"{PROD_APP}/Contents/MacOS/Chorus"], capture_output=True)
    prod_was_running = running.returncode == 0
    if prod_was_running:
        print("  （暫時結束正式 Chorus）", flush=True)
        subprocess.run(["osascript", "-e", 'quit app "Chorus"'], capture_output=True)
        time.sleep(2)
        subprocess.run(["pkill", "-x", "Chorus"], capture_output=True)
        time.sleep(1)


def cleanup():
    for inst in list(procs):
        notify(inst, "restoreAllDisplayPower")
    time.sleep(1)
    for inst in list(procs):
        procs[inst].terminate()
        try:
            procs[inst].wait(timeout=5)
        except Exception:
            procs[inst].kill()
    for inst in ("A", "B"):
        subprocess.run(["defaults", "delete", f"com.hermes.Chorus.instance-{inst}"], capture_output=True)
        subprocess.run(["security", "delete-generic-password", "-s", f"com.hermes.Chorus.instance-{inst}"],
                       capture_output=True)
        subprocess.run(["rm", "-rf", os.path.expanduser(f"~/Library/Application Support/Chorus/instance-{inst}")],
                       capture_output=True)
    subprocess.run(["rm", "-rf", WORK], capture_output=True)
    if prod_was_running:
        subprocess.run(["open", PROD_APP], capture_output=True)
        print("  （正式 Chorus 已重新啟動）", flush=True)


def value_for(response, prop):
    for item in (response or {}).get("results") or []:
        if item.get("property") == prop:
            return item.get("value")
    return None


def main():
    build_notify()
    stop_production_app()

    print("\n=== B4-1（M10）動詞層 ===\n", flush=True)
    launch("A", 47700, 47800)
    ok, state = wait_for(lambda d: len(d.get("displays", [])) > 0, timeout=30)
    if not ok:
        record("實例啟動", False)
        return
    displays = state["displays"]
    display_name = displays[-1]["name"]
    display_uuid = displays[-1]["uuid"]
    record("實例啟動並列舉顯示器", True, f"{len(displays)} 台")

    print("\n[測試 1] get — 列舉入口（省略 property）", flush=True)
    response = control({"verb": "get", "target": "allDisplays"})
    ok = bool(response and response.get("ok"))
    record("get allDisplays 成功", ok)
    props = {item.get("property") for item in (response or {}).get("results") or []}
    record("回傳含 brightness／power／uuid／backend／powerLayer",
           {"brightness", "power", "uuid", "backend", "powerLayer"} <= props,
           f"實得 {sorted(props)}")

    print("\n[測試 2] set — 三種值寫法都收", flush=True)
    for text, expected in [("0.4", 0.4), ("70%", 0.7), ("55", 0.55)]:
        response = control({"verb": "set", "target": f"displayUUID:{display_uuid}",
                            "property": "brightness", "value": text})
        got = value_for(response, "brightness")
        record(f"set brightness {text} → {expected}",
               got is not None and abs(got - expected) < 0.001, f"實得 {got}")

    print("\n[測試 3] set — 相對增減疊在現值上", flush=True)
    control({"verb": "set", "target": f"displayUUID:{display_uuid}",
             "property": "brightness", "value": "50%"})
    response = control({"verb": "set", "target": f"displayUUID:{display_uuid}",
                        "property": "brightness", "value": "+10%"})
    got = value_for(response, "brightness")
    record("50% 之後 +10% → 60%", got is not None and abs(got - 0.6) < 0.001, f"實得 {got}")
    response = control({"verb": "set", "target": f"displayUUID:{display_uuid}",
                        "property": "brightness", "value": "-0.2"})
    got = value_for(response, "brightness")
    record("再 -0.2 → 40%", got is not None and abs(got - 0.4) < 0.001, f"實得 {got}")

    print("\n[測試 4] 名稱定位（大小寫不敏感）", flush=True)
    fragment = display_name[:4].lower()
    response = control({"verb": "get", "target": f"displayLike:{fragment}", "property": "brightness"})
    record(f"displayLike:{fragment} 對上「{display_name}」",
           bool(response and response.get("ok")),
           (response or {}).get("error", {}).get("message", ""))

    print("\n[測試 5] 語意化定位", flush=True)
    for target in ["displayWithMouse", "displayWithFocus", "builtinDisplay"]:
        response = control({"verb": "get", "target": target, "property": "brightness"})
        record(f"{target} 解析成實體",
               bool(response and response.get("ok")),
               (response or {}).get("error", {}).get("message", ""))

    print("\n[測試 6] toggle 與 power", flush=True)
    response = control({"verb": "toggle", "target": f"displayUUID:{display_uuid}", "property": "power"})
    record("toggle power → 關閉", value_for(response, "power") is False, f"實得 {value_for(response,'power')}")
    ok, _ = wait_for(lambda d: any(x["uuid"] == display_uuid and x["poweredOff"] for x in d["displays"]))
    record("狀態確實反映在 displays", ok)
    response = control({"verb": "toggle", "target": f"displayUUID:{display_uuid}", "property": "power"})
    record("再 toggle → 開啟", value_for(response, "power") is True)

    print("\n[測試 7] system 屬性", flush=True)
    response = control({"verb": "set", "target": "system", "property": "keepAwake", "value": "30m"})
    record("set keepAwake 30m", value_for(response, "keepAwake") == 1800, f"實得 {value_for(response,'keepAwake')}")
    ok, _ = wait_for(lambda d: d["keepAwake"]["holding"] is True)
    record("assertion 真的持有", ok)
    response = control({"verb": "toggle", "target": "system", "property": "keepAwake"})
    record("toggle keepAwake → 關閉", value_for(response, "keepAwake") == 0)
    control({"verb": "set", "target": "system", "property": "keepAwake", "value": "off"})

    print("\n[測試 8] perform 動作", flush=True)
    control({"verb": "set", "target": "allDisplays", "property": "power", "value": "off"})
    response = control({"verb": "perform", "target": "system", "action": "restoreAllPower"})
    record("perform restoreAllPower 回復原台數",
           (value_for(response, "restoreAllPower") or 0) > 0,
           f"實得 {value_for(response,'restoreAllPower')}")
    response = control({"verb": "perform", "target": "system", "action": "refresh"})
    record("perform refresh", bool(response and response.get("ok")))

    print("\n[測試 9] 錯誤都帶可修正的 hint", flush=True)
    cases = [
        ({"verb": "set", "target": "defaultOutput", "property": "brightness", "value": "50%"},
         "targetKindMismatch", "亮度套在音訊裝置上"),
        ({"verb": "get", "target": "allDisplays", "property": "input"},
         "verbNotAllowed", "input 不支援 get"),
        ({"verb": "set", "target": "allDisplays", "property": "brightness", "value": "abc"},
         "badValue", "無法解析的值"),
        ({"verb": "set", "target": "displayLike:不存在的螢幕", "property": "brightness", "value": "50%"},
         "targetNotFound", "找不到目標"),
        ({"verb": "toggle", "target": "allDisplays", "property": "brightness"},
         "verbNotAllowed", "亮度不能 toggle"),
        ({"verb": "set", "target": "allDisplays", "property": "brightness"},
         "missingValue", "set 少了值"),
        ({"verb": "set", "target": "app:com.apple.Music", "property": "volume", "value": "50%"},
         "unsupported", "per-app 尚未啟用"),
        ({"verb": "set", "target": "allDisplays", "property": "brightness", "value": "50%", "peer": "不存在"},
         "peerNotFound", "找不到 peer"),
    ]
    for request, expected_code, label in cases:
        response = control(request)
        error = (response or {}).get("error") or {}
        code_ok = error.get("code") == expected_code
        # unsupported 是唯一允許沒有 hint 的（訊息本身已是完整說明）
        hint_ok = bool(error.get("hint")) or expected_code == "unsupported"
        record(f"{label} → {expected_code}＋hint", code_ok and hint_ok,
               f"實得 code={error.get('code')} hint={'有' if error.get('hint') else '無'}")

    print("\n[測試 10] 跨機轉發", flush=True)
    launch("B", 47701, 47801)
    ok, _ = wait_for(lambda d: len(d.get("displays", [])) > 0, inst="B", timeout=30)
    if not ok:
        record("第二實例啟動", False)
    else:
        notify("A", "beginPairing")
        notify("B", "beginPairing")
        time.sleep(2)
        notify("A", "requestPairLoopback", "47801")
        ok, _ = wait_for(lambda d: d.get("pairingPhase") == "incomingRequest", inst="B", timeout=20)
        if not ok:
            record("loopback 配對", False)
        else:
            notify("B", "acceptIncoming")
            wait_for(lambda d: d.get("pairingPhase", "").startswith("showingSAS"), inst="A")
            wait_for(lambda d: d.get("pairingPhase", "").startswith("showingSAS"), inst="B")
            notify("A", "confirmSAS")
            notify("B", "confirmSAS")
            connected = lambda d: "connected" in d.get("connectionStates", {}).values()
            ok_a, _ = wait_for(connected, inst="A", timeout=30)
            ok_b, _ = wait_for(connected, inst="B", timeout=30)
            record("配對並連線", ok_a and ok_b)
            if ok_a and ok_b:
                peer_name = (dump("B") or {}).get("instance", "B")
                # peer 比對是名稱片段；B 實例的 deviceName 會帶 (B)
                response = control({"verb": "set", "target": "allDisplays", "property": "power",
                                    "value": "off", "peer": "(B)"})
                record("peer + allDisplays + power off 轉發成功",
                       bool(response and response.get("ok")),
                       (response or {}).get("error", {}).get("message", ""))
                ok, _ = wait_for(lambda d: any(x["poweredOff"] for x in d["displays"]),
                                 inst="B", timeout=15)
                record("B 的螢幕真的關了（MCP 招牌情境）", ok)
                control({"verb": "set", "target": "allDisplays", "property": "power",
                         "value": "on", "peer": "(B)"})
                ok, _ = wait_for(lambda d: not any(x["poweredOff"] for x in d["displays"]),
                                 inst="B", timeout=15)
                record("遙控開回來", ok)

                response = control({"verb": "set", "target": "allDisplays", "property": "brightness",
                                    "value": "+10%", "peer": "(B)"})
                error = (response or {}).get("error") or {}
                record("跨機相對增減誠實拒絕（不猜對方現值）",
                       error.get("code") == "unsupported", f"實得 {error.get('code')}")

                response = control({"verb": "set", "target": "displayLike:DELL",
                                    "property": "brightness", "value": "50%", "peer": "(B)"})
                error = (response or {}).get("error") or {}
                record("跨機名稱定位誠實回 unsupported＋可用組合",
                       error.get("code") == "unsupported" and "allDisplays" in (error.get("message") or ""),
                       f"實得 {error.get('code')}")

    print("\n=== 總結 ===", flush=True)
    passed = sum(1 for _, ok in results if ok)
    print(f"  {passed}/{len(results)} 通過\n", flush=True)
    for name, ok in results:
        if not ok:
            print(f"  ❌ {name}", flush=True)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    code = 1
    try:
        code = main() or 0
    finally:
        cleanup()
    sys.exit(code)
