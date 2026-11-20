#!/usr/bin/env python3
"""Draws the S2A Claude X-Ray app icon (1024x1024 PNG) with Pillow.

Usage: python3 scripts/make-icon.py Resources/AppIcon.png
The macOS build script turns the PNG into AppIcon.icns with sips + iconutil.
With --ios it draws the iPad app's icon: a full square without transparency.
"""
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = 1024
INSET = 100           # Apple icon grid: 824 px tile inside the 1024 canvas
RADIUS = 185

DEEP = (48, 17, 114)       # #301172
VIOLET = (113, 83, 221)    # #7153dd  S2A Violet
CYAN = (14, 177, 205)      # #0eb1cd  S2A Cyan


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size):
    """Diagonal deep violet -> violet -> cyan."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + (size - y)) / (2 * size)
            px[x, y] = lerp(DEEP, VIOLET, t / 0.55) if t < 0.55 else lerp(VIOLET, CYAN, (t - 0.55) / 0.45)
    return img


def font(size, bold=True):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_tile(tile):
    """The icon's square artwork, `tile` pixels wide; the shapes are laid out for 824 px."""
    k = tile / 824
    tile_img = gradient(tile).convert("RGBA")

    overlay = Image.new("RGBA", (tile, tile), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    # X-ray beams crossing behind the glyphs.
    for start, end in (((-60 * k, -60 * k), (tile + 60 * k, tile + 60 * k)), ((tile + 60 * k, -60 * k), (-60 * k, tile + 60 * k))):
        d.line((start, end), fill=(255, 255, 255, 34), width=round(70 * k))
    # Top highlight.
    d.ellipse((-tile * 0.3, -tile * 0.75, tile * 1.3, tile * 0.42), fill=(255, 255, 255, 30))
    tile_img.alpha_composite(overlay)

    glyphs = Image.new("RGBA", (tile, tile), (0, 0, 0, 0))
    g = ImageDraw.Draw(glyphs)
    # "S2A" wordmark.
    title = font(round(228 * k))
    w = g.textlength("S2A", font=title)
    g.text(((tile - w) / 2, 70 * k), "S2A", font=title, fill=(255, 255, 255, 255))
    # Pulse line (the live trace).
    cy = 488
    pts = [(x * k, y * k) for x, y in ((70, cy), (250, cy), (300, cy - 40), (350, cy + 28), (398, cy - 118), (452, cy + 112),
                                       (505, cy - 52), (548, cy), (754, cy))]
    g.line(pts, fill=(255, 255, 255, 255), width=round(34 * k), joint="curve")
    r = 17 * k
    for x, y in (pts[0], pts[-1]):
        g.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 255))
    # "X-RAY" caption.
    caption = font(round(92 * k))
    text = "X-RAY"
    spacing = 18 * k
    total = sum(g.textlength(ch, font=caption) for ch in text) + spacing * (len(text) - 1)
    x = (tile - total) / 2
    for ch in text:
        g.text((x, 660 * k), ch, font=caption, fill=(255, 255, 255, 220))
        x += g.textlength(ch, font=caption) + spacing

    glow = glyphs.filter(ImageFilter.GaussianBlur(14 * k))
    tile_img.alpha_composite(Image.eval(glow, lambda v: v // 2))
    tile_img.alpha_composite(glyphs)
    return tile_img


def main(out):
    tile = SIZE - 2 * INSET
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Soft drop shadow.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (INSET + 10, INSET + 28, INSET + tile - 10, INSET + tile + 18), RADIUS, fill=(10, 6, 40, 120))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))

    # Gradient tile with rounded corners.
    mask = Image.new("L", (tile, tile), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, tile - 1, tile - 1), RADIUS, fill=255)
    canvas.paste(draw_tile(tile), (INSET, INSET), mask)
    canvas.save(out)
    print(f"icon: {out}")


def main_ios(out):
    """iPadOS draws the rounded corners itself: a full square without transparency."""
    draw_tile(SIZE).convert("RGB").save(out)
    print(f"icon: {out}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--ios"]
    if "--ios" in sys.argv:
        main_ios(args[0] if args else "iPad/XRay/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    else:
        main(args[0] if args else "Resources/AppIcon.png")
