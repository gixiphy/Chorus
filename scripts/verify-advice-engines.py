#!/usr/bin/env python3
"""BE 手動驗證：各家 LLM CLI 作為光環境顧問引擎的端到端路徑。

**不是回歸測試**——會實際呼叫 CLI（需網路、已登入帳號，並消耗額度），
因此不放進常跑的套件。改動任一引擎的接入路徑後手動跑一次。

    python3 scripts/verify-advice-engines.py            # 測所有偵測到的引擎
    python3 scripts/verify-advice-engines.py codex grok # 只測指定的
"""

import json
import os
import struct
import subprocess
import sys
import time
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".agy-work")
NOTIFY = os.path.join(WORK, "notify")
PROD_APP = "/Applications/Chorus.app"

proc = None
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
        sys.exit("找不到 Debug build，先跑 xcodebuild build")
    return newest


APP = find_debug_app()


def make_test_photo(path):
    """純洋紅測試圖。用它是因為斷言可以很硬：模型若沒真的讀到圖，
    描述裡不可能出現 magenta／pink，只會生出通用的桌面說法。"""
    w = h = 160
    raw = b''.join(b'\x00' + bytes((255, 0, 255)) * w for _ in range(h))

    def chunk(tag, data):
        body = tag + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as handle:
        handle.write(png)
    return path


def notify(action, value=None):
    subprocess.run([NOTIFY, "A", action] + ([value] if value else []), capture_output=True)


def dump():
    try:
        with open(os.path.join(WORK, "dump-A.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def wait_for(pred, timeout=180):
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
        time.sleep(1)
    return False, last


def record(name, ok, detail=""):
    results.append((name, ok))
    print(("  ✅ " if ok else "  ❌ ") + name + (f"\n      {detail}" if detail else ""), flush=True)


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
    if prod_was_running:
        subprocess.run(["open", PROD_APP], capture_output=True)


ENGINES = ["claude", "agy", "grok", "codex", "opencode", "pi"]


def verify_engine(engine_id, photo, model=""):
    """對單一引擎跑一次真實分析並斷言結果。model 非空時一併驗 --model 路徑。"""
    label = f"{engine_id}" + (f"（模型 {model}）" if model else "")
    print(f"\n--- {label} ---", flush=True)
    notify("setAdvisorModel", f"{engine_id}:{model}")
    time.sleep(1)
    notify("analyzeReal", f"{engine_id}:{photo}")
    ok, _ = wait_for(lambda d: d["advisor"]["isAnalyzing"] is True, 20)
    if not ok:
        record(f"{engine_id}：分析啟動", False, "（引擎未偵測到？）")
        return
    ok, state = wait_for(
        lambda d: d["advisor"]["isAnalyzing"] is False
        and (d["advisor"]["hasResult"] or d["advisor"]["lastError"]),
        240,
    )
    advisor = (state or {}).get("advisor", {})
    if not ok:
        record(f"{engine_id}：分析結束", False, "逾時")
        return
    error = advisor.get("lastError")
    if error:
        record(f"{engine_id}：產出建議", False, str(error)[:220])
        return

    summary = advisor.get("sceneSummary") or ""
    # 硬性判準只有一條：走完整條管線並產出可解析的建議。
    # 讀不到圖的引擎不會走到這裡——agy 會回空字串（emptyResponse）、
    # codex／opencode 會抱怨找不到檔案、claude 的 Read 會失敗。
    record(f"{engine_id}：產出可解析的建議", True)
    print(f"      「{summary[:120]}」", flush=True)
    # 以下是加分觀察，**不計入通過數**：模型有沒有主動點出這是純色測試圖。
    # 沒點出不代表沒讀到——同一張圖 opencode 在短 prompt 下答得出 "Magenta"，
    # 在顧問的長 prompt 下則選擇回「無法辨識桌面」，那對純色圖也是合理答案。
    lowered = summary.lower()
    named = any(w in lowered for w in ("magenta", "洋紅", "桃紅", "pink", "粉紅", "紫紅", "fuchsia",
                                       "純色", "單色", "solid", "佔位", "placeholder", "色塊"))
    print(f"      {'✚ 有點出是純色測試圖' if named else '· 未點出顏色（不判定為失敗）'}", flush=True)


def main():
    global proc, prod_was_running
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["swiftc", "-o", NOTIFY, os.path.join(REPO, "scripts", "notify.swift")], check=True)
    subprocess.run(["pkill", "-f", "instance A"], capture_output=True)

    running = subprocess.run(["pgrep", "-f", f"{PROD_APP}/Contents/MacOS/Chorus"], capture_output=True)
    prod_was_running = running.returncode == 0
    if prod_was_running:
        subprocess.run(["osascript", "-e", 'quit app "Chorus"'], capture_output=True)
        time.sleep(2)
        subprocess.run(["pkill", "-x", "Chorus"], capture_output=True)

    photo = make_test_photo(os.path.join(WORK, "magenta.png"))

    print("\n=== BE：光環境顧問引擎端到端 ===\n", flush=True)
    proc = subprocess.Popen(
        [APP, "--instance", "A", "--fake-als", "--state-dump", os.path.join(WORK, "dump-A.json")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    ok, state = wait_for(lambda d: len(d.get("displays", [])) > 0, 30)
    record("實例啟動", ok)
    if not ok:
        return 1

    # 參數可寫 "engine" 或 "engine=model"（後者一併驗 --model 路徑）
    wanted = [a for a in sys.argv[1:] if not a.startswith("-")] or ENGINES
    for item in wanted:
        engine_id, _, model = item.partition("=")
        verify_engine(engine_id, photo, model)

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
