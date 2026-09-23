#!/usr/bin/env python3
"""蒐集這台 Chorus 的回應性數據，產出一份可以前後對照的摘要（Batch F）。

在要量的那台 Mac 上執行（不需要 Debug build、不改任何設定）：

    python3 scripts/collect-health.py                 # 印摘要
    python3 scripts/collect-health.py --json out.json # 另存完整 JSON
    python3 scripts/collect-health.py --since 2026-09-14T00:15

遠端（例如 mini）不必把 repo 放過去：

    ssh mini 'python3 -' < scripts/collect-health.py

資料來源：
- 自動化介面開著時讀 `GET /v1/health`（token 取自 ~/.config/chorus/config.json）
- `~/Library/Logs/Chorus/chorus.log`（含輪替檔）：啟動耗時、每 10 分鐘摘要、
  主執行緒卡住事件、慢操作、同步重撥、結束收尾、紀錄丟棄
- 系統：swap、load average、記憶體壓力
"""

import datetime
import glob
import json
import os
import re
import subprocess
import sys
import urllib.request

LOG_DIR = os.path.expanduser("~/Library/Logs/Chorus")
CONFIG = os.path.expanduser("~/.config/chorus/config.json")
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) (\w) \[(\w+)\] (.*)$")
DURATION = re.compile(r"([\d.]+) (ms|s)")


def seconds(text):
    match = DURATION.search(text)
    if not match:
        return None
    value = float(match.group(1))
    return value if match.group(2) == "s" else value / 1000


def read_log_lines(since):
    files = sorted(glob.glob(os.path.join(LOG_DIR, "chorus.*.log")), reverse=True)
    files.append(os.path.join(LOG_DIR, "chorus.log"))
    for path in files:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                match = STAMP.match(raw.rstrip("\n"))
                if not match:
                    continue
                stamp = datetime.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f")
                if since and stamp < since:
                    continue
                yield stamp, match.group(2), match.group(3), match.group(4)


def analyze_log(since):
    report = {
        "launches": [], "startupTimings": [], "hangs": [], "stallRecoveries": [],
        "summaries": [], "slowOperations": {}, "stalledOperations": {},
        "syncRetries": 0, "syncRetryReasons": {}, "exits": [], "logDrops": 0, "errors": 0,
    }
    for stamp, level, category, message in read_log_lines(since):
        when = stamp.isoformat(timespec="seconds")
        if level == "E":
            report["errors"] += 1
        if category == "app" and message.startswith("啟動 "):
            report["launches"].append({"at": when, "line": message.split(" log=")[0]})
        elif category == "app" and message.startswith("啟動耗時"):
            report["startupTimings"].append({"at": when, "line": message})
        elif category == "app" and message.startswith("結束收尾"):
            report["exits"].append({"at": when, "line": message})
        elif category == "health" and message.startswith("主執行緒無回應"):
            report["hangs"].append({"at": when, "pendingSeconds": seconds(message)})
        elif category == "health" and message.startswith("主執行緒恢復回應"):
            report["stallRecoveries"].append({"at": when, "stallSeconds": seconds(message)})
        elif category == "health" and message.startswith("主迴圈（"):
            head = message.split("｜")[0]
            report["summaries"].append({"at": when, "line": head})
        elif category == "health" and message.startswith("慢操作 "):
            name = message.split(" ")[1]
            entry = report["slowOperations"].setdefault(name, {"count": 0, "maxSeconds": 0.0, "last": None})
            entry["count"] += 1
            entry["maxSeconds"] = max(entry["maxSeconds"], seconds(message) or 0)
            entry["last"] = when
        elif category == "health" and message.startswith("操作進行中已"):
            name = message.split("：")[-1]
            report["stalledOperations"][name] = report["stalledOperations"].get(name, 0) + 1
        elif category == "sync" and "後重撥" in message:
            report["syncRetries"] += 1
            reason = re.search(r"（(.*)）", message)
            key = reason.group(1) if reason else "?"
            report["syncRetryReasons"][key] = report["syncRetryReasons"].get(key, 0) + 1
        elif category == "log" and "丟棄" in message:
            report["logDrops"] += 1
    return report


def fetch_health():
    try:
        with open(CONFIG) as handle:
            config = json.load(handle)
        request = urllib.request.Request(
            f"http://127.0.0.1:{config['port']}/v1/health",
            headers={"Authorization": f"Bearer {config['token']}"},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)
    except Exception as error:
        return {"unavailable": str(error)}


def system_state():
    def run(args):
        try:
            return subprocess.run(args, capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception:
            return ""
    pressure = run(["memory_pressure"]).splitlines()
    return {
        "swap": run(["sysctl", "-n", "vm.swapusage"]),
        "uptime": run(["uptime"]),
        "memoryFree": next((line for line in pressure if "free percentage" in line), ""),
        "chorusProcess": run(["pgrep", "-lf", "/Applications/Chorus.app/Contents/MacOS/Chorus"]),
    }


def print_summary(data):
    health, log, system = data["health"], data["log"], data["system"]
    print(f"== Chorus 回應性摘要（{data['collectedAt']}，自 {data['since'] or '紀錄開頭'}）")
    print(f"系統：{system['uptime']}")
    print(f"      swap {system['swap']}；{system['memoryFree']}")
    print(f"行程：{system['chorusProcess'] or '沒有在跑'}")
    if "unavailable" in health:
        print(f"/v1/health：讀不到（{health['unavailable']}）——自動化介面沒開或 App 沒在跑")
    else:
        loop = health["mainLoop"]
        print(f"/v1/health：responsive={loop['responsive']} 卡住 {loop['hangCount']} 次、延遲 {loop['lagCount']} 次、"
              f"最長停頓 {loop['longestStallMs']:.0f} ms、P95≤{loop['p95UpperMs']} ms")
        crash = health.get("crashReports", {})
        print(f"lastExit={health.get('lastExit', '?')} crashReports={crash.get('count', 0)}")
        for item in crash.get("recent", [])[:3]:
            print(f"  {item.get('occurredAt')} {item.get('kind')} build={item.get('appVersion')} {item.get('exception') or ''}")
        slow = sorted(health["operations"].items(), key=lambda item: -item[1]["maxMs"])[:8]
        print("  最慢的操作：" + "；".join(f"{name} {v['maxMs']:.0f} ms（{v['completed']} 次）" for name, v in slow))
        stuck = [name for name, v in health["operations"].items() if v["inFlight"] and (v["oldestInFlightMs"] or 0) > 5000]
        if stuck:
            print("  ⚠️ 在途超過 5 秒：" + "、".join(stuck))
    print(f"啟動：{len(log['launches'])} 次")
    for entry in log["startupTimings"][-3:]:
        print(f"  {entry['at']} {entry['line']}")
    print(f"主執行緒卡住（>2 s）：{len(log['hangs'])} 次；恢復紀錄 {len(log['stallRecoveries'])} 筆")
    for entry in log["stallRecoveries"][-5:]:
        print(f"  {entry['at']} 停頓 {entry['stallSeconds']} s")
    for entry in log["summaries"][-3:]:
        print(f"  {entry['at']} {entry['line']}")
    if log["slowOperations"]:
        print("慢操作（>1 s，同名 60 秒最多記一次）：" + "；".join(
            f"{name} {v['count']} 次、最長 {v['maxSeconds']:.1f} s" for name, v in
            sorted(log["slowOperations"].items(), key=lambda item: -item[1]["maxSeconds"])))
    if log["stalledOperations"]:
        print("在途超過 5 秒的操作：" + "；".join(f"{k} {v} 次" for k, v in log["stalledOperations"].items()))
    print(f"同步重撥：{log['syncRetries']} 次 {log['syncRetryReasons'] or ''}")
    for entry in log["exits"][-3:]:
        print(f"結束：{entry['at']} {entry['line']}")
    print(f"紀錄緩衝丟棄事件：{log['logDrops']} 次；error 等級紀錄 {log['errors']} 行")


def main():
    since = None
    if "--since" in sys.argv:
        since = datetime.datetime.fromisoformat(sys.argv[sys.argv.index("--since") + 1])
    data = {
        "collectedAt": datetime.datetime.now().isoformat(timespec="seconds"),
        "since": since.isoformat() if since else None,
        "health": fetch_health(),
        "log": analyze_log(since),
        "system": system_state(),
    }
    print_summary(data)
    if "--json" in sys.argv:
        path = sys.argv[sys.argv.index("--json") + 1]
        with open(path, "w") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
        print(f"\n完整資料：{path}")


if __name__ == "__main__":
    main()
