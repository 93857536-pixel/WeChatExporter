#!/usr/bin/env python3
"""Generate DMG window backgrounds (660×400 @1x + 1320×800 @2x with correct DPI)."""

from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"

# Finder 窗口逻辑尺寸（points）——必须与 create_dmg.sh 中 WINDOW_* 一致
BASE_W, BASE_H = 660, 400

# Icon positions in points (match create_dmg.sh AppleScript)
ICON_LEFT = (180, 170)
ICON_RIGHT = (480, 170)
ICON_SIZE = 128

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


def s(v: float, scale: int) -> int:
    return int(v * scale)


def cosmic_gradient(w: int, h: int) -> Image.Image:
    img = Image.new("RGB", (w, h))
    px = img.load()
    c_tl, c_tr = (8, 10, 32), (18, 8, 48)
    c_bl, c_br = (6, 18, 42), (28, 6, 38)
    for y in range(h):
        ty = y / max(h - 1, 1)
        for x in range(w):
            tx = x / max(w - 1, 1)
            top = lerp_color(c_tl, c_tr, tx)
            bottom = lerp_color(c_bl, c_br, tx)
            px[x, y] = lerp_color(top, bottom, ty)
    return img


def add_aurora(base: Image.Image, scale: int) -> Image.Image:
    w, h = base.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for cx, cy, rx, ry, color in [
        (w * 0.35, h * 0.22, s(210, scale), s(90, scale), (0, 180, 255, 55)),
        (w * 0.65, h * 0.18, s(190, scale), s(80, scale), (140, 60, 255, 50)),
        (w * 0.5, h * 0.55, s(250, scale), s(100, scale), (255, 60, 200, 35)),
    ]:
        for i in range(8, 0, -1):
            alpha = color[3] // i
            draw.ellipse(
                (cx - rx * i / 8, cy - ry * i / 8, cx + rx * i / 8, cy + ry * i / 8),
                fill=(*color[:3], alpha),
            )
    blurred = layer.filter(ImageFilter.GaussianBlur(radius=20 * scale))
    return Image.alpha_composite(base.convert("RGBA"), blurred)


def add_stars(base: Image.Image, scale: int, count: int = 180) -> Image.Image:
    w, h = base.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    rng = random.Random(42)
    for _ in range(count):
        x = rng.randint(0, w - 1)
        y = rng.randint(0, h - 1)
        r = rng.choice([1, 1, 1, 2]) * scale
        alpha = rng.randint(60, 220)
        tint = rng.choice([WHITE, CYAN, PURPLE])
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(*tint, alpha))
    return Image.alpha_composite(base, layer)


def add_grid(base: Image.Image, scale: int) -> Image.Image:
    w, h = base.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    horizon = int(h * 0.78)
    step = 40 * scale
    for i in range(-20, 30):
        x = w // 2 + i * step
        draw.line((w // 2, horizon, x, h), fill=(*CYAN, 18), width=scale)
    for j in range(0, 12):
        y = horizon + j * (14 * scale)
        t = j / 11
        half = int(w * (0.15 + t * 0.55))
        draw.line((w // 2 - half, y, w // 2 + half, y), fill=(*PURPLE, 14 + j * 2), width=scale)
    return Image.alpha_composite(base, layer)


def glow_text(
    base: Image.Image,
    xy: tuple[int, int],
    text: str,
    font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
    fill: tuple[int, int, int],
    glow: tuple[int, int, int],
    blur: int,
    anchor: str = "mm",
) -> Image.Image:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for dx, dy, alpha in [(0, 0, 255), (0, 0, 180), (2, 0, 120), (-2, 0, 120), (0, 2, 120), (0, -2, 120)]:
        draw.text((xy[0] + dx, xy[1] + dy), text, fill=(*glow, alpha), font=font, anchor=anchor)
    blurred = layer.filter(ImageFilter.GaussianBlur(radius=blur))
    base = Image.alpha_composite(base, blurred)
    ImageDraw.Draw(base).text(xy, text, fill=(*fill, 255), font=font, anchor=anchor)
    return base


def draw_hud_zone(
    draw: ImageDraw.ImageDraw,
    center: tuple[int, int],
    scale: int,
    color: tuple[int, int, int],
    label: str,
    font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
) -> tuple[int, int, int, int]:
    cx, cy = center
    half = s(ICON_SIZE // 2 + 14, scale)
    box = (cx - half, cy - half, cx + half, cy + half)
    radius = 12 * scale
    draw.rounded_rectangle(box, radius=radius, fill=(12, 20, 48, 90), outline=(*color, 160), width=2 * scale)
    corner = 11 * scale
    x1, y1, x2, y2 = box
    for ox, oy, dx, dy in [(x1, y1, 1, 1), (x2, y1, -1, 1), (x1, y2, 1, -1), (x2, y2, -1, -1)]:
        draw.line((ox, oy, ox + dx * corner, oy), fill=(*color, 230), width=2 * scale)
        draw.line((ox, oy, ox, oy + dy * corner), fill=(*color, 230), width=2 * scale)
    draw.text((cx, y2 + s(18, scale)), label, fill=(*SUBTEXT, 230), font=font, anchor="mm")
    return box


def neon_arrow_layer(size: tuple[int, int], start: tuple[int, int], end: tuple[int, int], scale: int) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    sx, sy = start
    ex, ey = end
    control = ((sx + ex) // 2, sy - s(55, scale))
    steps = 64
    points: list[tuple[int, int]] = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = u * u * sx + 2 * u * t * control[0] + t * t * ex
        y = u * u * sy + 2 * u * t * control[1] + t * t * ey
        points.append((int(x), int(y)))

    for width, alpha, color in [(7 * scale, 40, PURPLE), (4 * scale, 80, CYAN), (2 * scale, 255, WHITE)]:
        draw.line(points, fill=(*color, alpha), width=max(width, 1), joint="curve")

    angle = math.atan2(points[-1][1] - points[-2][1], points[-1][0] - points[-2][0])
    head_len = 16 * scale
    tip = points[-1]
    left = (tip[0] - head_len * math.cos(angle - math.pi / 6), tip[1] - head_len * math.sin(angle - math.pi / 6))
    right = (tip[0] - head_len * math.cos(angle + math.pi / 6), tip[1] - head_len * math.sin(angle + math.pi / 6))
    draw.polygon([tip, left, right], fill=(*CYAN, 255))
    for i in range(0, len(points) - 1, 6):
        px, py = points[i]
        r = 2 * scale
        draw.ellipse((px - r, py - r, px + r, py + r), fill=(*MAGENTA, 180))
    return layer.filter(ImageFilter.GaussianBlur(radius=scale))


def glass_panel(base: Image.Image, scale: int) -> Image.Image:
    w, h = base.size
    margin = 20 * scale
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    box = (margin, margin, w - margin, h - margin)
    draw.rounded_rectangle(box, radius=16 * scale, fill=(16, 24, 56, 110), outline=(100, 140, 255, 60), width=2 * scale)
    x1, y1, x2, _ = box
    draw.line((x1 + 20 * scale, y1 + scale, x2 - 20 * scale, y1 + scale), fill=(*WHITE, 40), width=scale)
    return Image.alpha_composite(base, layer)


def render(scale: int) -> Image.Image:
    w, h = BASE_W * scale, BASE_H * scale
    img = cosmic_gradient(w, h).convert("RGBA")
    img = add_aurora(img, scale)
    img = add_stars(img, scale, count=120 if scale == 1 else 180)
    img = add_grid(img, scale)
    img = glass_panel(img, scale)

    title_font = load_font(26 * scale)
    sub_font = load_font(14 * scale)
    hint_font = load_font(12 * scale)
    label_font = load_font(11 * scale)
    badge_font = load_font(10 * scale)

    img = glow_text(img, (w // 2, s(44, scale)), "微信聊天记录导出", title_font, WHITE, CYAN, 3 * scale)
    img = glow_text(
        img, (w // 2, s(84, scale)), "将左侧应用图标拖入右侧「应用程序」文件夹", sub_font, WHITE, PURPLE, 2 * scale
    )
    draw = ImageDraw.Draw(img)
    draw.text(
        (w // 2, s(107, scale)),
        "Drag WeChatExporter into Applications to install",
        fill=(*SUBTEXT, 220),
        font=hint_font,
        anchor="mm",
    )

    left_center = (s(ICON_LEFT[0], scale) + s(ICON_SIZE // 2, scale), s(ICON_LEFT[1], scale) + s(ICON_SIZE // 2, scale))
    right_center = (s(ICON_RIGHT[0], scale) + s(ICON_SIZE // 2, scale), s(ICON_RIGHT[1], scale) + s(ICON_SIZE // 2, scale))
    left_box = draw_hud_zone(draw, left_center, scale, CYAN, "WeChatExporter", label_font)
    right_box = draw_hud_zone(draw, right_center, scale, PURPLE, "Applications", label_font)

    arrow = neon_arrow_layer(
        (w, h),
        (left_box[2] - s(8, scale), left_box[1] + (left_box[3] - left_box[1]) // 2),
        (right_box[0] + s(8, scale), right_box[1] + (right_box[3] - right_box[1]) // 2),
        scale,
    )
    img = Image.alpha_composite(img, arrow)

    badge_box = (w // 2 - s(150, scale), h - s(56, scale), w // 2 + s(150, scale), h - s(27, scale))
    badge_layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    badge_draw = ImageDraw.Draw(badge_layer)
    badge_draw.rounded_rectangle(badge_box, radius=11 * scale, fill=(20, 30, 70, 180), outline=(*GREEN, 180), width=2 * scale)
    img = Image.alpha_composite(img, badge_layer.filter(ImageFilter.GaussianBlur(radius=scale)))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle(badge_box, radius=11 * scale, outline=(*GREEN, 120), width=scale)
    draw.text((w // 2, h - s(41, scale)), "安装完成后在启动台或应用程序中打开", fill=(*GREEN, 255), font=badge_font, anchor="mm")
    return img


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    out_1x = ASSETS / "dmg-background.png"
    out_2x = ASSETS / "dmg-background@2x.png"

    img_1x = render(1)
    img_2x = render(2)

    # Finder 通过 DPI 判断逻辑尺寸：1x=72dpi，2x=144dpi
    img_1x.convert("RGB").save(out_1x, "PNG", optimize=True, dpi=(72, 72))
    img_2x.convert("RGB").save(out_2x, "PNG", optimize=True, dpi=(144, 144))

    print(f"已生成: {out_1x} ({img_1x.size[0]}×{img_1x.size[1]} @72dpi)")
    print(f"已生成: {out_2x} ({img_2x.size[0]}×{img_2x.size[1]} @144dpi)")


if __name__ == "__main__":
    main()
