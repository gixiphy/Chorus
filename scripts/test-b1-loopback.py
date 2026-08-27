#!/usr/bin/env python3
"""B1 同機 loopback 回歸測試：兩個 Debug 實例，走真實 Bonjour 探索與 TLS-PSK 連線。

涵蓋 HANDOFF 測試 1–4 中不需要第二台實體 Mac 的部分：
區網權限、Bonjour 探索、配對＋SAS、TLS 連線、雙向同步、收斂無震盪、
斷線偵測、重啟自動重連。

需要實體第二台／人為動作的項目（睡醒重連、拔網路、鍵盤亮度鍵、
DDC 背光與 OSD 音量目視確認）不在此腳本範圍。

用法：
    scripts/test-b1-loopback.py            # 完整跑（含亮度同步，會動到實體螢幕）
    scripts/test-b1-loopback.py --no-hw    # 跳過會寫入實體螢幕的同步測試

⚠️ 亮度同步測試會寫入實體螢幕。腳本會先結束 /Applications/Chorus.app 再測，
   避免正式 app 的自動亮度把測試值學成差異值（實測踩過這個坑），
   結束後還原亮度並重新啟動正式 app。
"""
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".b1-work")
NOTIFY = os.path.join(WORK, "notify")
PROD_APP = "/Applications/Chorus.app"

SKIP_HW = "--no-hw" in sys.argv
procs = {}
results = []
prod_was_running = False


def find_debug_app():
    for entry in sorted(os.listdir(DERIVED)):
        if not entry.startswith("Chorus-"):
            continue
        candidate = os.path.join(DERIVED, entry, "Build/Products/Debug/Chorus.app/Contents/MacOS/Chorus")
        if os.path.exists(candidate):
            return candidate
    sys.exit("找不到 Debug build。先執行：xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Debug build")


APP = find_debug_app()


def build_notify():
    os.makedirs(WORK, exist_ok=True)
    src = os.path.join(REPO, "scripts", "notify.swift")
    if not os.path.exists(NOTIFY) or os.path.getmtime(src) > os.path.getmtime(NOTIFY):
        subprocess.run(["swiftc", "-o", NOTIFY, src], check=True)


def notify(inst, action, value=None):
    subprocess.run([NOTIFY, inst, action] + ([value] if value else []), capture_output=True)


def dump(inst):
    try:
        with open(os.path.join(WORK, f"dump-{inst}.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def launch(inst):
    procs[inst] = subprocess.Popen(
        [APP, "--instance", inst, "--fake-als", "--state-dump", os.path.join(WORK, f"dump-{inst}.json")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def kill(inst):
    if inst not in procs:
        return
    procs[inst].terminate()
    try:
        procs[inst].wait(timeout=5)
    except Exception:
        procs[inst].kill()
    del procs[inst]


def wait_for(inst, pred, timeout=30):
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
        time.sleep(0.5)
    return False, last


def record(name, ok, detail=""):
    results.append((name, ok))
    print(("  ✅ " if ok else "  ❌ ") + name + (f"  — {detail}" if detail else ""), flush=True)


def stop_production_app():
    """避免正式 app 的自動亮度把測試寫入的亮度學成差異值。"""
    global prod_was_running
    running = subprocess.run(["pgrep", "-f", f"{PROD_APP}/Contents/MacOS/Chorus"], capture_output=True)
    prod_was_running = running.returncode == 0
    if prod_was_running:
        print("  （暫時結束正式 Chorus，避免自動亮度學到測試值）", flush=True)
        subprocess.run(["osascript", "-e", 'quit app "Chorus"'], capture_output=True)
        time.sleep(2)
        subprocess.run(["pkill", "-x", "Chorus"], capture_output=True)
        time.sleep(1)


def cleanup():
    for inst in list(procs):
        kill(inst)
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


def main():
    build_notify()
    cleanup_defaults_only()
    if not SKIP_HW:
        stop_production_app()

    print("\n=== B1 loopback 測試（兩個 Debug 實例，真實 Bonjour + TLS）===\n", flush=True)

    print("[測試 1] Bonjour 探索與配對", flush=True)
    launch("A")
    launch("B")
    # 等到顯示器清單真的填好（空 list 不算），才有可信的原始亮度可還原
    ok_a, dump_a = wait_for("A", lambda d: len(d.get("displays", [])) > 0, 30)
    ok_b, _ = wait_for("B", lambda d: len(d.get("displays", [])) > 0, 30)
    if not (ok_a and ok_b):
        record("兩實例啟動並列舉顯示器", False, "state dump 未就緒")
        return
    original = {x["uuid"]: x["brightness"] for x in dump_a["displays"]}

    notify("A", "beginPairing")
    notify("B", "beginPairing")
    time.sleep(2)

    state_a = dump("A") or {}
    browser = state_a.get("pairingBrowserState", "?")
    record("區域網路權限（browser 無 NoAuth）", "NoAuth" not in browser, f"browser={browser}")
    listener = state_a.get("pairingListenerState", "?")
    record("配對 listener 啟動", "ready" in listener.lower(), f"listener={listener}")

    ok, data = wait_for("A", lambda d: any("(B)" in c for c in d.get("candidates", [])), 25)
    record("Bonjour 探索到對方（A 看到 B）", ok, f"候選={(data or {}).get('candidates')}")
    if not ok:
        return

    notify("A", "requestPairNamed", "(B)")
    ok, data = wait_for("B", lambda d: d.get("pairingPhase") == "incomingRequest", 15)
    record("B 收到配對請求", ok)
    if not ok:
        return

    notify("B", "acceptIncoming")
    ok_a, da = wait_for("A", lambda d: d.get("pairingPhase", "").startswith("showingSAS"), 15)
    ok_b, db = wait_for("B", lambda d: d.get("pairingPhase", "").startswith("showingSAS"), 15)
    sas_a = da.get("pairingPhase", "").split(":")[1] if ok_a else "?"
    sas_b = db.get("pairingPhase", "").split(":")[1] if ok_b else "?"
    record("雙方顯示 SAS 配對碼", ok_a and ok_b, f"A={sas_a} B={sas_b}")
    record("SAS 配對碼相符", ok_a and ok_b and sas_a == sas_b)

    notify("A", "confirmSAS")
    notify("B", "confirmSAS")
    ok_a, _ = wait_for("A", lambda d: len(d.get("pairedPeers", [])) > 0, 15)
    ok_b, _ = wait_for("B", lambda d: len(d.get("pairedPeers", [])) > 0, 15)
    record("配對完成（雙方留下紀錄）", ok_a and ok_b)

    connected = lambda d: "connected" in d.get("connectionStates", {}).values()
    ok_a, _ = wait_for("A", connected, 30)
    ok_b, _ = wait_for("B", connected, 30)
    record("TLS-PSK 同步連線建立", ok_a and ok_b)
    if not (ok_a and ok_b):
        return

    if SKIP_HW:
        print("\n[測試 2] 雙向同步 — 已跳過（--no-hw）", flush=True)
    else:
        print("\n[測試 2] 雙向同步", flush=True)
        target = 0.37
        notify("A", "setBrightness", str(target))
        ok, data = wait_for("B", lambda d: any(abs(x["brightness"] - target) < 0.02 for x in d["displays"]), 12)
        record("A → B 亮度同步", ok)

        target = 0.63
        notify("B", "setBrightness", str(target))
        ok, data = wait_for("A", lambda d: any(abs(x["brightness"] - target) < 0.02 for x in d["displays"]), 12)
        record("B → A 亮度同步（反向）", ok)

        for value in (0.30, 0.55, 0.45, 0.50):
            notify("A", "setBrightness", str(value))
            time.sleep(0.25)
        time.sleep(4)
        a1 = dump("A")["displays"][0]["brightness"]
        b1 = dump("B")["displays"][0]["brightness"]
        record("連續變更後收斂到同值", abs(a1 - b1) < 0.02, f"A={a1:.3f} B={b1:.3f}")
        time.sleep(3)
        a2 = dump("A")["displays"][0]["brightness"]
        b2 = dump("B")["displays"][0]["brightness"]
        record("靜置 3 秒無震盪", abs(a2 - a1) < 0.02 and abs(b2 - b1) < 0.02)

    print("\n[測試 3] 韌性：重啟 app 自動重連", flush=True)
    kill("B")
    ok, _ = wait_for("A", lambda d: "connected" not in d.get("connectionStates", {}).values(), 45)
    record("B 離線後 A 偵測到斷線", ok)

    launch("B")
    ok_a, _ = wait_for("A", connected, 60)
    ok_b, _ = wait_for("B", connected, 60)
    record("B 重啟後自動重連（配對資料持久化）", ok_a and ok_b)

    if not SKIP_HW and original:
        print("\n[收尾] 還原測試前的亮度", flush=True)
        for uuid, value in original.items():
            notify("A", "setBrightnessUUID", f"{uuid}:{value}")
        time.sleep(2)


def cleanup_defaults_only():
    for inst in ("A", "B"):
        subprocess.run(["defaults", "delete", f"com.hermes.Chorus.instance-{inst}"], capture_output=True)
        subprocess.run(["security", "delete-generic-password", "-s", f"com.hermes.Chorus.instance-{inst}"],
                       capture_output=True)
    os.makedirs(WORK, exist_ok=True)


if __name__ == "__main__":
    try:
        main()
    finally:
        print("\n=== 結果總表 ===", flush=True)
        passed = sum(1 for _, ok in results if ok)
        for name, ok in results:
            print(("✅ " if ok else "❌ ") + name, flush=True)
        print(f"\n{passed}/{len(results)} 通過", flush=True)
        cleanup()
        sys.exit(0 if passed == len(results) and results else 1)
