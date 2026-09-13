#!/usr/bin/env python3
"""Batch D：本機 HTTP 自動化介面的限額、期限與健康檢查（不寫任何硬體）。

一個 Debug 實例（假光感、假 tap），用暫存 port 開自動化介面，驗：
- 認證與 Host 檢查仍在；/v1/health 在背景回應
- 批次指令上限、不完整請求的絕對期限、連線數上限
- 事件流上限；對方正常關閉（FIN）後名額立刻還回來
- 主執行緒卡住時：/v1/health 照樣回、說 responsive=false；/v1/state 期限到回 504

    python3 scripts/test-d-http.py
"""

import json
import os
import socket
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
WORK = os.path.join(REPO, ".d-work")
NOTIFY = os.path.join(WORK, "notify")
PORT = 55791

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
    subprocess.run([NOTIFY, inst, action] + ([value] if value is not None else []), capture_output=True)


def dump(inst="A"):
    try:
        with open(os.path.join(WORK, f"dump-{inst}.json")) as handle:
            return json.load(handle)
    except Exception:
        return None


def wait_for(pred, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        data = dump()
        if data:
            try:
                if pred(data):
                    return True, data
            except Exception:
                pass
        time.sleep(0.4)
    return False, dump()


def record(name, ok, detail=""):
    results.append((name, ok))
    print(("  ✅ " if ok else "  ❌ ") + name + (f"  — {detail}" if detail else ""), flush=True)


def raw_request(text, timeout=15.0):
    """送原始 HTTP，回 (status, body, 花費秒數)。連線被關而沒有回應時 status 為 None。"""
    started = time.time()
    chunks = []
    with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as sock:
        try:
            sock.sendall(text.encode())
            while True:
                data = sock.recv(65536)
                if not data:
                    break
                chunks.append(data)
        except (socket.timeout, ConnectionResetError, BrokenPipeError):
            # 伺服器回完就關（或直接拒絕）：已經收到的部分照樣判讀
            pass
    raw = b"".join(chunks).decode("utf-8", "replace")
    status = None
    if raw.startswith("HTTP/1.1 "):
        status = int(raw.split(" ")[1])
    body = raw.split("\r\n\r\n", 1)[1] if "\r\n\r\n" in raw else ""
    return status, body, time.time() - started


def request(method, path, token, body=None, host="127.0.0.1", timeout=15.0):
    payload = json.dumps(body) if body is not None else ""
    text = (f"{method} {path} HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {token}\r\n"
            f"Content-Type: application/json\r\nContent-Length: {len(payload.encode())}\r\n\r\n{payload}")
    return raw_request(text, timeout=timeout)


def open_stream(token):
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    sock.sendall((f"GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\n\r\n").encode())
    head = sock.recv(4096).decode("utf-8", "replace")
    return sock, head


def cleanup():
    for proc in procs.values():
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
    subprocess.run(["defaults", "delete", "com.hermes.Chorus.instance-A"], capture_output=True)
    subprocess.run(["security", "delete-generic-password", "-s", "com.hermes.Chorus.instance-A"], capture_output=True)
    subprocess.run(["rm", "-rf", WORK], capture_output=True)


def main():
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["swiftc", "-o", NOTIFY, os.path.join(REPO, "scripts", "notify.swift")], check=True)
    subprocess.run(["pkill", "-f", "instance A"], capture_output=True)
    time.sleep(1)
    app = find_debug_app()
    procs["A"] = subprocess.Popen(
        [app, "--instance", "A", "--fake-als", "--fake-taps", "--cloud-root", os.path.join(WORK, "cloud"),
         "--state-dump", os.path.join(WORK, "dump-A.json")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    print("\n=== Batch D：HTTP 自動化介面的限額與期限 ===\n", flush=True)
    ok, _ = wait_for(lambda d: d.get("responsiveness", {}).get("mainLoop", {}).get("running"), 30)
    if not ok:
        record("實例啟動", False)
        return
    notify("automationServer", f"1:{PORT}")
    ok, state = wait_for(lambda d: d["automationServer"]["running"] is True, 15)
    token = (state or {}).get("automationServer", {}).get("token")
    record("HTTP 介面啟動", bool(ok and token))
    if not token:
        return

    print("\n[1] 認證與健康檢查", flush=True)
    status, _, _ = request("GET", "/v1/health", "wrong")
    record("錯誤 token → 401", status == 401, str(status))
    status, _, _ = request("GET", "/v1/health", token, host="evil.example")
    record("錯誤 Host → 403", status == 403, str(status))
    status, body, _ = request("GET", "/v1/health", token)
    health = json.loads(body) if status == 200 else {}
    record("/v1/health → 200，主迴圈 responsive", status == 200 and health.get("mainLoop", {}).get("responsive") is True,
           f"{status} {health.get('mainLoop')}")
    status, _, _ = request("GET", "/v1/state", token)
    record("/v1/state 仍正常", status == 200, str(status))

    print("\n[2] 批次上限", flush=True)
    probe = {"verb": "get", "target": "system", "property": "keepAwake"}
    status, body, _ = request("POST", "/v1/command", token, [probe] * 64)
    record("64 筆批次 → 200", status == 200, str(status))
    status, body, _ = request("POST", "/v1/command", token, [probe] * 65)
    record("65 筆批次 → 413 tooManyCommands", status == 413 and "tooManyCommands" in body, f"{status} {body[:80]}")

    print("\n[3] 不完整請求有絕對期限", flush=True)
    status, _, elapsed = raw_request(
        f"GET /v1/state HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\n", timeout=20)
    record("標頭沒送完 → 約 10 秒後 408", status == 408 and 9 <= elapsed <= 13, f"{status}，{elapsed:.1f} 秒")

    print("\n[4] 連線數上限", flush=True)
    idle = [socket.create_connection(("127.0.0.1", PORT), timeout=5) for _ in range(16)]
    time.sleep(0.5)
    status, body, elapsed = request("GET", "/v1/health", token, timeout=5)
    record("16 條閒置連線佔滿後第 17 條 → 503", status == 503, f"{status}，{elapsed:.2f} 秒")
    for sock in idle:
        sock.close()
    time.sleep(0.8)
    status, _, _ = request("GET", "/v1/health", token)
    record("閒置連線關掉後名額還回來", status == 200, str(status))

    print("\n[5] 事件流上限與 FIN 釋放", flush=True)
    streams = [open_stream(token) for _ in range(4)]
    record("4 條事件流 → 200", all(head.startswith("HTTP/1.1 200") for _, head in streams))
    status, _, _ = request("GET", "/v1/events", token, timeout=5)
    record("第 5 條事件流 → 503", status == 503, str(status))
    streams[0][0].shutdown(socket.SHUT_WR)
    streams[0][0].close()
    time.sleep(1.0)
    sock, head = open_stream(token)
    record("一條正常關閉（FIN）後可以再開", head.startswith("HTTP/1.1 200"), head.split("\r\n")[0])
    sock.close()
    for stream, _ in streams[1:]:
        stream.close()
    time.sleep(0.8)

    print("\n[6] 主執行緒卡住", flush=True)
    notify("blockMainThread", "14")
    time.sleep(3.5)
    status, body, elapsed = request("GET", "/v1/health", token, timeout=5)
    health = json.loads(body) if status == 200 else {}
    record("卡住期間 /v1/health 仍在 1 秒內回應", status == 200 and elapsed < 1.0, f"{status}，{elapsed:.2f} 秒")
    record("而且回報 responsive=false", health.get("mainLoop", {}).get("responsive") is False,
           str(health.get("mainLoop")))
    status, body, elapsed = request("GET", "/v1/state", token, timeout=20)
    record("/v1/state 期限到回 504", status == 504 and elapsed < 12, f"{status}，{elapsed:.1f} 秒")
    time.sleep(4)
    status, body, _ = request("GET", "/v1/health", token)
    health = json.loads(body) if status == 200 else {}
    record("解除後 responsive 恢復", health.get("mainLoop", {}).get("responsive") is True, str(health.get("mainLoop")))
    status, _, _ = request("GET", "/v1/state", token)
    record("解除後 /v1/state 正常", status == 200, str(status))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        import traceback
        traceback.print_exc()
        record(f"腳本例外：{error!r}", False)
    finally:
        passed = sum(1 for _, ok in results if ok)
        print(f"\n{passed}/{len(results)} 通過", flush=True)
        cleanup()
        sys.exit(0 if results and passed == len(results) else 1)
