#!/usr/bin/env python3
"""Model shoot-out for burst-photo judging, decoupled from the app.

Runs the same judge task the app uses (pick the best of N similar photos,
with a reason per photo) across every available backend, then writes an
HTML report showing the photos and each model's pick so a human can
confirm which model did the right thing.

Usage:
  python3 judge_eval.py --dir ~/Desktop/burst7        # real burst (e.g. 7 exported photos)
  python3 judge_eval.py --dir ~/Desktop/burst7 --answer 3   # you know photo 3 is best
  python3 judge_eval.py --models google/gemma-4-12b-qat qwen/qwen3-vl-4b

Backends:
  - every vision model loaded/available in LM Studio (localhost:1234)
  - Gemma on Google AI Studio, if a key is available via $GEMINI_API_KEY
    or the app's Keychain entry (read via `security`, never printed)

Only Python stdlib is used.
"""

import argparse
import base64
import html
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

LMSTUDIO = "http://127.0.0.1:1234/v1"
AISTUDIO = "https://generativelanguage.googleapis.com/v1beta"
MAX_PER_CALL = 3  # mirror the app's tournament group size


def prompt(count: int) -> str:
    return (
        f"You are helping a user pick the best photo from a burst of {count} "
        f"similar photos, shown in order and numbered 1 to {count}. "
        "Judge sharpness/focus, motion blur, whether eyes are open, facial "
        "expressions, framing/composition, and exposure. "
        'Respond with JSON only, no other text: "keep_index" = the 1-based '
        f'number of the single best photo, and "reasons" = exactly {count} '
        "short strings (max 12 words each), where reason N explains photo N's "
        "main strength or flaw. Your reply MUST start with the character '{' — "
        "no analysis, no preamble, no markdown fences, just the JSON object."
    )


def http_json(url: str, body=None, headers=None, timeout=600):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers or {})
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def parse_verdict(text: str, count: int):
    start = text.find("{")
    if start < 0:
        raise ValueError(f"no JSON in output: {text[:200]!r}")
    raw, _ = json.JSONDecoder().raw_decode(text[start:])
    keep = min(max(int(raw["keep_index"]) - 1, 0), count - 1)
    reasons = list(raw.get("reasons", []))[:count]
    reasons += [""] * (count - len(reasons))
    return keep, reasons


def judge_lmstudio(jpegs, model):
    content = [{"type": "text", "text": prompt(len(jpegs))}]
    for j in jpegs:
        content.append({
            "type": "image_url",
            "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(j).decode()},
        })
    schema = {
        "type": "object",
        "properties": {
            "keep_index": {"type": "integer", "minimum": 1, "maximum": len(jpegs)},
            "reasons": {"type": "array", "items": {"type": "string"},
                        "minItems": len(jpegs), "maxItems": len(jpegs)},
        },
        "required": ["keep_index", "reasons"],
        "additionalProperties": False,
    }
    body = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "verdict", "strict": True,
                                            "schema": schema}},
        "temperature": 0.2,
        "max_tokens": 6000,
    }
    r = http_json(f"{LMSTUDIO}/chat/completions", body)
    return parse_verdict(r["choices"][0]["message"].get("content") or "", len(jpegs))


def judge_aistudio(jpegs, model, key):
    parts = [{"text": prompt(len(jpegs))}]
    for j in jpegs:
        parts.append({"inline_data": {"mime_type": "image/jpeg",
                                      "data": base64.b64encode(j).decode()}})
    body = {"contents": [{"parts": parts}],
            "generationConfig": {"temperature": 0.2, "maxOutputTokens": 8000}}
    r = http_json(f"{AISTUDIO}/models/{model}:generateContent", body,
                  headers={"x-goog-api-key": key}, timeout=300)
    text = "".join(p.get("text", "")
                   for p in r["candidates"][0]["content"]["parts"])
    return parse_verdict(text, len(jpegs))


def balanced_chunks(items, max_size):
    n = len(items)
    groups = -(-n // max_size)
    base, rem = divmod(n, groups)
    out, cur = [], 0
    for _ in range(groups):
        size = base + (1 if rem > 0 else 0)
        rem -= 1
        out.append(items[cur : cur + size])
        cur += size
    return out


def judge_cluster(jpegs, call):
    """Tournament identical to the app: groups of <=3, winners to a final."""
    reasons = [""] * len(jpegs)
    contenders = list(range(len(jpegs)))
    while len(contenders) > MAX_PER_CALL:
        winners = []
        for group in balanced_chunks(contenders, MAX_PER_CALL):
            if len(group) == 1:
                winners.append(group[0])
                continue
            keep, rs = call([jpegs[i] for i in group])
            for k, orig in enumerate(group):
                reasons[orig] = rs[k]
            winners.append(group[keep])
        contenders = winners
    if len(contenders) == 1:
        return contenders[0], reasons
    keep, rs = call([jpegs[i] for i in contenders])
    for k, orig in enumerate(contenders):
        reasons[orig] = rs[k]
    return contenders[keep], reasons


def aistudio_key():
    import os
    if os.environ.get("GEMINI_API_KEY"):
        return os.environ["GEMINI_API_KEY"]
    try:
        for svc in ("com.surendran.whittle", "com.surendran.culler"):
            out = subprocess.run(
                ["security", "find-generic-password", "-s", svc,
                 "-a", "aistudio-api-key", "-w"],
                capture_output=True, text=True, timeout=30)
            if out.stdout.strip():
                return out.stdout.strip()
        return None
    except Exception:
        return None


def discover_backends(only_models):
    backends = []  # (label, callable)
    try:
        models = [m["id"] for m in http_json(f"{LMSTUDIO}/models", timeout=10)["data"]]
        for m in models:
            if "embed" in m or "nemotron" in m or "glm" in m:
                continue  # text-only / won't fit in RAM alongside others
            if only_models and m not in only_models:
                continue
            backends.append((f"{m} (local)",
                             lambda js, m=m: judge_lmstudio(js, m)))
    except Exception as e:
        print(f"LM Studio unreachable: {e}", file=sys.stderr)

    key = aistudio_key()
    if key:
        try:
            models = http_json(f"{AISTUDIO}/models?pageSize=1000",
                               headers={"x-goog-api-key": key}, timeout=30)
            gemmas = [m["name"].removeprefix("models/")
                      for m in models.get("models", [])
                      if "gemma" in m["name"].lower()
                      and "generateContent" in (m.get("supportedGenerationMethods") or [])]
            for m in sorted(gemmas, reverse=True)[:1]:  # largest one
                if only_models and m not in only_models:
                    continue
                backends.append((f"{m} (AI Studio)",
                                 lambda js, m=m: judge_aistudio(js, m, key)))
        except Exception as e:
            print(f"AI Studio unavailable: {e}", file=sys.stderr)
    else:
        print("No AI Studio key (set GEMINI_API_KEY or save it in the app).",
              file=sys.stderr)
    return backends


def load_images(directory):
    import tempfile
    exts = {".jpg", ".jpeg", ".png", ".heic"}
    paths = sorted(p for p in Path(directory).iterdir()
                   if p.suffix.lower() in exts)
    jpegs = []
    # Private (0700) scratch dir — photo copies must not be readable by
    # other local users, which fixed names in /tmp would allow.
    tmpdir = Path(tempfile.mkdtemp(prefix="whittle-eval-"))
    for p in paths:
        # Downscale to 768px JPEG — same size the app sends to the judge.
        tmp = tmpdir / (p.stem + "_eval.jpg")
        subprocess.run(["sips", "-Z", "768", "-s", "format", "jpeg",
                        "-s", "formatOptions", "70", str(p), "--out", str(tmp)],
                       capture_output=True, timeout=60)
        jpegs.append(tmp.read_bytes())
        tmp.unlink(missing_ok=True)
    tmpdir.rmdir()
    return paths, jpegs


def write_report(paths, jpegs, results, answer, out_path):
    rows = []
    for label, seconds, keep, reasons, error in results:
        if error:
            verdict = f'<td colspan="2" class="err">{html.escape(error)}</td>'
        else:
            mark = ""
            if answer is not None:
                mark = " ✅" if keep == answer - 1 else " ❌"
            verdict = (f"<td><b>Photo {keep + 1}</b>{mark}</td>"
                       f"<td>{html.escape(reasons[keep])}</td>")
        rows.append(f"<tr><td>{html.escape(label)}</td>"
                    f"<td>{seconds:.1f}s</td>{verdict}</tr>")

    photos = "".join(
        f'<figure><img src="data:image/jpeg;base64,{base64.b64encode(j).decode()}">'
        f"<figcaption>Photo {i + 1} — {html.escape(p.name)}</figcaption></figure>"
        for i, (p, j) in enumerate(zip(paths, jpegs)))

    out_path.write_text(f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Culler judge eval</title><style>
body{{font-family:-apple-system,sans-serif;margin:24px;background:#111;color:#eee}}
.photos{{display:flex;flex-wrap:wrap;gap:12px}}
figure{{margin:0;text-align:center}}
img{{max-width:260px;border-radius:8px}}
figcaption{{font-size:12px;color:#999;margin-top:4px}}
table{{border-collapse:collapse;margin-top:24px;width:100%}}
td,th{{border:1px solid #333;padding:8px 12px;text-align:left}}
.err{{color:#f90}}
</style></head><body>
<h1>Which photo should be kept?</h1>
<p>Look at the photos, decide the right answer yourself, then see which model agrees with you.</p>
<div class="photos">{photos}</div>
<table><tr><th>Model</th><th>Time</th><th>Pick</th><th>Reason for its pick</th></tr>
{''.join(rows)}</table>
</body></html>""")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True,
                    help="folder of burst photos (export ~7 from Photos)")
    ap.add_argument("--answer", type=int,
                    help="1-based index of the photo YOU consider best (optional)")
    ap.add_argument("--models", nargs="*",
                    help="restrict to these model ids")
    args = ap.parse_args()

    paths, jpegs = load_images(args.dir)
    if len(jpegs) < 2:
        sys.exit(f"Need at least 2 images in {args.dir}, found {len(jpegs)}")
    print(f"Burst: {len(jpegs)} photos from {args.dir}")

    backends = discover_backends(args.models)
    if not backends:
        sys.exit("No backends available.")
    print(f"Backends: {[b[0] for b in backends]}\n")

    results = []
    for label, call in backends:
        t0 = time.time()
        try:
            keep, reasons = judge_cluster(jpegs, call)
            dt = time.time() - t0
            suffix = ""
            if args.answer is not None:
                suffix = " ✅" if keep == args.answer - 1 else " ❌"
            print(f"{label}: {dt:.1f}s → Photo {keep + 1}{suffix} — {reasons[keep]}")
            results.append((label, dt, keep, reasons, None))
        except Exception as e:
            dt = time.time() - t0
            print(f"{label}: {dt:.1f}s → ERROR {e}")
            results.append((label, dt, None, None, str(e)))

    report = Path(args.dir) / "eval_report.html"
    write_report(paths, jpegs, results, args.answer, report)
    print(f"\nReport: {report}  (open it to confirm which model was right)")


if __name__ == "__main__":
    main()
