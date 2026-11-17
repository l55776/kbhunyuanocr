"""Streaming (SSE) smoke test for the local llama-server OCR backend.

Usage:
    python stream_test.py <image_path> [port]

Writes partial tokens to deploy/stream_result.txt so you can watch progress
while the (CPU) model is generating.
"""
import base64
import json
import mimetypes
import sys
import time
import urllib.request

PORT = sys.argv[2] if len(sys.argv) > 2 else "8099"
IMAGE = sys.argv[1] if len(sys.argv) > 1 else r"h:\2026\hunyuanocr\llama_cpp\test_assets\ocr\3.png"
OUT = r"h:\2026\hunyuanocr\deploy\stream_result.txt"
PROMPT = (
    "提取文档图片中正文的所有信息用markdown格式表示，其中页眉、页脚部分忽略，"
    "表格用html格式表达，文档中公式用latex格式表示，按照阅读顺序组织进行解析。"
)

mime = mimetypes.guess_type(IMAGE)[0] or "image/jpeg"
with open(IMAGE, "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")

payload = {
    "model": "hunyuanocr",
    "messages": [{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
        {"type": "text", "text": PROMPT},
    ]}],
    "max_tokens": 2048,
    "temperature": 0,
    "stream": True,
}

req = urllib.request.Request(
    f"http://127.0.0.1:{PORT}/v1/chat/completions",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)

log = open(OUT, "w", encoding="utf-8")
log.write(f"[image] {IMAGE}\n[time] {time.strftime('%Y-%m-%d %H:%M:%S')}\n--- tokens ---\n")
log.flush()
t0 = time.time()
text = []
with urllib.request.urlopen(req, timeout=3600) as r:
    for raw in r:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        try:
            chunk = json.loads(data)
            delta = chunk["choices"][0]["delta"].get("content", "")
            if delta:
                text.append(delta)
                log.write(delta)
                log.flush()
        except Exception:
            pass
log.write(f"\n--- done in {time.time()-t0:.1f}s, {len(''.join(text))} chars ---\n")
log.close()
print("done, result in", OUT)
