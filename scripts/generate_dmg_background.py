#!/usr/bin/env python3
"""Generate Retina-ready DMG window background (1320×800)."""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "dmg-background.png"

W, H = 1320, 800
GREEN = (7, 193, 96)
GREEN_DARK = (5, 150, 74)
TEXT = (28, 36, 44)
SUBTEXT = (96, 108, 120)
ARROW = (7, 193, 96, 210)


def lerp(a: int, b: int, t: float) -> int:
    return int(a + (b - a) * t)


def vertical_gradient(size: tuple[int, int]) -> Image.Image:
    img = Image.new("RGB", size)
    px = img.load()
    top = (245, 247, 250)
    bottom = (232, 236, 242)
    for y in range(size[1]):
        t = y / max(size[1] - 1, 1)
        color = tuple(lerp(top[i], bottom[i], t) for i in range(3))
        for x in range(size[0]):
            px[x, y] = color
    return img


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "/usr/share/fonts/truetype/arphic/uming.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size=size)
            except OSError:
                continue
    return ImageFont.load_default()


def draw_rounded_rect(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    radius: int,
    fill: tuple[int, ...],
    outline: tuple[int, ...] | None = None,
    width: int = 1,
) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_arrow(draw: ImageDraw.ImageDraw, start: tuple[int, int], end: tuple[int, int]) -> None:
    sx, sy = start
    ex, ey = end
    mid_x = (sx + ex) // 2
    control = (mid_x, sy - 90)
    steps = 48
    points: list[tuple[int, int]] = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = u * u * sx + 2 * u * t * control[0] + t * t * ex
        y = u * u * sy + 2 * u * t * control[1] + t * t * ey
        points.append((int(x), int(y)))

    draw.line(points, fill=ARROW, width=8, joint="curve")

    angle = math.atan2(points[-1][1] - points[-2][1], points[-1][0] - points[-2][0])
    head_len = 28
    left = (
        ex - head_len * math.cos(angle - math.pi / 7),
        ey - head_len * math.sin(angle - math.pi / 7),
    )
    right = (
        ex - head_len * math.cos(angle + math.pi / 7),
        ey - head_len * math.sin(angle + math.pi / 7),
    )
    draw.polygon([points[-1], left, right], fill=ARROW)


def main() -> None:
    img = vertical_gradient((W, H))
    draw = ImageDraw.Draw(img, "RGBA")

    draw_rounded_rect(draw, (48, 48, W - 48, H - 48), 36, (255, 255, 255, 235), (220, 226, 234), 2)
    draw_rounded_rect(draw, (48, 48, W - 48, 132), 36, (*GREEN, 255))
    draw.rectangle((48, 96, W - 48, 132), fill=(*GREEN, 255))

    title_font = load_font(54, bold=True)
    sub_font = load_font(30)
    hint_font = load_font(26)

    draw.text((W // 2, 92), "微信聊天记录导出", fill=(255, 255, 255), font=title_font, anchor="mm")
    draw.text(
        (W // 2, 190),
        "将左侧应用图标拖入右侧「应用程序」文件夹",
        fill=TEXT,
        font=sub_font,
        anchor="mm",
    )
    draw.text(
        (W // 2, 238),
        "Drag WeChatExporter into Applications to install",
        fill=SUBTEXT,
        font=hint_font,
        anchor="mm",
    )

    # Icon drop zones (match AppleScript positions ×2)
    left_zone = (180 * 2 - 24, 170 * 2 - 24, 180 * 2 + 152, 170 * 2 + 152)
    right_zone = (480 * 2 - 24, 170 * 2 - 24, 480 * 2 + 152, 170 * 2 + 152)
    draw_rounded_rect(draw, left_zone, 28, (240, 252, 246), (*GREEN, 180), 3)
    draw_rounded_rect(draw, right_zone, 28, (240, 252, 246), (*GREEN, 180), 3)

    draw_arrow(draw, (left_zone[2] - 20, left_zone[1] + 88), (right_zone[0] + 20, right_zone[1] + 88))

    draw.text((left_zone[0] + 64, left_zone[3] + 34), "WeChatExporter", fill=SUBTEXT, font=hint_font)
    draw.text((right_zone[0] + 64, right_zone[3] + 34), "Applications", fill=SUBTEXT, font=hint_font)

    badge_font = load_font(20, bold=True)
    draw_rounded_rect(draw, (W // 2 - 280, H - 108, W // 2 + 280, H - 52), 20, (*GREEN_DARK, 255))
    draw.text((W // 2, H - 80), "安装完成后在启动台或应用程序中打开", fill=(255, 255, 255), font=badge_font, anchor="mm")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, "PNG", optimize=True)
    print(f"已生成: {OUT}")


if __name__ == "__main__":
    main()
