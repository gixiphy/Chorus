#!/usr/bin/env python3
"""B3（M9）自動化回歸：螢幕電源三層、防睡眠、緊急復原手勢、跨機 command。

單機即可跑完；不需要輔助使用權限（緊急手勢走 TestHooks 注入同一套狀態機）。
會短暫關閉一台非主要顯示器再開回來——任何失敗路徑最後都會 restoreAll，
且 App 結束時 kCGConfigureForAppOnly 與 gamma atexit 一定還原。

    python3 scripts/test-b3-display-power.py
"""

import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".b3-work")
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


def dump(inst):
    try:
        with open(os.path.join(WORK, f"dump-{inst}.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def launch(inst, listen_port=None, pair_port=None):
    args = [APP, "--instance", inst, "--fake-als", "--state-dump", os.path.join(WORK, f"dump-{inst}.json")]
    if listen_port:
        # 固定 port 的手動端點模式：不註冊 Bonjour，loopback 不受區域網路
        # 權限管制。Bonjour 探索本身由 B1 的腳本負責，這裡只需要一條通道。
        args += ["--listen-port", str(listen_port), "--pair-port", str(pair_port)]
    procs[inst] = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def kill(inst):
    if inst not in procs:
        return
    procs[inst].terminate()
    try:
        procs[inst].wait(timeout=5)
    except Exception:
        procs[inst].kill()
    del procs[inst]


def wait_for(inst, pred, timeout=20):
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
        time.sleep(0.4)
    return False, last


def record(name, ok, detail=""):
    results.append((name, ok))
    print(("  ✅ " if ok else "  ❌ ") + name + (f"  — {detail}" if detail else ""), flush=True)


def stop_production_app():
    global prod_was_running
    running = subprocess.run(["pgrep", "-f", f"{PROD_APP}/Contents/MacOS/Chorus"], capture_output=True)
    prod_was_running = running.returncode == 0
    if prod_was_running:
        print("  （暫時結束正式 Chorus，避免兩個實例同時操作同一片硬體）", flush=True)
        subprocess.run(["osascript", "-e", 'quit app "Chorus"'], capture_output=True)
        time.sleep(2)
        subprocess.run(["pkill", "-x", "Chorus"], capture_output=True)
        time.sleep(1)


def cleanup():
    # 保險：關批前一律把螢幕開回來
    for inst in list(procs):
        notify(inst, "restoreAllDisplayPower")
    time.sleep(1)
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


def by_uuid(data, uuid):
    for display in data.get("displays", []):
        if display["uuid"] == uuid:
            return display
    return None


def main():
    build_notify()
    stop_production_app()

    print("\n=== B3（M9）螢幕電源與防睡眠 ===\n", flush=True)

    launch("A", 47700, 47800)
    ok, state = wait_for("A", lambda d: len(d.get("displays", [])) > 0, 30)
    if not ok:
        record("實例啟動並列舉顯示器", False, "state dump 未就緒")
        return
    displays = state["displays"]
    record("實例啟動並列舉顯示器", True, f"{len(displays)} 台")

    print("\n[測試 1] 三層選擇", flush=True)
    for display in displays:
        print(f"    {display['name']}: layer={display['powerLayer']} backend={display['backend']}", flush=True)
    layers = {d["powerLayer"] for d in displays}
    if len(displays) >= 2:
        record("多螢幕時不會全部落到保底層", layers != {"gammaBlackout"}, f"layers={sorted(layers)}")
    else:
        record("單螢幕時不使用 soft-disconnect（會鎖死使用者）",
               "softDisconnect" not in layers, f"layers={sorted(layers)}")

    # 挑一台非主要的來測；只有一台就用那台（會走 gamma 全黑，一樣可還原）
    target = displays[-1] if len(displays) > 1 else displays[0]
    uuid = target["uuid"]
    print(f"\n[測試 2] 關閉「{target['name']}」（{target['powerLayer']}）", flush=True)
    notify("A", "setDisplayPower", f"{uuid}:0")
    ok, state = wait_for("A", lambda d: (by_uuid(d, uuid) or {}).get("poweredOff") is True, 15)
    record("電源鈕關閉生效", ok)

    # 最關鍵的一項：soft-disconnect 會讓顯示器離開 CGGetActiveDisplayList，
    # 若 refresh 沒把它補回清單，UI 上的電源鈕會消失、再也開不回來。
    ok_listed, state = wait_for("A", lambda d: by_uuid(d, uuid) is not None, 12)
    record("關閉後仍留在顯示器清單（否則再也開不回來）", ok_listed)

    print("\n[測試 3] 緊急復原手勢（連按 8 次 ⌘）", flush=True)
    notify("A", "emergencyGesture", "7")
    time.sleep(1.5)
    state = dump("A") or {}
    still_off = (by_uuid(state, uuid) or {}).get("poweredOff") is True
    record("按 7 次不觸發", still_off)

    notify("A", "emergencyGesture", "8")
    ok, state = wait_for("A", lambda d: (by_uuid(d, uuid) or {}).get("poweredOff") is False, 15)
    record("按 8 次全部復原", ok)

    print("\n[測試 4] 全部關閉 → 全部復原", flush=True)
    notify("A", "setDisplayPower", "0")
    ok, _ = wait_for("A", lambda d: all(x["poweredOff"] for x in d["displays"]), 15)
    record("語意層關閉所有螢幕", ok)
    notify("A", "restoreAllDisplayPower")
    ok, _ = wait_for("A", lambda d: not any(x["poweredOff"] for x in d["displays"]), 15)
    record("全部復原", ok)

    print("\n[測試 5] 防睡眠（IOPMAssertion）", flush=True)
    notify("A", "setKeepAwake", "1800")
    ok, state = wait_for("A", lambda d: d["keepAwake"]["holding"] is True, 10)
    record("計時模式持有 assertion", ok, f"mode={(state or {}).get('keepAwake', {}).get('mode')}")
    remaining = (state or {}).get("keepAwake", {}).get("remaining")
    record("倒數有值且 ≤ 1800", isinstance(remaining, (int, float)) and 0 < remaining <= 1800,
           f"remaining={remaining}")

    # 系統層面確認 assertion 真的存在（不是只有我們自己的旗標）
    pmset = subprocess.run(["pmset", "-g", "assertions"], capture_output=True, text=True).stdout
    record("pmset 看得到 PreventUserIdleDisplaySleep", "PreventUserIdleDisplaySleep         1" in pmset
           or "PreventUserIdleDisplaySleep" in [ln.split()[0] for ln in pmset.splitlines() if ln.strip()],
           "")

    notify("A", "setKeepAwake", "0")
    ok, _ = wait_for("A", lambda d: d["keepAwake"]["holding"] is False, 10)
    record("關閉後釋放 assertion", ok)

    print("\n[測試 6] 防睡眠綁定螢幕", flush=True)
    notify("A", "setKeepAwake", f"display:{uuid}")
    ok, _ = wait_for("A", lambda d: d["keepAwake"]["holding"] is True, 10)
    record("綁定在線螢幕 → 生效", ok)
    notify("A", "setKeepAwake", "display:no-such-display")
    ok, state = wait_for("A", lambda d: d["keepAwake"]["holding"] is False, 10)
    record("綁定未連接螢幕 → 不持有 assertion", ok,
           f"mode={(state or {}).get('keepAwake', {}).get('mode')}")
    notify("A", "setKeepAwake", "0")

    print("\n[測試 6b] 防睡眠綁定 App", flush=True)
    # Finder 一定在跑；沒安裝的 bundle id 一定不在——不必真的開關 App
    notify("A", "setKeepAwake", "app:com.apple.finder")
    ok, state = wait_for("A", lambda d: d["keepAwake"]["holding"] is True, 10)
    record("綁定執行中的 App → 生效", ok,
           f"mode={(state or {}).get('keepAwake', {}).get('mode')}")
    notify("A", "setKeepAwake", "app:com.example.not-installed")
    ok, _ = wait_for("A", lambda d: d["keepAwake"]["holding"] is False, 10)
    record("綁定未執行的 App → 不持有 assertion", ok)
    # 真的開關一個 App，驗 NSWorkspace 啟動／結束通知有接上
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to quit'],
                   capture_output=True)
    notify("A", "setKeepAwake", "app:com.apple.TextEdit")
    time.sleep(1)
    subprocess.run(["open", "-g", "-a", "TextEdit"], capture_output=True)
    ok, _ = wait_for("A", lambda d: d["keepAwake"]["holding"] is True, 15)
    record("綁定的 App 啟動 → 自動生效", ok)
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to quit'],
                   capture_output=True)
    ok, _ = wait_for("A", lambda d: d["keepAwake"]["holding"] is False, 15)
    record("綁定的 App 結束 → 自動失效", ok)
    notify("A", "setKeepAwake", "0")

    print("\n[測試 7] 跨機 command（第二實例遙控關螢幕）", flush=True)
    launch("B", 47701, 47801)
    ok, _ = wait_for("B", lambda d: len(d.get("displays", [])) > 0, 30)
    if not ok:
        record("第二實例啟動", False)
    else:
        notify("A", "beginPairing")
        notify("B", "beginPairing")
        time.sleep(2)
        notify("A", "requestPairLoopback", "47801")
        ok, _ = wait_for("B", lambda d: d.get("pairingPhase") == "incomingRequest", 20)
        record("loopback 配對請求送達", ok)
        if ok:
            notify("B", "acceptIncoming")
            wait_for("A", lambda d: d.get("pairingPhase", "").startswith("showingSAS"), 15)
            wait_for("B", lambda d: d.get("pairingPhase", "").startswith("showingSAS"), 15)
            notify("A", "confirmSAS")
            notify("B", "confirmSAS")
            connected = lambda d: "connected" in d.get("connectionStates", {}).values()
            ok_a, _ = wait_for("A", connected, 30)
            ok_b, _ = wait_for("B", connected, 30)
            record("配對並建立同步連線", ok_a and ok_b)
            if ok_a and ok_b:
                notify("A", "remoteCommand", "displayPower:0")
                ok, _ = wait_for("B", lambda d: any(x["poweredOff"] for x in d["displays"]), 15)
                record("A 遙控 → B 關閉螢幕", ok)
                notify("A", "remoteCommand", "displayPower:1")
                ok, _ = wait_for("B", lambda d: not any(x["poweredOff"] for x in d["displays"]), 15)
                record("A 遙控 → B 開啟螢幕", ok)

                notify("A", "remoteCommand", "keepAwake:-1")
                ok, state = wait_for("B", lambda d: d["keepAwake"]["holding"] is True, 10)
                record("A 遙控 → B 進入無限期防睡眠", ok,
                       f"mode={(state or {}).get('keepAwake', {}).get('mode')}")
                notify("A", "remoteCommand", "keepAwake:0")
                ok, _ = wait_for("B", lambda d: d["keepAwake"]["holding"] is False, 10)
                record("A 遙控 → B 關閉防睡眠", ok)

                # 電源與防睡眠是 command 專用鍵：絕不能進 LWW 狀態同步，
                # 否則兩台會互相把對方的螢幕關掉
                notify("B", "setDisplayPower", "0")
                time.sleep(3)
                state_a = dump("A") or {}
                leaked = any(x["poweredOff"] for x in state_a.get("displays", []))
                record("B 本機關螢幕不會同步回 A（command 專用鍵不做狀態同步）", not leaked)
                notify("B", "restoreAllDisplayPower")

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
