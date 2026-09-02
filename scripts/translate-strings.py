#!/usr/bin/env python3
"""用本機的 AI CLI（`claude`，備援 `codex`）當翻譯引擎，把 String Catalog 缺的語言補上。

    scripts/translate-strings.py                 # Localizable + InfoPlist → en
    scripts/translate-strings.py --lang ja       # 另一個語言
    scripts/translate-strings.py --dry-run       # 只列出要翻哪些 key，不呼叫 CLI
    scripts/translate-strings.py --retranslate   # 連已翻好的也重來（改詞彙表後用）
    scripts/translate-strings.py --model opus    # 指定模型（預設用 CLI 自己的預設）
    scripts/translate-strings.py --engine codex  # claude 未登入時改走 codex exec

流程：
1. 讀 catalog，撈出目標語言**沒有**翻譯、且不是 stale 的 key。
2. 不含中日韓文字的 key（`%@ — %@`、`DDC/CI`、`Chorus`）直接照抄，不花 token。
3. 其餘分批（預設 40 條）連同詞彙表、風格規則丟給 `claude -p`，要求回 JSON。
4. 檢查 format specifier（`%@`、`%lld`…）與原文一致；不一致的仍寫回，
   但狀態標 `needs_review`，Xcode 的 catalog 編輯器會把它們標出來。
5. 每批寫回一次，中途被打斷不會白做。

幂等：再跑一次只會翻新增的 key，git diff 只有新增條目。
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Chorus", "Resources")
DEFAULT_CATALOGS = [
    os.path.join(RESOURCES, "Localizable.xcstrings"),
    os.path.join(RESOURCES, "InfoPlist.xcstrings"),
]

# 不含「・」(U+30FB)：它是分隔符號，不算中文
CJK = re.compile(r"[\u3040-\u30fa\u30fc-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff66-\uff9f]")
# Foundation format specifier；結尾孤立的 % 不算（「回到 100%」）
# 不接受空白旗標：「100% passes」不是 specifier
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?[@diufsxXeEgGcaAp]")
COUNT_SPECIFIER = re.compile(r"%(?:\d+\$)?(?:ll|l|h|hh|q|z|t|j)?[diu]")

LANGUAGE_NAMES = {
    "en": "English (US)",
    "ja": "Japanese",
    "zh-Hans": "Simplified Chinese",
    "ko": "Korean",
    "de": "German",
    "fr": "French",
    "es": "Spanish",
}

GLOSSARY = {
    "Chorus": "Chorus（產品名，不翻）",
    "場景": "scene",
    "限時場景": "timed scene",
    "專注": "focus (the timed-scene feature; 「專注中」= Focusing)",
    "跨機": "cross-machine / on another Mac (paired peer)",
    "配對": "pair / pairing",
    "對方": "the other Mac / peer",
    "其他裝置": "other devices",
    "本機": "this Mac",
    "螢幕": "display (hardware); use \"screen\" only for what is shown",
    "顯示器": "display",
    "亮度": "brightness",
    "對比": "contrast",
    "輸入源": "input source",
    "軟體調光": "software dimming (gamma-based)",
    "強制軟體調光": "Force software dimming",
    "自動亮度": "auto-brightness",
    "光感／光線感測器／環境光": "ambient light sensor / ambient light",
    "螢幕長亮": "Keep Awake (the feature); 「長亮中」= keeping awake",
    "待機": "sleep (display sleep / system sleep)",
    "各 App 音量": "Per-app volume",
    "App 音訊接管": "App audio takeover",
    "系統音訊錄製權限": "System Audio Recording permission",
    "效果鏈": "effect chain (Audio Unit effects)",
    "等化／等化器": "EQ / equalizer",
    "前置增益": "preamp",
    "校正檔": "correction profile (AutoEq)",
    "手動 10 段": "Manual 10-band",
    "左右平衡": "balance",
    "軟體音量": "software volume",
    "轉送": "forward (volume forwarding to another device)",
    "鏡射": "mirror",
    "數位音量": "digital volume",
    "排除": "exclude",
    "隱藏的裝置": "hidden devices",
    "預設輸出": "default output",
    "配置圖": "layout (the desk layout diagram)",
    "情境": "scenario (a saved desk lighting scenario)",
    "顧問／建議": "advisor / advice",
    "AI 引擎": "AI engine (an external AI CLI such as Claude Code; also the Settings tab name)",
    "動詞層／動作": "action (in scenes: 「%lld 個動作」= actions)",
    "結束時還原": "restore when the timed scene ends (NOT when the app quits)",
    "限時套用": "apply for a limited time (starts a timed scene)",
    "接續／補送": "resume / retry pending restores",
    "注意事項": "notes (advisor caveats)",
    "還原": "restore",
    "未生效": "did not take effect",
    "選單列": "menu bar",
    "系統設定": "System Settings",
    "隱私權與安全性": "Privacy & Security",
    "螢幕與系統音訊錄製": "Screen & System Audio Recording",
    "輔助使用": "Accessibility",
    "緊急復原": "emergency restore",
    "備份／還原（iCloud）": "back up / restore",
    "綁機設定": "device-bound settings (settings tied to this Mac's hardware)",
}

STYLE_RULES = """\
- Target: macOS menu bar app UI text. Follow Apple's macOS Human Interface Guidelines for English.
- Capitalization: Title Case ONLY for short control labels of at most four English words that are
  clearly a window title, menu item, button, tab, toggle, picker option or section header
  (e.g. "Quit Chorus", "Pair New Device", "Software Dimming").
  EVERYTHING ELSE is sentence case: any full sentence, anything containing 。，：；—— or a
  parenthetical, anything longer than about five words, and all status captions, help/tooltip
  text, footnotes and error messages. When unsure, use sentence case.
- Keep it compact: the menu bar popover is narrow. Short labels must stay short;
  never pad with words that are not in the source. Prefer "Auto" over "Automatic" where the source is 自動 as a badge.
- Keep every format specifier exactly (%@, %lld, %d, %02d, …), same count and same type.
  "%%" is a literal percent sign (e.g. "%lld%%" renders as "42%"); keep it as "%%".
  If English word order requires reordering arguments, switch ALL specifiers in that string
  to positional form (%1$@, %2$lld, …).
- When a %lld / %d is a count of things and the English noun would change between 1 and many,
  return a plural object {"one": "...", "other": "..."} instead of a plain string.
  Do not do this for durations, percentages, hex values or lux readings.
- 「」quotes become straight double quotes “%@” → "%@". Chinese full-width punctuation
  （）：、；—— becomes ASCII equivalents. Use the single-character ellipsis "…".
- Keep untranslated: Chorus, macOS, iCloud Drive, DDC, DDC/CI, VCP, HDMI, DisplayPort, USB-C,
  AutoEq, Audio Unit/AU, Bearer token, CLI, engine names, file paths, hex codes, URLs, and
  anything that looks like an identifier or a command.
- Preserve leading markers such as ▲ and ⓘ, and preserve line breaks.
- Never add explanations, never leave anything in Chinese.
"""


def load_catalog(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_catalog(path, catalog):
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True)
    text = text.replace('": ', '" : ')
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + "\n")


def source_text(key, entry, source_lang):
    unit = entry.get("localizations", {}).get(source_lang, {}).get("stringUnit")
    return unit["value"] if unit and unit.get("value") else key


def has_translation(entry, lang):
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return False
    if "stringUnit" in loc:
        # 空字串 key 的翻譯也是空字串，仍算已翻
        return "value" in loc["stringUnit"]
    return "variations" in loc


def specifiers(text):
    return sorted(m.group(0) for m in SPECIFIER.finditer(text))


def normalized_specifiers(text):
    """去掉位置編號後比對型別與數量：%1$@ 與 %@ 視為同一個。"""
    return sorted(re.sub(r"%\d+\$", "%", s) for s in specifiers(text))


def build_prompt(batch, lang):
    items = [{"id": i, "source": src, "comment": comment} for i, (src, comment) in enumerate(batch)]
    glossary = "\n".join(f"- {k}: {v}" for k, v in GLOSSARY.items())
    return f"""You are localizing the UI of Chorus, a macOS menu bar app that controls display brightness,
audio output volume, per-app volume/EQ, keep-awake timers and cross-machine scenes across paired Macs.
Translate each source string from Traditional Chinese into {LANGUAGE_NAMES.get(lang, lang)}.

Glossary (source term: preferred rendering):
{glossary}

Rules:
{STYLE_RULES}
Input is a JSON array of {{"id", "source", "comment"}}. Reply with ONLY a JSON object, no prose,
no code fences:
{{"translations": [{{"id": 0, "text": "..."}}, {{"id": 1, "plural": {{"one": "...", "other": "..."}}}}]}}

Input:
{json.dumps(items, ensure_ascii=False, indent=1)}
"""


def call_claude(prompt, model):
    args = ["claude", "-p", "--output-format", "json", "--no-session-persistence"]
    if model:
        args += ["--model", model]
    proc = subprocess.run(args, input=prompt, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(f"claude 退出碼 {proc.returncode}\n{proc.stderr}\n{proc.stdout[:500]}")
    envelope = json.loads(proc.stdout)
    if envelope.get("is_error"):
        # 典型：Failed to authenticate: OAuth session expired → 使用者自己跑 `claude /login`
        raise RuntimeError(f"claude 回錯誤：{envelope.get('result')}（若是登入問題，先 `claude /login`，或改 --engine codex）")
    return parse_reply(envelope.get("result", ""))


def call_codex(prompt, model):
    """`codex exec` 沒有 JSON 信封，用 -o 拿最後一則訊息。cwd 指到暫存目錄，免得它去看 repo。"""
    import tempfile
    with tempfile.TemporaryDirectory(prefix="chorus-translate.") as tmp:
        out = os.path.join(tmp, "reply.txt")
        args = ["codex", "exec", "--skip-git-repo-check", "-C", tmp, "-o", out]
        if model:
            args += ["-m", model]
        args.append("-")
        proc = subprocess.run(args, input=prompt, capture_output=True, text=True, timeout=600)
        if proc.returncode != 0 or not os.path.exists(out):
            raise RuntimeError(f"codex 退出碼 {proc.returncode}\n{proc.stderr[-800:]}")
        with open(out, encoding="utf-8") as f:
            return parse_reply(f.read())


ENGINES = {"claude": call_claude, "codex": call_codex}


def parse_reply(result):
    result = re.sub(r"^```(?:json)?\s*|\s*```$", "", result.strip())
    start = result.find("{")
    if start > 0:
        result = result[start:]
    return json.loads(result)["translations"]


def translated_unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def apply_translation(entry, lang, source, item, warnings):
    """把一條回覆寫進 entry；回傳 True 表示有寫。"""
    localizations = entry.setdefault("localizations", {})
    if "plural" in item and isinstance(item["plural"], dict):
        variants = item["plural"]
        if "other" not in variants:
            warnings.append(f"缺 other：{source}")
            return False
        state = "translated"
        for form, text in variants.items():
            if normalized_specifiers(text) != normalized_specifiers(source):
                warnings.append(f"specifier 不符（{form}）：{source!r} → {text!r}")
                state = "needs_review"
        localizations[lang] = {
            "variations": {
                "plural": {form: translated_unit(text, state) for form, text in variants.items()}
            }
        }
        return True
    text = item.get("text")
    if not isinstance(text, str) or not text.strip():
        warnings.append(f"空翻譯：{source}")
        return False
    state = "translated"
    if normalized_specifiers(text) != normalized_specifiers(source):
        warnings.append(f"specifier 不符：{source!r} → {text!r}")
        state = "needs_review"
    if CJK.search(text):
        warnings.append(f"翻譯仍含中文：{source!r} → {text!r}")
        state = "needs_review"
    localizations[lang] = translated_unit(text, state)
    return True


def process_catalog(path, lang, args):
    catalog = load_catalog(path)
    source_lang = catalog.get("sourceLanguage", "zh-Hant")
    strings = catalog.setdefault("strings", {})
    name = os.path.basename(path)

    pending = []
    copied = 0
    for key, entry in strings.items():
        if entry.get("extractionState") == "stale":
            continue
        if not args.retranslate and has_translation(entry, lang):
            continue
        src = source_text(key, entry, source_lang)
        if not CJK.search(src):
            entry.setdefault("localizations", {})[lang] = translated_unit(src)
            copied += 1
            continue
        pending.append((key, src, entry.get("comment", "")))

    print(f"{name}: 照抄 {copied} 條、待翻 {len(pending)} 條 → {lang}")
    if args.dry_run:
        for key, src, _ in pending:
            print(f"  · {src}")
        if copied:
            save_catalog(path, catalog)
        return

    if copied:
        save_catalog(path, catalog)
    if not pending:
        return

    batches = [pending[i:i + args.batch_size] for i in range(0, len(pending), args.batch_size)]
    warnings = []
    written = 0

    def run(batch):
        return ENGINES[args.engine](build_prompt([(src, comment) for _, src, comment in batch], lang), args.model)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run, batch): batch for batch in batches}
        for future in concurrent.futures.as_completed(futures):
            batch = futures[future]
            try:
                translations = future.result()
            except Exception as error:  # noqa: BLE001 — 一批失敗不該拖垮其他批
                print(f"  批次失敗（{len(batch)} 條）：{error}", file=sys.stderr)
                continue
            by_id = {t.get("id"): t for t in translations if isinstance(t, dict)}
            for index, (key, src, _) in enumerate(batch):
                item = by_id.get(index)
                if item is None:
                    warnings.append(f"回覆缺 id {index}：{src}")
                    continue
                if apply_translation(strings[key], lang, src, item, warnings):
                    written += 1
            save_catalog(path, catalog)
            print(f"  已寫回 {written}/{len(pending)}")

    if warnings:
        print(f"{name}: {len(warnings)} 條需人工複審（catalog 內已標 needs_review）：")
        for w in warnings:
            print(f"  ! {w}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lang", default="en", help="目標語言代碼（預設 en）")
    parser.add_argument("--catalog", action="append", help="指定 .xcstrings；可重複。預設 Localizable + InfoPlist")
    parser.add_argument("--engine", choices=sorted(ENGINES), default="claude", help="翻譯引擎 CLI（預設 claude）")
    parser.add_argument("--model", help="傳給引擎的 --model／-m；預設用 CLI 的預設模型")
    parser.add_argument("--batch-size", type=int, default=40)
    parser.add_argument("--jobs", type=int, default=3, help="同時跑幾個 claude 行程")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--retranslate", action="store_true", help="已有翻譯的也重翻")
    args = parser.parse_args()

    for path in args.catalog or DEFAULT_CATALOGS:
        process_catalog(path, args.lang, args)


if __name__ == "__main__":
    main()
