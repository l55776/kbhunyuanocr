"""Minimal stdlib-only smoke test against the local llama-server (OpenAI-compatible).

Usage:
    python quick_test.py [image_path] [port]
"""
import base64
import json
import mimetypes
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:{port}/v1"

# Official doc_parse task prompt (HunyuanOCR v1.0 / v1.5 通用)
DOC_PARSE_PROMPT = (
    "提取文档图片中正文的所有信息用markdown格式表示，其中页眉、页脚部分忽略，"
    "表格用html格式表达，文档中公式用latex格式表示，按照阅读顺序组织进行解析。"
)


def main():
    port = sys.argv[2] if len(sys.argv) > 2 else "8099"
    image = sys.argv[1] if len(sys.argv) > 1 else r"h:\2026\hunyuanocr\llama_cpp\test_assets\ocr\0.png"
    base = BASE.format(port=port)

    with urllib.request.urlopen(f"{base}/models", timeout=30) as r:
        models = json.loads(r.read())
        model_id = models["data"][0]["id"]
        print("[models]", model_id)

    mime = mimetypes.guess_type(image)[0] or "image/jpeg"
    with open(image, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")
    print(f"[image] {image} ({mime}, {len(b64) // 1024} KB b64)")

    payload = {
        "model": model_id,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
                    {"type": "text", "text": DOC_PARSE_PROMPT},
                ],
            }
        ],
        "max_tokens": 2048,
        "temperature": 0,
    }
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=600) as r:
        data = json.loads(r.read())
    elapsed = time.perf_counter() - t0
    text = data["choices"][0]["message"]["content"]
    usage = data.get("usage", {})
    print(f"[elapsed] {elapsed:.1f}s  prompt_tokens={usage.get('prompt_tokens')} "
          f"completion_tokens={usage.get('completion_tokens')}")
    print("----- OCR OUTPUT -----")
    print(text)


if __name__ == "__main__":
    main()
