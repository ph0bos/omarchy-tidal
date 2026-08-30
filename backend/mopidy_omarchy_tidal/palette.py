"""What an album cover looks like, in two numbers the interface can use.

Two problems share one answer. Text drawn over a blurred sleeve is unreadable
when the sleeve is bright -- a white cover lifts the backdrop until the muted
metadata all but disappears -- and a spectrum analyser in the theme's accent
ignores the record it is drawn beside. Both want to know something about the
artwork: how light it is, and what colour it is.

So the companion measures it. GdkPixbuf does the decoding, which mopidy already
depends on through PyGObject; there is no Pillow and no numpy here and none is
worth adding for a 16x16 thumbnail.

Not every cover has a colour. This one is black and white:

    Bring Me The Horizon - L.I.V.E. In Sao Paulo

and the honest answer for it is None, so the caller keeps the theme's own
accent rather than tinting the interface a washed-out grey.
"""

from __future__ import annotations

# Below this, a pixel is grey rather than coloured, and averaging it into an
# accent only mutes the result.
MIN_SATURATION = 0.18
# Near-black and near-white carry no usable hue.
MIN_VALUE = 0.12
MAX_VALUE = 0.97

# A cover needs this share of coloured pixels before we call it coloured.
MIN_COLOURED_SHARE = 0.08

HUE_BUCKETS = 12


def _channel(value: float) -> float:
    """sRGB channel to linear, for luminance that matches how eyes work."""
    v = value / 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb) -> float:
    """WCAG relative luminance, 0 (black) to 1 (white)."""
    r, g, b = rgb
    return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b)


def contrast_ratio(first, second) -> float:
    """WCAG contrast between two colours: 1 (identical) to 21 (black on white)."""
    a, b = relative_luminance(first), relative_luminance(second)
    high, low = max(a, b), min(a, b)
    return (high + 0.05) / (low + 0.05)


def to_hsv(rgb) -> tuple[float, float, float]:
    r, g, b = (c / 255 for c in rgb)
    high, low = max(r, g, b), min(r, g, b)
    span = high - low
    if span == 0:
        hue = 0.0
    elif high == r:
        hue = (60 * ((g - b) / span)) % 360
    elif high == g:
        hue = 60 * ((b - r) / span) + 120
    else:
        hue = 60 * ((r - g) / span) + 240
    return hue, (0.0 if high == 0 else span / high), high


def from_hsv(hue: float, saturation: float, value: float) -> tuple[int, int, int]:
    chroma = value * saturation
    x = chroma * (1 - abs(((hue / 60) % 2) - 1))
    m = value - chroma
    table = [(chroma, x, 0), (x, chroma, 0), (0, chroma, x),
             (0, x, chroma), (x, 0, chroma), (chroma, 0, x)]
    r, g, b = table[int(hue // 60) % 6]
    return tuple(max(0, min(255, round((c + m) * 255))) for c in (r, g, b))


def dominant_colour(pixels) -> tuple[int, int, int] | None:
    """The colour a listener would say the sleeve *is*, or None for greyscale.

    Hue buckets rather than a plain average: averaging a red-and-blue cover
    gives muddy purple, which is a colour that is not in the artwork. Weighting
    by saturation and brightness picks the hue that carries the sleeve rather
    than the one that merely covers the most area.
    """
    if not pixels:
        return None

    buckets: dict[int, list[float]] = {}
    coloured = 0
    for pixel in pixels:
        hue, saturation, value = to_hsv(pixel)
        if saturation < MIN_SATURATION or not (MIN_VALUE < value < MAX_VALUE):
            continue
        coloured += 1
        index = int(hue // (360 / HUE_BUCKETS)) % HUE_BUCKETS
        weight = saturation * value
        entry = buckets.setdefault(index, [0.0, 0.0, 0.0, 0.0])
        entry[0] += hue * weight
        entry[1] += saturation * weight
        entry[2] += value * weight
        entry[3] += weight

    if coloured / len(pixels) < MIN_COLOURED_SHARE or not buckets:
        return None

    _, entry = max(buckets.items(), key=lambda item: item[1][3])
    total = entry[3]
    hue, saturation, value = entry[0] / total, entry[1] / total, entry[2] / total

    # Lift it into a range that reads as an accent on either a dark or a light
    # surface. A sleeve's own colour is often too dark or too washed to use raw.
    saturation = max(0.55, min(0.9, saturation))
    value = max(0.62, min(0.95, value))
    return from_hsv(hue, saturation, value)


def analyse_pixels(pixels) -> dict:
    """Mean luminance and a representative colour for a list of (r, g, b)."""
    if not pixels:
        return {"luma": 0.0, "color": None, "isLight": False}
    luma = sum(relative_luminance(p) for p in pixels) / len(pixels)
    colour = dominant_colour(pixels)
    return {
        "luma": round(luma, 4),
        "color": "#%02x%02x%02x" % colour if colour else None,
        # The threshold where light text stops working over a wash of this.
        "isLight": luma > 0.45,
    }


def sample(data: bytes, size: int = 16) -> list[tuple[int, int, int]]:
    """Decode image bytes down to a size x size grid of pixels.

    GdkPixbuf is imported here rather than at module scope so this file stays
    importable -- and testable -- without a display stack.
    """
    import gi

    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf

    loader = GdkPixbuf.PixbufLoader()
    loader.write(data)
    loader.close()
    pixbuf = loader.get_pixbuf()
    if pixbuf is None:
        return []

    small = pixbuf.scale_simple(size, size, GdkPixbuf.InterpType.BILINEAR)
    if small is None:
        return []

    raw = small.get_pixels()
    channels = small.get_n_channels()
    stride = small.get_rowstride()
    pixels = []
    for y in range(small.get_height()):
        row = y * stride
        for x in range(small.get_width()):
            offset = row + x * channels
            pixels.append((raw[offset], raw[offset + 1], raw[offset + 2]))
    return pixels


def analyse(data: bytes) -> dict | None:
    """The palette for a piece of artwork, or None if it cannot be read."""
    try:
        return analyse_pixels(sample(data))
    except Exception:
        return None
