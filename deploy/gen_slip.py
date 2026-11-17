# -*- coding: utf-8 -*-
"""生成一张真实结构的医药销售随货同行单测试图（12 列，含多行数据 + 表外合计行），
用于验证 HunyuanOCR 的「单据 JSON」结构化抽取提示词。"""
from PIL import Image, ImageDraw, ImageFont

FDIR = r"C:\Windows\Fonts"
def F(name, size):
    return ImageFont.truetype(FDIR + "\\" + name, size)

f_title = F("msyhbd.ttc", 28)
f_head  = F("msyh.ttc", 18)
f_body  = F("msyh.ttc", 17)
f_info  = F("msyh.ttc", 20)

headers = ["商品编码","药品名称","规格型号","生产厂家/上市许可证持有人",
           "批准文号","单位","批号","生产日期","有效期至","数量","单价","金额"]
rows = [
    ["SP0001","复方丹参滴丸","180丸/瓶","天士力医药集团股份有限公司",
     "国药准字Z10950111","盒","250302","2025-03-02","2027-02-28","20","35.80","716.00"],
    ["SP0002","阿莫西林胶囊","0.25g×24粒","联邦制药",
     "国药准字H44021518","盒","240915","2024-09-15","2026-08-31","10","12.50","125.00"],
]

info_lines = ["单号：Y1058        开单日期：2026年3月26日",
              "收货仓库：合肥市第一人民医院药库",
              "供货单位：安徽福仁堂医药有限公司"]
footer = "合计：30 盒        金额合计：¥841.00"

pad = 12
col_w = []
for ci in range(len(headers)):
    texts = [headers[ci]] + [r[ci] for r in rows]
    w = max(f_head.getlength(headers[ci]), max(f_body.getlength(t) for t in texts)) + pad
    col_w.append(int(w) + 6)

margin = 20
table_w = sum(col_w)
canvas_w = table_w + 2*margin
row_h = 40
head_h = 44
y_title = 26
y_info = y_title + f_title.size + 14
n_gh = len(info_lines)
y_table = y_info + n_gh*(f_info.size+12) + 20
canvas_h = y_table + head_h + len(rows)*row_h + 20 + f_info.size + 28

img = Image.new("RGB", (canvas_w, canvas_h), "white")
d = ImageDraw.Draw(img)

t = "安徽福仁堂医药有限公司销售随货同行单"
d.text(((canvas_w - d.textlength(t, font=f_title))/2, y_title), t, font=f_title, fill="#111")

yy = y_info
for line in info_lines:
    d.text((margin, yy), line, font=f_info, fill="#222")
    yy += f_info.size + 12

X = margin
Yh = y_table
d.rectangle([margin, Yh, margin+table_w, Yh+head_h], fill="#e8f0fe")
for ci, h in enumerate(headers):
    cw = col_w[ci]
    d.rectangle([X, Yh, X+cw, Yh+head_h], outline="#9ab0d0", width=1)
    d.text((X + (cw - d.textlength(h, font=f_head))/2,
            Yh + (head_h - f_head.size)/2), h, font=f_head, fill="#123")
    X += cw

Yr = Yh + head_h
for ri, row in enumerate(rows):
    X = margin
    fill = "#ffffff" if ri % 2 == 0 else "#f7fafd"
    d.rectangle([margin, Yr, margin+table_w, Yr+row_h], fill=fill)
    for ci, cell in enumerate(row):
        cw = col_w[ci]
        d.rectangle([X, Yr, X+cw, Yr+row_h], outline="#c3cee0", width=1)
        align = "right" if cell.replace(".","").isdigit() else "center"
        d.text((X + 4, Yr + (row_h - f_body.size)/2), cell, font=f_body, fill="#222")
        X += cw
    Yr += row_h

d.text((margin + 8, Yr + 8), footer, font=f_info, fill="#444")

out = r"h:\2026\hunyuanocr\deploy\gen_slip.jpg"
img.save(out, "JPEG", quality=92)
print("saved:", out, img.size)
