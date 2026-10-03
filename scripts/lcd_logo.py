#!/usr/bin/env python3
"""Omarchy mark for an AIO LCD.

The square path is the one published at https://omarchy.org/brand/omarchy-logo.svg.
Omarchy is a pending trademark. All rights reserved. This is the geometry for
the user's own cooler, not a redistributed artwork file.

The five bands are derived from the theme accent. The field is the same near-black
as the temperature faces, not the theme background. The plate is cached upright.
The clock and the dial angle are applied after that cache.
"""

from __future__ import annotations

import hashlib
import math
import os
import re
import time
from pathlib import Path

# viewBox 0 0 1200 1200, one even-odd path.
_LOGO_PATH = (
    "m1200 1200h-480v-80h400v-1040h-479.996v160h-400v720h720v-720h-80v-80"
    "h159.996v880h-400v160h-640v-1200h1200z"
    "m-1120-80h480v-80h-400l.004-400h-80.004z"
    "m0-560h80.004v-400h400v-80h-480.004z"
)

# Hard stops from the brand page, as n/19 of the logo square.
_STOPS = (0.0, 5 / 19, 7 / 19, 11 / 19, 14 / 19, 1.0)
_SQUARE_SCALE = 0.80
_ROUND_SCALE = 0.62
# Same field as cc_client._LCD_BG. The cooler shows this as black.
_PLATE_BG = (10, 12, 11)
# About three and a half pixels of fringe at the 320 reference, scaled with the panel.
# The mark stays readable and the edge fades into the black field.
_BLUR_PX = 3.5
# "HH:MM" in the same face as the Liquid number (104px at 320), sized to stay on the glass.
_CLOCK_SCALE = 88 / 320

_CACHE = Path.home() / ".cache" / "omaflow" / "lcd"
_FONT_CANDIDATES = (
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf",
    "/usr/share/fonts/TTF/JetBrainsMono-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
)

# Counts mask builds so the self-check can see a cache hit.
mask_builds = 0

_FIXTURES = {
    "tokyo-night": {
        "crest": "#daecc6",
        "hover": "#bbdd97",
        "lit": "#9ece6a",
        "mid": "#678549",
        "dim": "#39482e",
    },
    "matte-black": {
        "crest": "#f6d4a3",
        "hover": "#eeb056",
        "lit": "#e68e0d",
        "mid": "#925b0b",
        "dim": "#4b310a",
    },
}


def _srgb_to_lin(channel: int) -> float:
    value = channel / 255
    if value <= 0.04045:
        return value / 12.92
    return ((value + 0.055) / 1.055) ** 2.4


def _lin_to_srgb(value: float) -> int:
    value = max(0.0, min(1.0, value))
    if value <= 0.0031308:
        out = 12.92 * value
    else:
        out = 1.055 * (value ** (1 / 2.4)) - 0.055
    return int(round(max(0.0, min(1.0, out)) * 255))


def _hex_to_oklab(color: str) -> tuple[float, float, float]:
    text = color.lstrip("#")
    red, green, blue = (int(text[i : i + 2], 16) for i in (0, 2, 4))
    r, g, b = _srgb_to_lin(red), _srgb_to_lin(green), _srgb_to_lin(blue)
    long = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    mid = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    short = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = long ** (1 / 3), mid ** (1 / 3), short ** (1 / 3)
    lightness = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    b_axis = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    return lightness, a, b_axis


def _oklab_to_hex(lightness: float, a: float, b_axis: float) -> str:
    l_ = lightness + 0.3963377774 * a + 0.2158037573 * b_axis
    m_ = lightness - 0.1055613458 * a - 0.0638541728 * b_axis
    s_ = lightness - 0.0894841775 * a - 1.2914855480 * b_axis
    long, mid, short = l_ ** 3, m_ ** 3, s_ ** 3
    red = 4.0767416621 * long - 3.3077115913 * mid + 0.2309699292 * short
    green = -1.2684380046 * long + 2.6097574011 * mid - 0.3413193965 * short
    blue = -0.0041960863 * long - 0.7034186147 * mid + 1.7076147010 * short
    return "#%02x%02x%02x" % (_lin_to_srgb(red), _lin_to_srgb(green), _lin_to_srgb(blue))


def _oklab_distance(left: str, right: str) -> float:
    l1, a1, b1 = _hex_to_oklab(left)
    l2, a2, b2 = _hex_to_oklab(right)
    return math.sqrt((l1 - l2) ** 2 + (a1 - a2) ** 2 + (b1 - b2) ** 2)


def _to_oklch(lightness: float, a: float, b_axis: float) -> tuple[float, float, float]:
    chroma = math.hypot(a, b_axis)
    hue = math.degrees(math.atan2(b_axis, a)) % 360
    return lightness, chroma, hue


def _from_oklch(lightness: float, chroma: float, hue: float) -> tuple[float, float, float]:
    radians = math.radians(hue)
    return lightness, chroma * math.cos(radians), chroma * math.sin(radians)


def band_colors(accent: str) -> dict[str, str]:
    """Five stops from one accent. Hue stays put. Lightness is clamped."""
    lightness, chroma, hue = _to_oklch(*_hex_to_oklab(accent))
    steps = {
        "crest": (lightness + 0.14, chroma * 0.50),
        "hover": (lightness + 0.06, chroma * 0.75),
        "lit": (lightness, chroma),
        "mid": (lightness - 0.20, chroma * 0.70),
        "dim": (lightness - 0.40, chroma * 0.35),
    }
    out: dict[str, str] = {}
    for name, (level, amount) in steps.items():
        level = max(0.02, min(0.98, level))
        out[name] = _oklab_to_hex(*_from_oklch(level, max(0.0, amount), hue))
    return out


def _subpaths(path: str) -> list[list[tuple[float, float]]]:
    tokens = re.findall(r"[MmHhVvLlZz]|-?\d*\.?\d+(?:e[-+]?\d+)?", path)
    index = 0
    command = ""
    x = y = 0.0
    start = (0.0, 0.0)
    current: list[tuple[float, float]] = []
    shapes: list[list[tuple[float, float]]] = []

    def number() -> float:
        nonlocal index
        value = float(tokens[index])
        index += 1
        return value

    while index < len(tokens):
        token = tokens[index]
        if re.fullmatch(r"[MmHhVvLlZz]", token):
            command = token
            index += 1
        if command in ("M", "m"):
            dx, dy = number(), number()
            if current:
                shapes.append(current)
            x, y = (dx, dy) if command == "M" else (x + dx, y + dy)
            start = (x, y)
            current = [(x, y)]
            command = "L" if command == "M" else "l"
        elif command in ("L", "l"):
            dx, dy = number(), number()
            x, y = (dx, dy) if command == "L" else (x + dx, y + dy)
            current.append((x, y))
        elif command in ("H", "h"):
            dx = number()
            x = dx if command == "H" else x + dx
            current.append((x, y))
        elif command in ("V", "v"):
            dy = number()
            y = dy if command == "V" else y + dy
            current.append((x, y))
        elif command in ("Z", "z"):
            if current and current[-1] != start:
                current.append(start)
            x, y = start
            if current:
                shapes.append(current)
            current = []
        else:
            raise ValueError("unsupported logo path command")
    if current:
        shapes.append(current)
    return shapes


def _raster_mask(side: int):
    """Even-odd fill of the logo, supersampled and scaled to `side` pixels."""
    global mask_builds
    from PIL import Image, ImageDraw

    mask_builds += 1
    sample = 4
    big = max(1, side * sample)
    image = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(image)
    # One even-odd fill across every subpath, so the counters stay open.
    shapes = [
        [(px / 1200 * big, py / 1200 * big) for px, py in shape]
        for shape in _subpaths(_LOGO_PATH)
    ]
    for row in range(big):
        scan = row + 0.5
        hits: list[float] = []
        for points in shapes:
            for index, (x0, y0) in enumerate(points[:-1]):
                x1, y1 = points[index + 1]
                if y0 == y1:
                    continue
                if (y0 <= scan < y1) or (y1 <= scan < y0):
                    hits.append(x0 + (scan - y0) / (y1 - y0) * (x1 - x0))
        hits.sort()
        for index in range(0, len(hits) - 1, 2):
            left = int(math.ceil(hits[index]))
            right = int(math.floor(hits[index + 1]))
            if right >= left:
                draw.line([(max(0, left), row), (min(big - 1, right), row)], fill=255)
    return image.resize((side, side), Image.Resampling.LANCZOS)


def _hex_rgb(color: str) -> tuple[int, int, int]:
    text = str(color or "").strip().lstrip("#")
    if len(text) != 6:
        return (10, 12, 11)
    try:
        return (int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16))
    except ValueError:
        return (10, 12, 11)


def _logo_side(width: int, height: int, shape: str) -> int:
    shorter = max(1, min(width, height))
    scale = _ROUND_SCALE if shape != "square" else _SQUARE_SCALE
    return max(8, int(round(shorter * scale)))


def _blur_radius(width: int, height: int) -> float:
    return _BLUR_PX * min(width, height) / 320


def _cache_path(
    kind: str, width: int, height: int, shape: str, accent: str, radius: float, clear: bool = False
) -> Path:
    raw = "|".join(
        [kind, "%.2f" % radius, "%sx%s" % (width, height), shape, accent.lower(), "clear" if clear else "black"]
    )
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]
    return _CACHE / (digest + ".png")


def _cached_plate(kind: str, width: int, height: int, shape: str, accent: str, clear: bool = False):
    """Upright plate. The clock and the rotation are not part of it.

    The cooler plate is opaque black. The preview plate is transparent so the
    window color shows through.
    """
    from PIL import Image, ImageDraw, ImageFilter

    radius = _blur_radius(width, height) if kind == "blur" else 0.0
    path = _cache_path(kind, width, height, shape, accent, radius, clear)
    if path.is_file():
        return Image.open(path).convert("RGBA" if clear else "RGB")
    bands = band_colors(accent)
    side = _logo_side(width, height, shape)
    mask = _raster_mask(side)
    logo = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(logo)
    names = ("crest", "hover", "lit", "mid", "dim")
    for index, name in enumerate(names):
        top = int(round(_STOPS[index] * side))
        bottom = int(round(_STOPS[index + 1] * side))
        draw.rectangle([0, top, side, max(top + 1, bottom)], fill=_hex_rgb(bands[name]) + (255,))
    logo.putalpha(mask)
    mask.close()
    if kind == "blur":
        # Room outside the mark so the soft edge fades out instead of stopping
        # on the sprite rectangle.
        pad = max(2, int(math.ceil(radius * 3)))
        padded = Image.new("RGBA", (side + 2 * pad, side + 2 * pad), (0, 0, 0, 0))
        padded.paste(logo, (pad, pad))
        logo.close()
        sprite = padded.filter(ImageFilter.GaussianBlur(radius=radius))
        padded.close()
    else:
        sprite = logo
    if clear:
        canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    else:
        canvas = Image.new("RGB", (width, height), _PLATE_BG)
    origin = ((width - sprite.width) // 2, (height - sprite.height) // 2)
    canvas.paste(sprite, origin, sprite)
    sprite.close()
    _CACHE.mkdir(parents=True, exist_ok=True)
    canvas.save(path, "PNG")
    os.chmod(path, 0o600)
    return canvas


def _clock_font(size: int):
    from PIL import ImageFont

    for path in _FONT_CANDIDATES:
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def _draw_clock(image, text: str, fill: str) -> None:
    """Same face as the Liquid number. The clock is one line, so it sits in the middle.

    One pixel of black at the 320 reference, scaled with the plate so the
    preview matches the cooler.
    """
    from PIL import ImageDraw

    draw = ImageDraw.Draw(image)
    shorter = min(image.size)
    font = _clock_font(max(16, int(round(shorter * _CLOCK_SCALE))))
    stroke = max(1, int(round(shorter / 320)))
    box = draw.textbbox((0, 0), text, font=font)
    width = box[2] - box[0]
    height = box[3] - box[1]
    x = (image.size[0] - width) / 2 - box[0]
    y = (image.size[1] - height) / 2 - box[1]
    draw.text(
        (x, y),
        text,
        font=font,
        fill=_hex_rgb(fill),
        stroke_width=stroke,
        stroke_fill=(0, 0, 0),
    )


def render_logo_png(
    face: str,
    accent: str,
    width: int,
    height: int,
    shape: str,
    angle: int = 0,
    clock: str | None = None,
    clear: bool = False,
) -> bytes:
    """Plate at the requested pixel size. `clock` overrides the minute.

    The cooler plate is the temperature-face black. `clear` leaves the field
    transparent for the window preview. The clock is drawn in `accent` with a
    1px black edge at the 320 reference.
    """
    import io

    from PIL import Image

    kind = "blur" if face == "omarchy-time" else "sharp"
    plate = _cached_plate(
        kind, width, height, "square" if shape == "square" else "round", accent, clear
    )
    image = plate.copy()
    plate.close()
    if face == "omarchy-time":
        label = clock if clock is not None else time.strftime("%H:%M")
        _draw_clock(image, label, accent or "#b59790")
    turned = int(angle) % 360
    if turned:
        image = image.rotate(
            -turned,
            resample=Image.Resampling.BICUBIC,
            expand=False,
            fillcolor=(0, 0, 0, 0) if clear else _PLATE_BG,
        )
    buf = io.BytesIO()
    image.save(buf, "PNG")
    image.close()
    return buf.getvalue()


def _fail(message: str) -> None:
    raise SystemExit(message)


def self_check() -> None:
    """Band fixtures, four cooler buffers, and a plate cache hit."""
    import io

    from PIL import Image

    for name, fixture in _FIXTURES.items():
        got = band_colors(fixture["lit"])
        for key in ("crest", "hover", "lit", "mid", "dim"):
            distance = _oklab_distance(fixture[key], got[key])
            if distance > 0.04:
                _fail("%s %s distance %.3f" % (name, key, distance))
    buffers = (
        (320, 320, "round"),
        (640, 640, "round"),
        (240, 240, "square"),
        (240, 320, "square"),
    )
    accent = "#7fbbb3"
    # The disk cache survives this process. Drop one probe plate so the
    # rasterizer has to run, then prove the next call does not run it again.
    probe = "#010203"
    _cache_path("sharp", 320, 320, "round", probe, 0.0).unlink(missing_ok=True)
    before = mask_builds
    first = render_logo_png("omarchy", probe, 320, 320, "round")
    built = mask_builds
    if built != before + 1:
        _fail("mask was not built")
    second = render_logo_png("omarchy", probe, 320, 320, "round")
    if mask_builds != built:
        _fail("cache rebuilt the mask")
    if first != second:
        _fail("cached plate differed")
    other = render_logo_png("omarchy", accent, 240, 240, "square")
    if other == first:
        _fail("a different size reused the plate")
    sharp = render_logo_png("omarchy", accent, 320, 320, "round")
    noon = render_logo_png("omarchy-time", accent, 320, 320, "round", clock="12:00")
    later = render_logo_png("omarchy-time", accent, 320, 320, "round", clock="12:01")
    if noon == later:
        _fail("clock minute did not change the picture")
    if noon == sharp:
        _fail("clock plate matched the sharp logo")
    out_dir = Path("/tmp/omaflow-lcd-check")
    out_dir.mkdir(parents=True, exist_ok=True)
    for width, height, shape in buffers:
        for face in ("omarchy", "omarchy-time"):
            raw = render_logo_png(face, accent, width, height, shape, clock="09:41")
            image = Image.open(io.BytesIO(raw))
            if image.size != (width, height) or image.mode != "RGB":
                _fail("%s %s is %s %s" % (face, shape, image.size, image.mode))
            if image.getpixel((0, 0)) != _PLATE_BG:
                _fail("%s field is %s" % (face, image.getpixel((0, 0))))
            if shape == "round":
                _assert_round(image)
                _assert_no_blur_square(image)
            if face == "omarchy-time":
                _assert_clock_edge(image)
            image.save(out_dir / ("%s-%s-%sx%s.png" % (face, shape, width, height)))
            image.close()
    clear = render_logo_png("omarchy-time", accent, 320, 320, "round", clock="09:41", clear=True)
    preview = Image.open(io.BytesIO(clear))
    if preview.mode != "RGBA" or preview.getpixel((0, 0))[3] != 0:
        _fail("preview field is %s %s" % (preview.mode, preview.getpixel((0, 0))))
    _assert_clock_edge(preview)
    preview.close()
    print("lcd_logo ok")


def _assert_clock_edge(image) -> None:
    """Omarchy | Time keeps a black edge on the digits. At 320 that edge is 1px."""
    width, height = image.size
    pixels = image.load()
    found = 0
    for y in range(height // 3, (2 * height) // 3):
        for x in range(width // 8, width - width // 8):
            pixel = pixels[x, y]
            if pixel[0] > 2 or pixel[1] > 2 or pixel[2] > 2:
                continue
            if len(pixel) > 3 and pixel[3] < 200:
                continue
            found += 1
            if found >= 20:
                return
    _fail("clock digits have no black edge")


def _assert_round(image) -> None:
    width, height = image.size
    cx = (width - 1) / 2
    cy = (height - 1) / 2
    radius = min(width, height) / 2
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            if (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2:
                continue
            red, green, blue = pixels[x, y]
            if abs(red - _PLATE_BG[0]) + abs(green - _PLATE_BG[1]) + abs(blue - _PLATE_BG[2]) > 18:
                _fail("logo pixel outside the circle at %s,%s" % (x, y))


def _assert_no_blur_square(image) -> None:
    """The softened mark must fade out before it becomes a rectangle on the field."""
    width, height = image.size
    side = _logo_side(width, height, "round")
    pad = max(2, int(math.ceil(_blur_radius(width, height) * 3)))
    top = (height - side) // 2 - pad - 4
    if top < 1:
        return
    pixel = image.getpixel((width // 2, top))
    if pixel != _PLATE_BG:
        _fail("blur square at %s,%s %s" % (width // 2, top, pixel))


if __name__ == "__main__":
    self_check()
