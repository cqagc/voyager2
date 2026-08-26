#!/usr/bin/env python3
"""生成 Voyager 2 数字孪生的应用图标。

设计取自金唱片封面上最具辨识度的那个元素：脉冲星定位图的星芒。
这是**风格化**的致敬，不是那张图的准确复刻 —— 我没有把握准确记住那 14 颗
脉冲星的方位，编一张假的星图没有意义（同样的理由，游戏里也没有程序化画它，
而是直接展示 NASA 模型自带的真实蚀刻贴图）。

叠加一条橙色的双曲线航迹和末端的探测器光点，对应孪生体的主题：
一条永不返回的轨迹。

产出：
  assets/generated/icon/icon_1024.png   主图标
  assets/generated/icon/icon.icns       macOS
  assets/generated/icon/icon.ico        Windows
  godot/icon.png                        Godot 项目内图标（256）
"""

import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

SS = 4  # 超采样倍率，最后降采样得到抗锯齿
SIZE = 1024
W = SIZE * SS

GOLD = (214, 168, 74)
GOLD_BRIGHT = (247, 214, 138)
ORANGE = (255, 128, 48)
ORANGE_HOT = (255, 208, 150)


def radial_background(img):
    """深空底色：中心略亮的径向渐变。"""
    px = img.load()
    cx = cy = W / 2
    maxr = W * 0.72
    for y in range(W):
        dy = y - cy
        for x in range(W):
            dx = x - cx
            t = min(1.0, math.hypot(dx, dy) / maxr)
            # 由中心的深蓝灰过渡到近黑
            r = int(20 * (1 - t) + 5 * t)
            g = int(26 * (1 - t) + 6 * t)
            b = int(42 * (1 - t) + 11 * t)
            px[x, y] = (r, g, b, 255)


def grooves(draw):
    """唱片纹路：一圈圈极淡的同心圆。"""
    cx = cy = W / 2
    for i in range(20):
        rr = W * (0.17 + i * 0.0122)
        a = 40 if i % 2 == 0 else 22
        draw.ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
                     outline=GOLD + (a,), width=int(W * 0.0016))


def pulsar_burst(draw):
    """风格化的脉冲星星芒。14 条长度不一的射线，向外发散。

    长度序列是刻意做成不规则的 —— 真图上每条射线的长度编码着对应脉冲星的
    周期，所以「不等长」本身是这个图形的灵魂。这里的具体数值是设计取值，
    不代表任何真实脉冲星。
    """
    cx = cy = W / 2
    lengths = [0.98, 0.62, 0.86, 0.44, 0.74, 0.55, 0.93,
               0.50, 0.80, 0.68, 0.40, 0.90, 0.58, 0.76]
    n = len(lengths)
    base = W * 0.062
    span = W * 0.290
    for i, f in enumerate(lengths):
        ang = -math.pi / 2 + i * (2 * math.pi / n) + 0.11
        r0 = base
        r1 = base + span * f
        x0, y0 = cx + r0 * math.cos(ang), cy + r0 * math.sin(ang)
        x1, y1 = cx + r1 * math.cos(ang), cy + r1 * math.sin(ang)
        draw.line([x0, y0, x1, y1], fill=GOLD_BRIGHT + (235,), width=int(W * 0.0075))
        # 末端小刻度，模拟真图上的二进制周期标记
        px_, py_ = -math.sin(ang), math.cos(ang)
        t = W * 0.014
        draw.line([x1 + px_ * t, y1 + py_ * t, x1 - px_ * t, y1 - py_ * t],
                  fill=GOLD_BRIGHT + (200,), width=int(W * 0.0055))
    # 中心：太阳
    r = W * 0.026
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=GOLD_BRIGHT + (255,))


def trajectory(draw):
    """双曲线航迹 + 末端的探测器光点。一条永不返回的轨迹。

    刻意让整条曲线连同末端光点都落在画幅内 —— 图标在 32 px 下要能成形，
    跑出边界的线条会被裁成一根没有来由的斜杠。
    """
    cx = cy = W / 2
    pts = []
    for i in range(300):
        t = -1.28 + i * (2.42 / 299)
        hx = 0.30 * math.cosh(t)
        hy = 0.62 * math.sinh(t)
        a = math.radians(-38)
        rx = hx * math.cos(a) - hy * math.sin(a)
        ry = hx * math.sin(a) + hy * math.cos(a)
        pts.append((cx + rx * W * 0.335 - W * 0.055,
                    cy + ry * W * 0.335 + W * 0.020))
    draw.line(pts, fill=ORANGE + (225,), width=int(W * 0.0105), joint="curve")
    # 探测器：整幅图里唯一的高亮点，落在画幅内。
    ex, ey = pts[-1]
    r = W * 0.026
    draw.ellipse([ex - r * 2.1, ey - r * 2.1, ex + r * 2.1, ey + r * 2.1],
                 fill=ORANGE + (70,))
    draw.ellipse([ex - r, ey - r, ex + r, ey + r], fill=ORANGE_HOT + (255,))


def rim(draw):
    """外圈：把内容框住，小尺寸下更成形。"""
    cx = cy = W / 2
    rr = W * 0.428
    draw.ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
                 outline=GOLD + (120,), width=int(W * 0.006))


def build() -> Image.Image:
    img = Image.new("RGBA", (W, W), (0, 0, 0, 255))
    radial_background(img)

    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    grooves(d)
    rim(d)
    pulsar_burst(d)
    trajectory(d)

    # 辉光：把亮部模糊后叠加，得到发光感
    glow = layer.filter(ImageFilter.GaussianBlur(W * 0.010))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, layer)

    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> int:
    out_dir = os.path.join("assets", "generated", "icon")
    os.makedirs(out_dir, exist_ok=True)
    icon = build()

    png = os.path.join(out_dir, "icon_1024.png")
    icon.save(png)
    print("写出", png)

    # Godot 项目内图标
    os.makedirs("godot", exist_ok=True)
    icon.resize((256, 256), Image.LANCZOS).save(os.path.join("godot", "icon.png"))
    print("写出 godot/icon.png")

    # Windows .ico：多尺寸打包
    ico = os.path.join(out_dir, "icon.ico")
    icon.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
                          (128, 128), (256, 256)])
    print("写出", ico)

    # macOS .icns：走 iconutil，需要标准命名的 iconset
    iconset = os.path.join(out_dir, "icon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        icon.resize((base, base), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%dx%d.png" % (base, base)))
        icon.resize((base * 2, base * 2), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%dx%d@2x.png" % (base, base)))
    icns = os.path.join(out_dir, "icon.icns")
    try:
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
        print("写出", icns)
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print("iconutil 不可用，跳过 .icns：", exc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
