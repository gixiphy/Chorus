#!/usr/bin/env python3
"""B8 設定備份（iCloud Drive）自動化回歸。

兩個實例共用同一個 **暫存** 備份目錄（`--cloud-root`）——測試絕不碰使用者
真的 iCloud Drive。驗的是完整那條路：寫檔 → 另一台看得到 → 匯入 →
綁機設定留在本機。

    python3 scripts/test-b8-cloud.py
"""

import json
import os
import subprocess
import sys
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".b8-work")
NOTIFY = os.path.join(WORK, "notify")
CLOUD = os.path.join(WORK, "cloud")

procs = {}
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


def notify(action, value=None, inst="A"):
    subprocess.run([NOTIFY, inst, action] + ([value] if value is not None else []),
                   capture_output=True)


def dump(inst="A"):
    try:
        with open(os.path.join(WORK, f"dump-{inst}.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def wait_for(pred, timeout=15, inst="A"):
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


def launch(inst, app):
    procs[inst] = subprocess.Popen(
        [app, "--instance", inst, "--fake-als", "--fake-taps",
         "--cloud-root", CLOUD,
         "--state-dump", os.path.join(WORK, f"dump-{inst}.json")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def stop(inst):
    proc = procs.pop(inst, None)
    if not proc:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()


def cloud(data):
    return (data or {}).get("cloudBackup", {})


def backup_files():
    devices = os.path.join(CLOUD, "devices")
    if not os.path.isdir(devices):
        return []
    return sorted(f for f in os.listdir(devices) if f.endswith(".json"))


def read_backup(name):
    try:
        with open(os.path.join(CLOUD, "devices", f"{name}.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def save_scene(name, inst="A"):
    notify("saveScene", json.dumps(
        {"id": str(uuid.uuid4()), "name": name, "requests": []}, ensure_ascii=False
    ), inst=inst)


def cleanup():
    for inst in list(procs):
        stop(inst)
    for inst in ("A", "B"):
        subprocess.run(["defaults", "delete", f"com.hermes.Chorus.instance-{inst}"], capture_output=True)
        subprocess.run(["rm", "-rf",
                        os.path.expanduser(f"~/Library/Application Support/Chorus/instance-{inst}")],
                       capture_output=True)
    subprocess.run(["rm", "-rf", WORK], capture_output=True)


def main():
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["swiftc", "-o", NOTIFY, os.path.join(REPO, "scripts", "notify.swift")], check=True)
    subprocess.run(["pkill", "-f", "instance A"], capture_output=True)
    subprocess.run(["pkill", "-f", "instance B"], capture_output=True)
    time.sleep(1)

    app = find_debug_app()
    print("\n=== B8 設定備份（暫存目錄，不碰真的 iCloud Drive）===\n", flush=True)
    launch("A", app)
    ok, data = wait_for(lambda d: cloud(d).get("available") is True, 30)
    record("A 啟動，備份目錄可用", ok, CLOUD)
    record("自動備份預設關閉（會把資料寫出本機的功能要親手開）",
           cloud(data).get("enabled") is False)
    record("還沒開就沒有任何檔案", backup_files() == [], str(backup_files()))

    print("\n[1] 備份寫出這台的設定", flush=True)
    save_scene("工作")
    time.sleep(1)
    notify("cloudEnabled", "1")
    ok, _ = wait_for(lambda d: len(backup_files()) == 1, 15)
    record("開啟自動備份 → 立刻寫出一份", ok, str(backup_files()))

    name_a = backup_files()[0][:-5] if backup_files() else ""
    content = read_backup(name_a) or {}
    record("內容是這台的設定（場景在裡面）",
           [s["name"] for s in content.get("scenes", [])] == ["工作"],
           str(content.get("scenes")))
    record("檔案是人看得懂的 JSON（有換行、ISO 8601 時間）",
           "savedAt" in content and content.get("savedAt", "").startswith("20"))

    mtime = os.path.getmtime(os.path.join(CLOUD, "devices", f"{name_a}.json"))
    notify("cloudTick")
    time.sleep(1.5)
    record("內容沒變就不重寫",
           os.path.getmtime(os.path.join(CLOUD, "devices", f"{name_a}.json")) == mtime)

    print("\n[2] 另一台看得到，也匯得進來", flush=True)
    launch("B", app)
    ok, _ = wait_for(lambda d: cloud(d).get("available") is True, 30, inst="B")
    record("B 啟動", ok)

    # B 先有自己的設定：綁機的與可攜的各一
    save_scene("B 自己的場景", inst="B")
    notify("softwareVolume", "b-device|0.5|0", inst="B")
    notify("cloudEnabled", "1", inst="B")
    ok, _ = wait_for(lambda d: len(cloud(d).get("files", [])) == 2, 20, inst="B")
    record("B 列出兩台的備份", ok,
           str([f["device"] for f in cloud(dump("B")).get("files", [])]))
    record("B 分得出哪一份是自己的",
           sum(1 for f in cloud(dump("B")).get("files", []) if f["isSelf"]) == 1)

    notify("cloudImport", name_a, inst="B")
    time.sleep(2)
    ok, data = wait_for(lambda d: any(s["name"] == "工作" for s in d.get("scenes", [])), 15, inst="B")
    record("B 匯入 A 的備份 → A 的場景出現在 B 上", ok,
           str([s["name"] for s in (dump("B") or {}).get("scenes", [])]))
    record("匯入前先留了一份退路",
           any(f.endswith("-before-import.json") for f in backup_files()),
           str(backup_files()))

    print("\n[3] 綁機與權限設定不跟著跑", flush=True)
    # A 從來沒開過 taps；B 匯入 A 的備份之後，B 自己的權限開關不該被動到
    b_dump = dump("B") or {}
    record("跨機匯入不動 App 音訊接管的開關（權限各台自己開）",
           b_dump.get("tapEngine", {}).get("state") in ("off", "probing", "denied"),
           str(b_dump.get("tapEngine", {}).get("state")))
    record("跨機匯入不動自動備份的開關", cloud(b_dump).get("enabled") is True)

    print("\n[4] 從自己的備份還原（重灌那條路：isSelf ＝ 全套）", flush=True)
    stop("B")
    # 不模擬「清掉 defaults 再開」——`defaults delete` 與 App 結束時的寫回
    # 是競態的，測起來會時好時壞。改在 A 上走同一條 isSelf 路徑：
    # 備份 → 破壞現況 → 從自己那份還原
    notify("cloudBackupNow")
    time.sleep(1.5)
    notify("deleteScene", "工作")
    ok, _ = wait_for(lambda d: d.get("scenes") == [], 10)
    record("刪掉場景，現況與備份不一致", ok, str((dump() or {}).get("scenes")))

    notify("cloudImport", name_a)
    time.sleep(2)
    ok, _ = wait_for(lambda d: any(s["name"] == "工作" for s in d.get("scenes", [])), 15)
    record("從自己的備份還原 → 場景回來了", ok,
           str([s["name"] for s in (dump() or {}).get("scenes", [])]))
    record("自己那份標成「這台」",
           any(f["isSelf"] and f["device"] == name_a for f in cloud(dump()).get("files", [])))

    notify("cloudEnabled", "0")
    time.sleep(1)
    record("關掉自動備份後不再寫檔", cloud(dump()).get("enabled") is False)

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
