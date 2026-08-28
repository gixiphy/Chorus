#!/usr/bin/env python3
"""B4-1（M10 動詞層）自動化回歸：走 TestHooks 的 control 入口，
不需要 HTTP server、token 或任何權限。

    python3 scripts/test-b4-automation.py
"""

import json
import os
import subprocess
import sys
import threading
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


def kill_stale_instances():
    """前一輪沒收乾淨的測試實例會佔著 HTTP port，讓整組 HTTP 測試假性失敗。"""
    for inst in ("A", "B"):
        subprocess.run(["pkill", "-f", f"instance {inst}"], capture_output=True)
    time.sleep(1)


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


def by_uuid(data, uuid):
    for display in data.get("displays", []):
        if display["uuid"] == uuid:
            return display
    return None


def value_for(response, prop):
    for item in (response or {}).get("results") or []:
        if item.get("property") == prop:
            return item.get("value")
    return None


def main():
    build_notify()
    kill_stale_instances()
    stop_production_app()

    print("\n=== B4（M10）自動化介面 ===\n", flush=True)
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

    print("\n[測試 10] localhost HTTP 介面（B4-2）", flush=True)
    port = 55781  # 錯開預設 55780，避免撞到正式 app
    notify("A", "automationServer", f"1:{port}")
    ok, state = wait_for(lambda d: d["automationServer"]["running"] is True, timeout=15)
    record("HTTP server 啟動", ok, (state or {}).get("automationServer", {}).get("lastError") or "")
    token = (state or {}).get("automationServer", {}).get("token")
    if not ok or not token:
        record("取得 token", False)
    else:
        base = f"http://127.0.0.1:{port}"

        def curl(args):
            out = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5"] + args,
                                 capture_output=True, text=True)
            return out.stdout.strip()

        def curl_body(args):
            out = subprocess.run(["curl", "-s", "--max-time", "5"] + args, capture_output=True, text=True)
            try:
                return json.loads(out.stdout)
            except Exception:
                return None

        auth = ["-H", f"Authorization: Bearer {token}"]
        record("無 token → 401", curl([f"{base}/v1/state"]) == "401")
        record("錯 token → 401",
               curl(["-H", "Authorization: Bearer wrong", f"{base}/v1/state"]) == "401")
        record("偽造 Host → 403（擋 DNS rebinding）",
               curl(auth + ["-H", "Host: evil.example", f"{base}/v1/state"]) == "403")
        record("正確 token → 200", curl(auth + [f"{base}/v1/state"]) == "200")
        record("未知端點 → 404", curl(auth + [f"{base}/v1/nope"]) == "404")

        body = curl_body(auth + [f"{base}/v1/state"])
        props = {item.get("property") for item in (body or {}).get("results") or []}
        record("/v1/state 併回顯示器＋音訊＋整機",
               {"brightness", "volume", "keepAwake"} <= props, f"實得 {sorted(props)[:8]}")

        payload = json.dumps({"verb": "set", "target": f"displayUUID:{display_uuid}",
                              "property": "brightness", "value": "35%"})
        body = curl_body(auth + ["-X", "POST", "-H", "Content-Type: application/json",
                                 "-d", payload, f"{base}/v1/command"])
        record("POST /v1/command 單筆",
               bool(body and body.get("ok")) and abs((value_for(body, "brightness") or 0) - 0.35) < 0.001,
               f"實得 {value_for(body, 'brightness') if body else None}")

        batch = json.dumps([
            {"verb": "set", "target": f"displayUUID:{display_uuid}", "property": "brightness", "value": "45%"},
            {"verb": "get", "target": "system", "property": "autoBrightness"},
        ])
        body = curl_body(auth + ["-X", "POST", "-H", "Content-Type: application/json",
                                 "-d", batch, f"{base}/v1/command"])
        record("POST /v1/command 陣列（批次）",
               isinstance(body, list) and len(body) == 2 and all(x.get("ok") for x in body),
               f"實得 {type(body).__name__}")

        body = curl_body(auth + ["-X", "POST", "-H", "Content-Type: application/json",
                                 "-d", '{"verb":"nonsense","target":"allDisplays"}', f"{base}/v1/command"])
        record("壞請求 → 400＋可讀錯誤",
               bool(body) and body.get("ok") is False and bool(body.get("error", {}).get("message")))

        # SSE：開一條事件流，改亮度，確認收得到。
        # 連線建立與事件送達都沒有保證時間，固定 sleep 會 flaky（指令可能早於
        # 訂閱生效，或 terminate 早於事件 flush），所以改成輪詢：背景執行緒把
        # stdout 收進 buffer，主迴圈重複下指令直到看見 brightness 事件或逾時。
        # 亮度值交替，免得同值被判定為「沒變」而不發事件。
        proc = subprocess.Popen(["curl", "-sN", "--max-time", "30"] + auth + [f"{base}/v1/events"],
                                stdout=subprocess.PIPE, text=True)
        chunks = []

        def drain(pipe):
            for line in iter(pipe.readline, ""):
                chunks.append(line)

        reader = threading.Thread(target=drain, args=(proc.stdout,), daemon=True)
        reader.start()

        deadline = time.monotonic() + 10
        percent = 65
        while True:
            # control() 自帶 1.6 秒等待，剛好當作輪詢節奏
            control({"verb": "set", "target": f"displayUUID:{display_uuid}",
                     "property": "brightness", "value": f"{percent}%"})
            percent = 60 if percent == 65 else 65
            if "brightness" in "".join(chunks) or time.monotonic() >= deadline:
                break
        proc.terminate()
        reader.join(timeout=2)
        stream = "".join(chunks)
        record("GET /v1/events 推送變更事件",
               "data:" in stream and "brightness" in stream,
               f"收到 {len(stream)} bytes")

        print("\n[測試 11] chorus CLI（B4-3）", flush=True)
        # APP 是 .../Chorus.app/Contents/MacOS/Chorus，CLI 在 SharedSupport
        cli = os.path.join(os.path.dirname(os.path.dirname(APP)), "SharedSupport", "chorus")
        record("CLI 內嵌在 App bundle 裡", os.path.exists(cli), cli)

        config_path = os.path.expanduser("~/.config/chorus/config.json")
        record("啟動時寫出 CLI 設定檔", os.path.exists(config_path))
        if os.path.exists(config_path):
            mode = oct(os.stat(config_path).st_mode & 0o777)
            record("設定檔權限 600（內容等同介面的鑰匙）", mode == "0o600", f"實得 {mode}")

        if os.path.exists(cli):
            # 用環境變數驅動，不動使用者的設定檔
            env = dict(os.environ, CHORUS_TOKEN=token, CHORUS_PORT=str(port))

            def run_cli(args, env_override=None):
                return subprocess.run([cli] + args, capture_output=True, text=True,
                                      env=env_override or env, timeout=15)

            out = run_cli(["set", "--display-uuid", display_uuid, "--brightness", "25%"])
            record("chorus set --brightness 25%",
                   out.returncode == 0 and "25%" in out.stdout, f"{out.stdout.strip()}{out.stderr.strip()}")

            out = run_cli(["get", "--display-uuid", display_uuid, "--brightness"])
            record("chorus get 印出百分比（依屬性種類，不靠猜）",
                   out.returncode == 0 and "25%" in out.stdout, out.stdout.strip())

            out = run_cli(["set", "--display-uuid", display_uuid, "--brightness", "+10%"])
            record("chorus set 相對增減 → 35%",
                   out.returncode == 0 and "35%" in out.stdout, out.stdout.strip())

            out = run_cli(["--json", "get", "--display-uuid", display_uuid, "--brightness"])
            parsed = None
            try:
                parsed = json.loads(out.stdout)
            except Exception:
                pass
            record("--json 輸出機器可讀 JSON", bool(parsed and parsed.get("ok")))

            out = run_cli(["get", "--system", "--keepAwake"])
            record("system 屬性：keepAwake 印秒數不印百分比",
                   out.returncode == 0 and "%" not in out.stdout, out.stdout.strip())

            out = run_cli(["set", "--brightness", "30%"])
            record("省略目標時依屬性推斷（allDisplays）", out.returncode == 0, out.stdout.strip()[:60])

            out = run_cli(["set", "--display-like", "不存在", "--brightness", "50%"])
            record("找不到目標 → 非零結束碼＋提示",
                   out.returncode != 0 and "提示" in out.stderr, out.stderr.strip()[:80])

            out = run_cli(["set", "--nosuchprop", "1"])
            record("未知屬性 → 非零結束碼", out.returncode != 0, out.stderr.strip()[:60])

            bad = dict(os.environ, CHORUS_TOKEN="wrong", CHORUS_PORT=str(port))
            out = run_cli(["state"], env_override=bad)
            record("錯 token → 結束碼 3", out.returncode == 3, f"實得 {out.returncode}")

            no_token = {k: v for k, v in os.environ.items() if k != "CHORUS_TOKEN"}
            no_token["CHORUS_CONFIG"] = "/nonexistent/chorus.json"
            out = run_cli(["state"], env_override=no_token)
            record("沒有 token → 結束碼 3＋說明怎麼取得",
                   out.returncode == 3 and "設定頁" in out.stderr, out.stderr.strip()[:60])

            out = run_cli(["help"])
            record("chorus help 列出用法", out.returncode == 0 and "--brightness" in out.stdout)

            notify("A", "captureScene", "CLI 場景")
            time.sleep(1.5)
            out = run_cli(["scenes"])
            record("chorus scenes 列出場景",
                   out.returncode == 0 and "CLI 場景" in out.stdout, out.stdout.strip()[:60])
            out = run_cli(["scene", "CLI 場景"])
            record("chorus scene <名稱> 套用場景", out.returncode == 0, out.stdout.strip()[:60] + out.stderr.strip()[:60])
            notify("A", "deleteScene", "CLI 場景")

    notify("A", "automationServer", "0")
    ok, _ = wait_for(lambda d: d["automationServer"]["running"] is False, timeout=10)
    record("關閉後 server 停止", ok)
    record("關閉後 CLI 設定檔一併移除（不留過期的鑰匙）",
           not os.path.exists(os.path.expanduser("~/.config/chorus/config.json")))
    record("關閉後 port 不再接受連線",
           subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3",
                           f"http://127.0.0.1:{port}/v1/state"],
                          capture_output=True, text=True).stdout.strip() in ("000", ""))

    print("\n[測試 12] 場景（B4-5）", flush=True)
    # 先把亮度設成已知值，擷取後改掉，再套用場景看是否回得去
    control({"verb": "set", "target": f"displayUUID:{display_uuid}",
             "property": "brightness", "value": "42%"})
    notify("A", "captureScene", "測試場景")
    ok, state = wait_for(lambda d: any(s["name"] == "測試場景" for s in d.get("scenes", [])), timeout=10)
    captured = next((s for s in (state or {}).get("scenes", []) if s["name"] == "測試場景"), None)
    record("以目前狀態建立場景", ok and (captured or {}).get("requests", 0) > 0,
           f"{(captured or {}).get('requests')} 個動作")

    control({"verb": "set", "target": f"displayUUID:{display_uuid}",
             "property": "brightness", "value": "90%"})
    response = control({"verb": "perform", "target": "system",
                        "action": "runScene", "value": "測試場景"})
    record("perform runScene 成功", bool(response and response.get("ok")),
           (response or {}).get("error", {}).get("message", ""))
    ok, state = wait_for(
        lambda d: abs(((by_uuid(d, display_uuid) or {}).get("brightness") or 0) - 0.42) < 0.02, timeout=12)
    record("套用場景把亮度還原成擷取時的值", ok,
           f"實得 {(by_uuid(state or {}, display_uuid) or {}).get('brightness')}")

    # 名稱前綴查找
    response = control({"verb": "perform", "target": "system",
                        "action": "runScene", "value": "測試"})
    record("場景名稱可用前綴定位", bool(response and response.get("ok")))

    response = control({"verb": "perform", "target": "system",
                        "action": "runScene", "value": "不存在的場景"})
    error = (response or {}).get("error") or {}
    record("找不到場景 → targetNotFound＋列出現有場景",
           error.get("code") == "targetNotFound" and "測試場景" in (error.get("hint") or ""),
           f"實得 {error.get('code')}")

    response = control({"verb": "perform", "target": "system", "action": "runScene"})
    error = (response or {}).get("error") or {}
    record("perform runScene 少了名稱 → badValue", error.get("code") == "badValue")

    notify("A", "deleteScene", "測試場景")
    ok, _ = wait_for(lambda d: not any(s["name"] == "測試場景" for s in d.get("scenes", [])), timeout=10)
    record("刪除場景", ok)

    print("\n[測試 13] 跨機轉發", flush=True)
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
