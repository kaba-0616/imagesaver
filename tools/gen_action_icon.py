"""Generate the share-sheet action icon.

iOS renders action-extension icons in the share sheet as *templates*: only the
alpha channel survives, and it is filled with the system tint. So the artwork
must be a transparent-background line drawing (like the stock Copy / Bookmark
glyphs), not a filled tile -- a fully opaque square renders as a solid square.
"""
import math, struct, zlib, os

# Matched by eye against the stock Copy and Bookmark glyphs sitting beside
# this one in the share sheet: they are drawn thinner, and sit smaller inside
# their circle, than a naive full-bleed glyph.
STROKE = 0.043          # line width, fraction of canvas
GLYPH_SCALE = 0.74      # shrink about the centre, leaving breathing room
SS = 4                  # supersampling factor per axis


def arc_points(cx, cy, r, a0, a1, steps=8):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / steps),
             cy + r * math.sin(a0 + (a1 - a0) * i / steps))
            for i in range(steps + 1)]


def polyline(points):
    return [(points[i], points[i + 1]) for i in range(len(points) - 1)]


def build_glyph():
    """A tray open at the top with an arrow dropping into it."""
    segs = []

    # Arrow shaft + head
    segs += polyline([(0.50, 0.09), (0.50, 0.615)])
    segs += polyline([(0.305, 0.425), (0.50, 0.62), (0.695, 0.425)])

    # Tray: left wall, rounded bottom corners, floor, right wall
    r = 0.13
    left, right, top, bottom = 0.155, 0.845, 0.545, 0.885
    segs += polyline([(left, top), (left, bottom - r)])
    segs += polyline(arc_points(left + r, bottom - r, r, math.pi, math.pi / 2))
    segs += polyline([(left + r, bottom), (right - r, bottom)])
    segs += polyline(arc_points(right - r, bottom - r, r, math.pi / 2, 0))
    segs += polyline([(right, bottom - r), (right, top)])
    return recentre(segs, GLYPH_SCALE)


def recentre(segs, scale):
    """Scale about the drawing's own centre and place it in the canvas centre."""
    xs = [p[0] for seg in segs for p in seg]
    ys = [p[1] for seg in segs for p in seg]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2

    def move(p):
        return (0.5 + (p[0] - cx) * scale, 0.5 + (p[1] - cy) * scale)

    return [(move(a), move(b)) for a, b in segs]


def dist_to_segment(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    denom = dx * dx + dy * dy
    t = 0.0 if denom == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / denom))
    return math.hypot(px - (ax + dx * t), py - (ay + dy * t))




MASTER = 1024


def render_master(segs, size=MASTER):
    """Analytic coverage: alpha falls off over roughly one pixel at the edge."""
    half = STROKE / 2
    boxes = [(min(a[0], b[0]) - half, min(a[1], b[1]) - half,
              max(a[0], b[0]) + half, max(a[1], b[1]) + half) for a, b in segs]

    rows = []
    for py in range(size):
        y = (py + 0.5) / size
        row = [0] * size
        for px in range(size):
            x = (px + 0.5) / size
            best = 1e9
            for (a, b), (x0, y0, x1, y1) in zip(segs, boxes):
                if x < x0 or x > x1 or y < y0 or y > y1:
                    continue
                d = dist_to_segment(x, y, a, b)
                if d < best:
                    best = d
                    if d <= 0:
                        break
            if best < 1e8:
                cov = (half - best) * size + 0.5
                row[px] = max(0, min(255, round(cov * 255)))
        rows.append(row)
    return rows


def downsample(master, target):
    """Area-average the master's alpha down to `target` pixels square."""
    n = len(master)
    step = n / target
    out = []
    for ty in range(target):
        y0, y1 = int(ty * step), max(int(ty * step) + 1, int((ty + 1) * step))
        row = []
        for tx in range(target):
            x0, x1 = int(tx * step), max(int(tx * step) + 1, int((tx + 1) * step))
            total = count = 0
            for y in range(y0, min(y1, n)):
                src = master[y]
                for x in range(x0, min(x1, n)):
                    total += src[x]
                    count += 1
            row.append(round(total / count) if count else 0)
        out.append(row)
    return out


def write_png(path, alpha_rows):
    size = len(alpha_rows)
    raw = bytearray()
    for row in alpha_rows:
        raw.append(0)
        for a in row:
            raw += bytes((0, 0, 0, a))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# The share sheet takes an action extension's icon from its *app icon set*, so
# the extension needs the full iOS slot list -- an imageset is ignored.
APPICON_SLOTS = [
    ("iphone", "20x20", "2x", 40), ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58), ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80), ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120), ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20), ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29), ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40), ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76), ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
]


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                        "ImageSaverAction", "Assets.xcassets")
    segs = build_glyph()
    print("rendering %dx%d master..." % (MASTER, MASTER))
    master = render_master(segs)

    cache = {MASTER: master}

    def at(size):
        if size not in cache:
            cache[size] = downsample(master, size)
        return cache[size]

    imageset = os.path.join(root, "ActionIcon.imageset")
    os.makedirs(imageset, exist_ok=True)
    for size in (60, 120, 180):
        write_png(os.path.join(imageset, "action-%d.png" % size), at(size))
    print("wrote ActionIcon.imageset")

    appicon = os.path.join(root, "AppIcon.appiconset")
    os.makedirs(appicon, exist_ok=True)
    entries = []
    for idiom, sizes, scale, px in APPICON_SLOTS:
        name = "icon-%d.png" % px
        write_png(os.path.join(appicon, name), at(px))
        entries.append('    {\n      "filename" : "%s",\n      "idiom" : "%s",\n'
                       '      "scale" : "%s",\n      "size" : "%s"\n    }'
                       % (name, idiom, scale, sizes))
    with open(os.path.join(appicon, "Contents.json"), "w") as f:
        f.write('{\n  "images" : [\n' + ",\n".join(entries)
                + '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    print("wrote AppIcon.appiconset (%d slots)" % len(APPICON_SLOTS))


if __name__ == "__main__":
    main()
