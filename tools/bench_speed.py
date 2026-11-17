"""Measure where the time goes for one OCR request against local llama-server.

Splits total latency into:
  1) prefill  (TTFT: image encode + first token)
  2) generate (chars / s)
  3) total

Usage:
    python3 bench_speed.py <image_path> [port]
"""
import base64
import json
import sys
import time
import urllib.request


def main():
    img = sys.argv[1] if len(sys.argv) > 1 else "sample.jpg"
    port = sys.argv[2] if len(sys.argv) > 2 else "8099"
    mime = "image/png" if img.lower().endswith(".png") else "image/jpeg"
    with open(img, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")

    prompt = "提取图中单据信息，用简洁JSON输出关键字段"
    payload = {
        "model": "hunyuanocr",
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (mime, b64)}},
                {"type": "text", "text": prompt},
            ],
        }],
        "max_tokens": 2048,
        "temperature": 0,
        "stream": True,
    }
    req = urllib.request.Request(
        "http://127.0.0.1:%s/v1/chat/completions" % port,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )

    t0 = time.time()
    first = None
    nchars = 0
    for line in urllib.request.urlopen(req, timeout=600):
        s = line.decode("utf-8").strip()
        if not s.startswith("data:"):
            continue
        if s == "data: [DONE]":
            break
        delta = json.loads(s[5:])["choices"][0]["delta"].get("content", "")
        if delta:
            if first is None:
                first = time.time() - t0
            nchars += len(delta)
    t1 = time.time()

    gen = t1 - t0 - first if first is not None else 0.0
    print("1) prefill / TTFT   : %.1f s   (image encode + first char)" % (first or 0.0))
    print("2) generate %d chars : %.1f s   (%.0f char/s)" % (nchars, gen, nchars / max(gen, 1e-9)))
    print("3) total            : %.1f s" % (t1 - t0))


if __name__ == "__main__":
    main()
