#!/usr/bin/env python3
"""Generate Retina-ready DMG window background — sci-fi dreamy style (1320×800)."""

from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "dmg-background.png"

W, H = 1320, 800

# Neon palette
CYAN = (0, 245, 255)
PURPLE = (123, 97, 255)
MAGENTA = (255, 77, 210)
GREEN = (7, 255, 160)
WHITE = (240, 248, 255)
SUBTEXT = (140, 170, 210)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp_color(c1: tuple[int, ...], c2: tuple[int, ...], t: float) -> tuple[int, ...]:
    return tuple(int(lerp(c1[i], c2[i], t)) for i in range(len(c1)))


def load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
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


def cosmic_gradient(size: tuple[int, int]) -> Image.Image:
    img = Image.new("RGB", size)
    px = img.load()
    c_tl = (8, 10, 32)
    c_tr = (18, 8, 48)
    c_bl = (6, 18, 42)
    c_br = (28, 6, 38)
    for y in range(size[1]):
        ty = y / max(size[1] - 1, 1)
        for x in range(size[0]):
            tx = x / max(size[0] - 1, 1)
            top = lerp_color(c_tl, c_tr, tx)
            bottom = lerp_color(c_bl, c_br, tx)
            px[x, y] = lerp_color(top, bottom, ty)
    return img


def add_aurora(base: Image.Image) -> Image.Image:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for cx, cy, rx, ry, color in [
        (W * 0.35, H * 0.22, 420, 180, (0, 180, 255, 55)),
        (W * 0.65, H * 0.18, 380, 160, (140, 60, 255, 50)),
        (W * 0.5, H * 0.55, 500, 200, (255, 60, 200, 35)),
    ]:
        for i in range(8, 0, -1):
            alpha = color[3] // i
            draw.ellipse(
                (cx - rx * i / 8, cy - ry * i / 8, cx + rx * i / 8, cy + ry * i / 8),
                fill=(*color[:3], alpha),
            )
    blurred = layer.filter(ImageFilter.GaussianBlur(radius=40))
    return Image.alpha_composite(base.convert("RGBA"), blurred)


def add_stars(base: Image.Image, count: int = 180) -> Image.Image:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    rng = random.Random(42)
    for _ in range(count):
        x = rng.randint(0, W - 1)
        y = rng.randint(0, H - 1)
        r = rng.choice([1, 1, 1, 2])
        alpha = rng.randint(60, 220)
        tint = rng.choice([WHITE, CYAN, PURPLE])
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(*tint, alpha))
    return Image.alpha_composite(base, layer)


def add_grid(base: Image.Image) -> Image.Image:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    horizon = int(H * 0.78)
    for i in range(-20, 30):
        x = W // 2 + i * 80
        draw.line((W // 2, horizon, x, H), fill=(*CYAN, 18), width=1)
    for j in range(0, 12):
        y = horizon + j * 28
        t = j / 11
        half = int(W * (0.15 + t * 0.55))
        draw.line((W // 2 - half, y, W // 2 + half, y), fill=(*PURPLE, 14 + j * 2), width=1)
    return Image.alpha_composite(base, layer)


def glow_text(
    base: Image.Image,
    xy: tuple[int, int],
    text: str,
    font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
    fill: tuple[int, int, int],
    glow: tuple[int, int, int],
    anchor: str = "mm",
) -> Image.Image:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for dx, dy, alpha in [(0, 0, 255), (0, 0, 180), (2, 0, 120), (-2, 0, 120), (0, 2, 120), (0, -2, 120)]:
        draw.text((xy[0] + dx, xy[1] + dy), text, fill=(*glow, alpha), font=font, anchor=anchor)
    blurred = layer.filter(ImageFilter.GaussianBlur(radius=6))
    base = Image.alpha_composite(base, blurred)
    draw2 = ImageDraw.Draw(base)
    draw2.text(xy, text, fill=(*fill, 255), font=font, anchor=anchor)
    return base


def draw_hud_zone(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    color: tuple[int, int, int],
    label: str,
    font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
) -> None:
    x1, y1, x2, y2 = box
    draw.rounded_rectangle(box, radius=24, fill=(12, 20, 48, 90), outline=(*color, 160), width=2)

    corner = 22
    for ox, oy, dx, dy in [
        (x1, y1, 1, 1),
        (x2, y1, -1, 1),
        (x1, y2, 1, -1),
        (x2, y2, -1, -1),
    ]:
        draw.line((ox, oy, ox + dx * corner, oy), fill=(*color, 230), width=3)
        draw.line((ox, oy, ox, oy + dy * corner), fill=(*color, 230), width=3)

    draw.text(((x1 + x2) // 2, y2 + 36), label, fill=(*SUBTEXT, 230), font=font, anchor="mm")


def neon_arrow_layer(size: tuple[int, int], start: tuple[int, int], end: tuple[int, int]) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    sx, sy = start
    ex, ey = end
    mid_x = (sx + ex) // 2
    control = (mid_x, sy - 110)
    steps = 64
    points: list[tuple[int, int]] = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = u * u * sx + 2 * u * t * control[0] + t * t * ex
        y = u * u * sy + 2 * u * t * control[1] + t * t * ey
        points.append((int(x), int(y)))

    for width, alpha, color in [(14, 40, PURPLE), (8, 80, CYAN), (3, 255, WHITE)]:
        draw.line(points, fill=(*color, alpha), width=width, joint="curve")

    angle = math.atan2(points[-1][1] - points[-2][1], points[-1][0] - points[-2][0])
    head_len = 32
    tip = points[-1]
    left = (
        tip[0] - head_len * math.cos(angle - math.pi / 6),
        tip[1] - head_len * math.sin(angle - math.pi / 6),
    )
    right = (
        tip[0] - head_len * math.cos(angle + math.pi / 6),
        tip[1] - head_len * math.sin(angle + math.pi / 6),
    )
    draw.polygon([tip, left, right], fill=(*CYAN, 255))

    for i in range(0, len(points) - 1, 6):
        px, py = points[i]
        draw.ellipse((px - 4, py - 4, px + 4, py + 4), fill=(*MAGENTA, 180))

    return layer.filter(ImageFilter.GaussianBlur(radius=1))


def glass_panel(base: Image.Image, box: tuple[int, int, int, int]) -> Image.Image:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle(box, radius=32, fill=(16, 24, 56, 110), outline=(100, 140, 255, 60), width=2)
    x1, y1, x2, y2 = box
    draw.line((x1 + 40, y1 + 2, x2 - 40, y1 + 2), fill=(*WHITE, 40), width=2)
    return Image.alpha_composite(base, layer)


def main() -> None:
    img = cosmic_gradient((W, H)).convert("RGBA")
    img = add_aurora(img)
    img = add_stars(img)
    img = add_grid(img)
    img = glass_panel(img, (40, 36, W - 40, H - 36))

    title_font = load_font(52)
    sub_font = load_font(28)
    hint_font = load_font(24)
    label_font = load_font(22)

    img = glow_text(img, (W // 2, 88), "微信聊天记录导出", title_font, WHITE, CYAN)
    img = glow_text(img, (W // 2, 168), "将左侧应用图标拖入右侧「应用程序」文件夹", sub_font, WHITE, PURPLE)
    draw = ImageDraw.Draw(img)
    draw.text(
        (W // 2, 214),
        "Drag WeChatExporter into Applications to install",
        fill=(*SUBTEXT, 220),
        font=hint_font,
        anchor="mm",
    )

    left_zone = (180 * 2 - 28, 170 * 2 - 28, 180 * 2 + 156, 170 * 2 + 156)
    right_zone = (480 * 2 - 28, 170 * 2 - 28, 480 * 2 + 156, 170 * 2 + 156)
    draw_hud_zone(draw, left_zone, CYAN, "WeChatExporter", label_font)
    draw_hud_zone(draw, right_zone, PURPLE, "Applications", label_font)

    arrow = neon_arrow_layer(
        (W, H),
        (left_zone[2] - 16, left_zone[1] + 92),
        (right_zone[0] + 16, right_zone[1] + 92),
    )
    img = Image.alpha_composite(img, arrow)

    badge_font = load_font(20)
    badge_box = (W // 2 - 300, H - 112, W // 2 + 300, H - 54)
    badge_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    badge_draw = ImageDraw.Draw(badge_layer)
    badge_draw.rounded_rectangle(badge_box, radius=22, fill=(20, 30, 70, 180), outline=(*GREEN, 180), width=2)
    badge_blur = badge_layer.filter(ImageFilter.GaussianBlur(radius=2))
    img = Image.alpha_composite(img, badge_blur)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle(badge_box, radius=22, outline=(*GREEN, 120), width=1)
    draw.text((W // 2, H - 83), "安装完成后在启动台或应用程序中打开", fill=(*GREEN, 255), font=badge_font, anchor="mm")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(OUT, "PNG", optimize=True)
    print(f"已生成: {OUT}")


if __name__ == "__main__":
    main()
