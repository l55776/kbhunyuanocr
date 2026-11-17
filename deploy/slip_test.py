# -*- coding: utf-8 -*-
"""用当前运行中的 llama-server 对测试单据图做一次真实的「单据 JSON」抽取验证。"""
import base64, json, sys, time, urllib.request

IMG = r"h:\2026\hunyuanocr\deploy\gen_slip.jpg"
URL = "http://127.0.0.1:8099/v1/chat/completions"

SLIP_PROMPT = r"""你是医药购销/出入库单据的 OCR 结构化解析引擎。仅依据图片输出 1 个合法的 JSON 对象：使用标准 JSON 双引号。
输出的 JSON 必须直接以 { 开始、以 } 结束，严禁使用 ``` / ```json 这类代码围栏，严禁任何前后缀文字或解释。

【第一步 单据头】从图片整体信息读取，均为字符串，缺失给空字符串 ""：
- billNo：单据编号（如 Y1058）
- date：开单日期，保留原样（如 2026年3月26日）
- warehouse：仓库/配送单位/收货单位名称
- cvendername：表头或票头中供货单位公司全称（如 "安徽福仁堂医药有限公司"）

【第二步 表格】逐行识别：表格每一行数据对应 goodsList 中的一个对象，行序与图片一致。请先清点表格中包含几行数据，再逐行完整输出，goodsList 的对象数量必须等于实际数据行数，逐行追加，一个都不能漏、不能合并、不能只输出第一行。表头按下列字段映射为键名，再把该行对应单元格的值逐格填入：
映射：tableHeaderMap = { "代码":"cgoodsid","商品编码":"cgoodsid","名称":"cgoodsname","药品名称":"cgoodsname","商品名称":"cgoodsname","通用名称":"cgoodsname","规格":"cpkname","产品规格":"cpkname","规格型号":"cpkname","剂型":"dosageForm","生产厂家/上市许可证持有人":"cfactoryname","生产厂家":"cfactoryname","注册证号":"cfactoryno","批准文号":"cfactoryno","单位":"cunit","数量":"fqty","出库数量":"fqty","单价":"fprice","金额":"amount","批号":"cph","产品批号":"cph","有效期至":"dexpdate","有效期":"dexpdate","生产日期":"dmadedate","uuid":"uuid" }
未出现在映射中的表头，键名保持原文字段名。对齐：表头顺序必须严格与图片列顺序一致，逐列取值，严禁错位。

【第三步 键与类型】每个对象只包含该行实际存在表头所映射的键；图片中没有的列，绝对不要输出对应键（尤其不要凭空出现 dosageForm、dmadedate、uuid 等键）。fqty/fprice/amount 用数字（去掉￥、逗号与单位，空给 0）；其余字段保持字符串原样。

【注意】表格最后的"合计/总计/小计"行以及页眉、页脚、表外文字一律不要计入 goodsList。

输出结构（goodsList 应包含表格中所有数据行；下面示例仅示意字段，实际按映射生成且键可省略）：
{"billNo":"Y1058","date":"2026年3月26日","warehouse":"","cvendername":"安徽福仁堂医药有限公司","goodsList":[{"cgoodsid":"","cgoodsname":"","cpkname":"","cfactoryname":"","cfactoryno":"","cunit":"","cph":"","dmadedate":"","dexpdate":"","fqty":20,"fprice":0,"amount":0},{"cgoodsid":"","cgoodsname":"","fqty":10,"amount":0}]}"""

with open(IMG, "rb") as f:
    b64 = base64.b64encode(f.read()).decode()
data_url = "data:image/jpeg;base64," + b64

payload = {
    "model": "hunyuanocr",
    "messages": [{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": data_url}},
        {"type": "text", "text": SLIP_PROMPT},
    ]}],
    "max_tokens": 2048,
    "temperature": 0,
    "stream": True,
}
body = json.dumps(payload).encode("utf-8")
req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})

print("submit OCR...", flush=True)
t0 = time.time()
content = ""
try:
    with urllib.request.urlopen(req, timeout=1800) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            d = line[5:].strip()
            if d == "[DONE]":
                break
            try:
                j = json.loads(d)
                seg = (j.get("choices") or [{}])[0].get("delta", {}).get("content", "")
            except Exception:
                continue
            if seg:
                content += seg
                if len(content) % 500 == 0:
                    print(f"...{len(content)} chars  {time.time()-t0:.0f}s", flush=True)
except Exception as e:
    print("ERROR:", e, file=sys.stderr)

el = int(time.time() - t0)
print(f"\n=== elapsed: {el}s  chars: {len(content)} ===")
with open(r"h:\2026\hunyuanocr\deploy\slip_result.txt", "w", encoding="utf-8") as f:
    f.write(content)

print("---- 输出原文 ----")
print(content)

def strip_fence(s):
    return s.strip().replace("```json", "").replace("```", "").strip()

try:
    obj = json.loads(strip_fence(content))
    print("\n[OK] 可解析为合法 JSON")
    print("billNo =", obj.get("billNo"))
    print("date =", obj.get("date"))
    print("cvendername =", obj.get("cvendername"))
    gl = obj.get("goodsList", [])
    print("goodsList rows =", len(gl))
    for i, r in enumerate(gl):
        print(f"  row{i}:", json.dumps(r, ensure_ascii=False))
except Exception as e:
    print("\n[WARN] 未能直接解析为 JSON:", e)
