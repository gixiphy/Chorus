#!/usr/bin/env python3
"""回應性基線與驗收：用故障注入重現事故，對照方案的驗收目標。

兩個 Debug 實例（假光感、假 tap、暫存備份目錄），不寫實體螢幕、不碰使用者
真的 iCloud Drive。每個情境記下量到的數字，並判定有沒有達到驗收目標；
報告另存 JSON。Batch A 在修正前跑出的是「全部未達標」的基線。

    python3 scripts/test-a-baseline.py                  # 全部情境
    python3 scripts/test-a-baseline.py idle cloud exit  # 只跑指定情境
    python3 scripts/test-a-baseline.py --report out.json

情境與驗收目標：
  idle   靜置 30 秒：主迴圈 P95 上界 ≤ 100 ms、沒有卡住
  cloud  備份寫入延遲 4 秒時觸發備份：期間沒有 >500 ms 的主執行緒延遲，備份仍會完成
  exit   備份寫入延遲 4 秒時正常結束：quit 到行程退出 < 2 秒
  hello  對端連線 ready 後不送 hello（心跳照送）：不卡在「連線中」、30 秒內
         hello 失敗 ≤ 8 次（有退避）、解除後 60 秒內自己恢復
  silent 對端連線 ready 後什麼都送不出去（sync.send 卡住）：hello 等待 < 10 秒、
         不卡在「連線中」、解除後 60 秒內自己恢復
  hello／silent 需要區域網路權限，會先走一次配對

百分位取自固定桶直方圖，是**上界**（所在桶的上界，並以最大值封頂）。
"""

import json
import os
import re
import subprocess
import sys
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".a-work")
NOTIFY = os.path.join(WORK, "notify")
CLOUD = os.path.join(WORK, "cloud")
LOGS = os.path.expanduser("~/Library/Logs/Chorus")
ALL_SCENARIOS = ["idle", "cloud", "exit", "hello", "silent"]

procs = {}
report = {"startedAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "scenarios": {}}


def find_debug_app():
    newest, newest_time = None, 0
    for entry in os.listdir(DERIVED):
        if not entry.startswith("Chorus-"):
            continue
        candidate = os.path.join(DERIVED, entry, "Build/Products/Debug/Chorus.app/Contents/MacOS/Chorus")
        if os.path.exists(candidate) and os.path.getmtime(candidate) > newest_time:
            newest, newest_time = candidate, os.path.getmtime(candidate)
    if not newest:
        sys.exit("找不到 Debug build。先執行：xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Debug build")
    return newest


APP = find_debug_app()


def notify(inst, action, value=None):
    subprocess.run([NOTIFY, inst, action] + ([value] if value is not None else []), capture_output=True)


def dump(inst):
    try:
        with open(os.path.join(WORK, f"dump-{inst}.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def launch(inst, faults=()):
    args = [APP, "--instance", inst, "--fake-als", "--fake-taps", "--cloud-root", CLOUD,
            "--state-dump", os.path.join(WORK, f"dump-{inst}.json")]
    for spec in faults:
        args += ["--fault", spec]
    try:
        os.remove(os.path.join(WORK, f"dump-{inst}.json"))
    except FileNotFoundError:
        pass
    procs[inst] = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop(inst, timeout=5):
    proc = procs.pop(inst, None)
    if not proc:
        return
    proc.terminate()
    try:
        proc.wait(timeout=timeout)
    except Exception:
        proc.kill()


def wait_for(inst, pred, timeout):
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


def resp(data):
    return (data or {}).get("responsiveness", {})


def main_loop(data):
    return resp(data).get("mainLoop", {})


def operation(data, name):
    return resp(data).get("operations", {}).get(name, {})


def log_path(inst):
    return os.path.join(LOGS, f"chorus-{inst}.log")


def log_size(inst):
    try:
        return os.path.getsize(log_path(inst))
    except FileNotFoundError:
        return 0


def log_lines_since(inst, offset):
    try:
        with open(log_path(inst), "rb") as handle:
            handle.seek(offset)
            return handle.read().decode("utf-8", "replace").splitlines()
    except FileNotFoundError:
        return []


def say(text):
    print(text, flush=True)


def record(name, target_met, metrics, note=""):
    report["scenarios"][name] = {"targetMet": target_met, "metrics": metrics, "note": note}
    mark = "✅ 達標" if target_met else "❌ 未達標"
    say(f"  {mark}  {note}")
    for key, value in metrics.items():
        say(f"      {key}: {value}")


def ready(inst, timeout=30):
    ok, _ = wait_for(inst, lambda d: main_loop(d).get("running") is True
                     and d.get("cloudBackup", {}).get("available") is True, timeout)
    return ok


def reset_instance(inst):
    subprocess.run(["defaults", "delete", f"com.hermes.Chorus.instance-{inst}"], capture_output=True)
    subprocess.run(["security", "delete-generic-password", "-s", f"com.hermes.Chorus.instance-{inst}"],
                   capture_output=True)
    subprocess.run(["rm", "-rf", os.path.expanduser(f"~/Library/Application Support/Chorus/instance-{inst}")],
                   capture_output=True)


def save_scene(inst, name):
    notify(inst, "saveScene", json.dumps({"id": str(uuid.uuid4()), "name": name, "requests": []},
                                         ensure_ascii=False))


# MARK: - 情境

def scenario_idle():
    say("\n[idle] 靜置 30 秒的主迴圈延遲")
    launch("A")
    if not ready("A"):
        record("idle", False, {}, "實例沒有就緒")
        return
    time.sleep(30)
    loop = main_loop(dump("A"))
    stop("A")
    latency = loop.get("latencyMs", {})
    record("idle", (latency.get("p95") or 0) <= 100 and loop.get("hangCount") == 0, {
        "samples": latency.get("count"), "p50UpperMs": latency.get("p50"),
        "p95UpperMs": latency.get("p95"), "p99UpperMs": latency.get("p99"), "maxMs": latency.get("max"),
        "lagCount": loop.get("lagCount"), "hangCount": loop.get("hangCount"),
    }, "正常基準（含啟動列舉）")


def scenario_cloud():
    say("\n[cloud] 備份寫入延遲 4 秒時觸發備份")
    launch("A", faults=["cloud.write=delay:4"])
    if not ready("A"):
        record("cloud", False, {}, "實例沒有就緒")
        return
    time.sleep(3)
    before = main_loop(dump("A"))
    notify("A", "cloudBackupNow")
    completed, _ = wait_for("A", lambda d: operation(d, "cloud.write").get("completed", 0) >= 1, 20)
    time.sleep(2)  # 等 watchdog 把可能的停頓記完
    data = dump("A")
    stop("A")
    loop = main_loop(data)
    write = operation(data, "cloud.write")
    lag_delta = loop.get("lagCount", 0) - before.get("lagCount", 0)
    hang_delta = loop.get("hangCount", 0) - before.get("hangCount", 0)
    record("cloud", completed and lag_delta == 0 and hang_delta == 0, {
        "backupCompleted": completed,
        "mainLagDelta": lag_delta,
        "mainHangDelta": hang_delta,
        "longestMainStallMs": round(loop.get("longestStallMs") or 0),
        "cloudWriteMaxMs": round(write.get("latencyMs", {}).get("max", 0)),
    }, "寫入卡住期間主執行緒照常回應" if lag_delta == 0 and hang_delta == 0
       else "cloud.write 拖住了主執行緒")


def scenario_exit():
    say("\n[exit] 備份寫入延遲 4 秒時正常結束")
    launch("A")
    if not ready("A"):
        record("exit", False, {}, "實例沒有就緒")
        return
    notify("A", "cloudEnabled", "1")
    wait_for("A", lambda d: operation(d, "cloud.write").get("completed", 0) >= 1, 15)
    # 內容要跟上次寫出的不同，結束時才會補寫
    save_scene("A", f"exit-{uuid.uuid4().hex[:6]}")
    time.sleep(1.5)
    notify("A", "fault", "cloud.write=delay:4")
    time.sleep(1)
    offset = log_size("A")
    proc = procs["A"]
    started = time.time()
    notify("A", "quit")
    try:
        proc.wait(timeout=30)
        exited = True
    except Exception:
        exited = False
    wall = time.time() - started
    procs.pop("A", None)
    if not exited:
        proc.kill()
    exit_line = next((line for line in log_lines_since("A", offset) if "結束收尾：" in line), "")
    match = re.search(r"cloud ([\d.]+ (?:ms|s))", exit_line)
    total = re.search(r"（共 ([\d.]+ (?:ms|s))）", exit_line)
    record("exit", exited and wall < 2.0, {
        "quitToExitSeconds": round(wall, 2),
        "exitCloudStep": match.group(1) if match else None,
        "exitCoordinatorTotal": total.group(1) if total else None,
    }, ("退出沒有等 iCloud Drive" if wall < 2.0 else "退出被收尾拖住") if exit_line
       else "紀錄檔裡找不到收尾耗時那一行")


def pair_instances():
    launch("A")
    launch("B")
    if not (ready("A") and ready("B")):
        return False, "實例沒有就緒"
    notify("A", "beginPairing")
    notify("B", "beginPairing")
    ok, _ = wait_for("A", lambda d: any("(B)" in c for c in d.get("candidates", [])), 25)
    if not ok:
        return False, "Bonjour 找不到對方（區域網路權限？）"
    notify("A", "requestPairNamed", "(B)")
    ok, _ = wait_for("B", lambda d: d.get("pairingPhase") == "incomingRequest", 15)
    if not ok:
        return False, "B 沒收到配對請求"
    notify("B", "acceptIncoming")
    ok_a, _ = wait_for("A", lambda d: d.get("pairingPhase", "").startswith("showingSAS"), 15)
    ok_b, _ = wait_for("B", lambda d: d.get("pairingPhase", "").startswith("showingSAS"), 15)
    if not (ok_a and ok_b):
        return False, "沒有進到 SAS"
    notify("A", "confirmSAS")
    notify("B", "confirmSAS")
    connected = lambda d: "connected" in d.get("connectionStates", {}).values()
    ok_a, _ = wait_for("A", connected, 40)
    ok_b, _ = wait_for("B", connected, 40)
    return ok_a and ok_b, "" if ok_a and ok_b else "配對後同步連線沒建立"


def sync_view(data):
    ops = resp(data).get("operations", {})
    def in_flight(name):
        return ops.get(name, {}).get("inFlight", 0)
    hello = ops.get("sync.hello", {})
    return {
        "states": list((data or {}).get("connectionStates", {}).values()),
        "connectInFlight": in_flight("sync.connect") + in_flight("sync.accept"),
        "helloInFlight": in_flight("sync.hello"),
        "helloOldestMs": round(hello.get("oldestInFlightMs") or 0),
        "helloOutcomes": hello.get("outcomes", {}),
    }


def stuck_connecting(view):
    """狀態寫著連線中，手上卻沒有任何進行中的撥號或 hello——沒有東西會讓它離開這個狀態。"""
    return "connecting" in view["states"] and view["connectInFlight"] == 0 and view["helloInFlight"] == 0


def scenario_peer_fault(name, fault, clear, title):
    say(f"\n[{name}] {title}")
    paired, reason = pair_instances()
    if not paired:
        stop("A")
        stop("B")
        record(name, False, {}, f"前置失敗：{reason}")
        return
    stop("B")
    wait_for("A", lambda d: "connected" not in d.get("connectionStates", {}).values(), 45)
    launch("B", faults=[fault])
    ready("B")
    failures_before = sync_view(dump("A"))["helloOutcomes"].get("failure", 0)
    observe = 30
    say(f"  觀察 {observe} 秒…")
    time.sleep(observe)
    a, b = sync_view(dump("A")), sync_view(dump("B"))
    both_connected = "connected" in a["states"] and "connected" in b["states"]
    hello_waiting = max(a["helloOldestMs"], b["helloOldestMs"]) >= 20_000
    stuck = stuck_connecting(a) or stuck_connecting(b)
    # 正常退避（1、2、4、8、16 秒）30 秒內最多撥 5 次左右；遠超過就是沒有退避的重撥迴圈
    churn = a["helloOutcomes"].get("failure", 0) - failures_before

    notify("B", "fault", clear)
    recover_window = 60
    say(f"  解除故障，再觀察 {recover_window} 秒是否自己恢復…")
    connected = lambda d: "connected" in d.get("connectionStates", {}).values()
    started = time.time()
    ok_a, _ = wait_for("A", connected, recover_window)
    ok_b, _ = wait_for("B", connected, max(1, recover_window - (time.time() - started)))
    recovered_after = round(time.time() - started, 1) if ok_a and ok_b else None
    after_a, after_b = sync_view(dump("A")), sync_view(dump("B"))
    stop("A")
    stop("B")

    findings = []
    if hello_waiting:
        findings.append("hello 沒有期限，session 一直掛在等待")
    if stuck:
        findings.append("撥號方停在「連線中」且沒有任何在途工作，不會再重撥")
    if churn > 8:
        findings.append(f"{observe} 秒內 hello 失敗 {churn} 次，重撥沒有退避")
    if recovered_after is None:
        findings.append(f"解除故障 {recover_window} 秒內沒有自己恢復")
    hello_limit_ms = 10_000
    longest_hello = max(a["helloOldestMs"], b["helloOldestMs"])
    target_met = (not stuck and churn <= 8 and recovered_after is not None
                  and (name != "silent" or longest_hello < hello_limit_ms))
    record(name, target_met, {
        "A": a, "B": b,
        "helloFailuresDuringObserve": churn,
        "recoveredAfterClearSeconds": recovered_after,
        "afterClear": {"A": after_a, "B": after_b},
    }, "；".join(findings) or "有期限、有退避，解除後自己恢復")


def scenario_hello():
    scenario_peer_fault("hello", "sync.hello=withhold", "sync.hello=off",
                        "對端連線 ready 後不送 hello（心跳照送）")


def scenario_silent():
    scenario_peer_fault("silent", "sync.send=hang", "sync.send=off",
                        "對端連線 ready 後什麼都送不出去")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    report_path = None
    if "--report" in sys.argv:
        index = sys.argv.index("--report")
        report_path = sys.argv[index + 1] if index + 1 < len(sys.argv) else None
        if report_path in args:
            args.remove(report_path)
    selected = args or ALL_SCENARIOS
    unknown = [s for s in selected if s not in ALL_SCENARIOS]
    if unknown:
        sys.exit(f"未知情境：{unknown}；可用 {ALL_SCENARIOS}")

    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["swiftc", "-o", NOTIFY, os.path.join(REPO, "scripts", "notify.swift")], check=True)
    for inst in ("A", "B"):
        subprocess.run(["pkill", "-f", f"instance {inst}"], capture_output=True)
        reset_instance(inst)
    time.sleep(1)

    report["app"] = APP
    say(f"\n=== Batch A 回應性基線（{', '.join(selected)}）===")
    for name in selected:
        globals()[f"scenario_{name}"]()
        for inst in ("A", "B"):
            stop(inst)
            reset_instance(inst)
        subprocess.run(["rm", "-rf", CLOUD], capture_output=True)

    path = report_path or os.path.join(WORK, f"baseline-{time.strftime('%Y%m%d-%H%M%S')}.json")
    with open(path, "w") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    say(f"\n報告：{path}")
    met = [s for s in selected if report["scenarios"].get(s, {}).get("targetMet")]
    say(f"達標 {len(met)}/{len(selected)}")
    return 0 if len(met) == len(selected) else 1


if __name__ == "__main__":
    code = 1
    try:
        code = main()
    finally:
        for inst in list(procs):
            stop(inst)
        for inst in ("A", "B"):
            reset_instance(inst)
    sys.exit(code)
