"""Makes the windows' cave backdrop, src/PintoTGD/Media/Cave.tga, from tools/art/cave.png,
and the mask that fades its right edge out, Media/FadeRight.tga.

    python tools/backdrop.py

Pure Python, standard library only. WoW wants textures with power-of-two sides, so the
picture (1672x941) is averaged down to 1024x512: a little squeezed, which the windows undo
with texture coordinates (UI/Frames.lua knows the picture's real shape, CAVE_ASPECT). It's
a background, so it has no alpha: a 24-bit TGA. The mask is white, opaque, and fades to
nothing over its last 2% from left to right.
"""
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "tools", "art", "cave.png")
TARGET = os.path.join(ROOT, "src", "PintoTGD", "Media", "Cave.tga")
FADE = os.path.join(ROOT, "src", "PintoTGD", "Media", "FadeRight.tga")
OUT_W, OUT_H = 1024, 512
FADE_FROM = 0.98


def read_png(path):
    """8-bit RGB or RGBA, not interlaced: (width, height, channels, rows of bytes)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError("needs an 8-bit RGB or RGBA PNG without interlacing")
            ch = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * ch
    rows, prev = [], bytearray(stride)
    for y in range(h):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 255
            elif ftype == 2:
                line[i] = (line[i] + b) & 255
            elif ftype == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, ch, rows


def shrink(w, h, ch, rows, ow, oh):
    """Area-averaged RGB, rows top to bottom."""
    out = []
    sx, sy = w / ow, h / oh
    for oy in range(oh):
        y0, y1 = oy * sy, (oy + 1) * sy
        spans = []
        y = int(y0)
        while y < y1 and y < h:
            spans.append((y, min(y + 1, y1) - max(y, y0)))
            y += 1
        line = bytearray()
        for ox in range(ow):
            x0, x1 = ox * sx, (ox + 1) * sx
            r = g = b = wsum = 0.0
            x = int(x0)
            while x < x1 and x < w:
                wx = min(x + 1, x1) - max(x, x0)
                k = x * ch
                for yy, wy in spans:
                    row = rows[yy]
                    wt = wx * wy
                    r += row[k] * wt
                    g += row[k + 1] * wt
                    b += row[k + 2] * wt
                    wsum += wt
                x += 1
            line += bytes((int(r / wsum + 0.5), int(g / wsum + 0.5), int(b / wsum + 0.5)))
        out.append(line)
    return out


def write_tga(path, w, h, rows):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 24, 0)
    out = bytearray(header)
    for row in reversed(rows):  # bottom-left origin
        for x in range(w):
            r, g, b = row[x * 3:x * 3 + 3]
            out += bytes((b, g, r))
    with open(path, "wb") as f:
        f.write(out)


def write_fade(path, w=256, h=8):
    """White, opaque, then fading to nothing over the last 2%, as a smooth step."""
    row = bytearray()
    for x in range(w):
        k = min(1.0, max(0.0, ((x + 0.5) / w - FADE_FROM) / (1 - FADE_FROM)))
        a = 1 - k * k * (3 - 2 * k)
        row += bytes((255, 255, 255, int(round(a * 255))))
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
    with open(path, "wb") as f:
        f.write(header + bytes(row) * h)


def main():
    w, h, ch, rows = read_png(SOURCE)
    print("read %s: %dx%d, aspect %.4f" % (os.path.relpath(SOURCE, ROOT), w, h, w / h))
    write_tga(TARGET, OUT_W, OUT_H, shrink(w, h, ch, rows, OUT_W, OUT_H))
    print("wrote %s: %dx%d" % (os.path.relpath(TARGET, ROOT), OUT_W, OUT_H))
    write_fade(FADE)
    print("wrote %s" % os.path.relpath(FADE, ROOT))


if __name__ == "__main__":
    main()
