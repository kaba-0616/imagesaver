"""Generate the share-sheet action icon.

iOS renders action-extension icons in the share sheet as *templates*: only the
alpha channel survives, and it is filled with the system tint. So the artwork
must be a transparent-background line drawing (like the stock Copy / Bookmark
glyphs), not a filled tile -- a fully opaque square renders as a solid square.
"""
import math, struct, zlib, os

STROKE = 0.075          # line width, fraction of canvas
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
    return segs


def dist_to_segment(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    denom = dx * dx + dy * dy
    t = 0.0 if denom == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / denom))
    return math.hypot(px - (ax + dx * t), py - (ay + dy * t))


def render(size, segs):
    half = STROKE / 2
    # Cheap rejection: a pixel far from every segment's bounding box is empty.
    boxes = [(min(a[0], b[0]) - half, min(a[1], b[1]) - half,
              max(a[0], b[0]) + half, max(a[1], b[1]) + half) for a, b in segs]

    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            hits = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) / size
                    y = (py + (sy + 0.5) / SS) / size
                    for (a, b), (x0, y0, x1, y1) in zip(segs, boxes):
                        if x < x0 or x > x1 or y < y0 or y > y1:
                            continue
                        if dist_to_segment(x, y, a, b) <= half:
                            hits += 1
                            break
            alpha = round(255 * hits / (SS * SS))
            row += bytes((0, 0, 0, alpha))
        rows.append(bytes(row))
    return rows


def write_png(path, size, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                       "ImageSaverAction", "Assets.xcassets", "ActionIcon.imageset")
    segs = build_glyph()
    for size in (60, 120, 180):
        write_png(os.path.join(out, "action-%d.png" % size), size, render(size, segs))
        print("wrote action-%d.png" % size)
