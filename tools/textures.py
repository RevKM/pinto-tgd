"""Draws every texture in src/PintoTGD/Media from the demo's own shapes.

    python tools/textures.py

Pure Python, standard library only. A small rasterizer fills SVG paths (M, L, Q, C, Z)
with the nonzero rule, with 4 vertical subsamples and exact horizontal coverage per row
for anti-aliasing. Strokes are unions of capsules along the flattened path, which matches
round joins and caps.

Tinted pieces are white with the shape in the alpha channel; WoW tints them in Lua.
Full-colour pieces (coins, gems, the haunch, hearts, the hoard, the minimap icon) carry
their own colours. Each texture is a 32-bit TGA for WoW plus a PNG for previews, and
src/PintoTGD/Render/MediaData.lua records the box of local units each texture covers.
"""
import math
import os
import re
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "src", "PintoTGD", "Media")
PREVIEW = os.path.join(ROOT, "tools", "sim", "out", "media")
DATA_LUA = os.path.join(ROOT, "src", "PintoTGD", "Render", "MediaData.lua")
WOW_PATH = "Interface\\\\AddOns\\\\PintoTGD\\\\Media\\\\"

# Paths -----------------------------------------------------------------------------------

TOKEN = re.compile(r"[MLQCZmlqcz]|-?\d*\.?\d+(?:e-?\d+)?")


def parse(d, steps=16):
    """Flattens an absolute SVG path into subpaths: list of (points, closed)."""
    toks = TOKEN.findall(d)
    i = 0
    subs = []
    cur = None
    pts = []
    cmd = None

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    while i < len(toks):
        t = toks[i]
        if t.isalpha():
            cmd = t
            i += 1
            if cmd in "Zz":
                if pts:
                    subs.append((pts, True))
                pts = []
                continue
        if cmd == "M":
            if pts:
                subs.append((pts, False))
            cur = (num(), num())
            pts = [cur]
            cmd = "L"
        elif cmd == "L":
            cur = (num(), num())
            pts.append(cur)
        elif cmd == "Q":
            c = (num(), num())
            e = (num(), num())
            p0 = cur
            for k in range(1, steps + 1):
                u = k / steps
                a, b, q = (1 - u) ** 2, 2 * u * (1 - u), u * u
                pts.append((a * p0[0] + b * c[0] + q * e[0], a * p0[1] + b * c[1] + q * e[1]))
            cur = e
        elif cmd == "C":
            c1 = (num(), num())
            c2 = (num(), num())
            e = (num(), num())
            p0 = cur
            for k in range(1, steps + 1):
                u = k / steps
                v = 1 - u
                a, b, c, q = v ** 3, 3 * v * v * u, 3 * v * u * u, u ** 3
                pts.append((a * p0[0] + b * c1[0] + c * c2[0] + q * e[0],
                            a * p0[1] + b * c1[1] + c * c2[1] + q * e[1]))
            cur = e
        else:
            raise ValueError("unsupported path command %r" % cmd)
    if pts:
        subs.append((pts, False))
    return subs


def ellipse(cx, cy, rx, ry, rot=0.0, n=72):
    c, s = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    pts = []
    for k in range(n):
        a = 2 * math.pi * k / n
        x, y = rx * math.cos(a), ry * math.sin(a)
        pts.append((cx + x * c - y * s, cy + x * s + y * c))
    return [(pts, True)]


def area(poly):
    s = 0.0
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        s += x0 * y1 - x1 * y0
    return s / 2


def oriented(poly):
    return poly if area(poly) > 0 else list(reversed(poly))


def capsule(a, b, r, n=10):
    """The convex outline of a thick segment with round caps, counter-clockwise."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    ang = math.atan2(dy, dx)
    pts = []
    for k in range(n + 1):
        t = ang - math.pi / 2 + math.pi * k / n
        pts.append((b[0] + r * math.cos(t), b[1] + r * math.sin(t)))
    for k in range(n + 1):
        t = ang + math.pi / 2 + math.pi * k / n
        pts.append((a[0] + r * math.cos(t), a[1] + r * math.sin(t)))
    return oriented(pts)


def fill_polys(subs):
    return [oriented(p) for p, _ in subs if len(p) >= 3]


def stroke_polys(subs, width):
    r = width / 2
    out = []
    for pts, closed in subs:
        seq = pts + ([pts[0]] if closed else [])
        if len(seq) == 1:
            seq = seq * 2
        for i in range(len(seq) - 1):
            out.append(capsule(seq[i], seq[i + 1], r))
    return out


# Canvas -----------------------------------------------------------------------------------

def pow2(n):
    p = 1
    while p < n:
        p *= 2
    return p


class Canvas:
    """Pixels covering a box of local units. Colours are premultiplied floats."""

    def __init__(self, box, ppu, square=False, fixed=None):
        x0, y0, x1, y1 = box
        if fixed:
            w, h = fixed
        else:
            w = pow2(max(8, int(math.ceil((x1 - x0) * ppu))))
            h = pow2(max(8, int(math.ceil((y1 - y0) * ppu))))
            if square:
                w = h = max(w, h)
        # widen the box to the power-of-two size, keeping it centred
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        if fixed:
            ppx, ppy = w / (x1 - x0), h / (y1 - y0)
        else:
            ppx = ppy = ppu
        self.x0, self.x1 = cx - w / ppx / 2, cx + w / ppx / 2
        self.y0, self.y1 = cy - h / ppy / 2, cy + h / ppy / 2
        if fixed:
            self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        self.w, self.h = w, h
        self.sx, self.sy = w / (self.x1 - self.x0), h / (self.y1 - self.y0)
        self.px = [0.0] * (w * h * 4)

    def to_px(self, polys):
        return [[((x - self.x0) * self.sx, (y - self.y0) * self.sy) for x, y in p] for p in polys]

    def coverage(self, polys, sub=4):
        w, h = self.w, self.h
        cov = [0.0] * (w * h)
        edges = []
        for poly in self.to_px(polys):
            n = len(poly)
            for i in range(n):
                xa, ya = poly[i]
                xb, yb = poly[(i + 1) % n]
                if ya == yb:
                    continue
                d = 1 if yb > ya else -1
                if ya > yb:
                    xa, ya, xb, yb = xb, yb, xa, ya
                edges.append((ya, yb, xa, (xb - xa) / (yb - ya), d))
        if not edges:
            return cov
        edges.sort()
        weight = 1.0 / sub
        for py in range(h):
            for s in range(sub):
                y = py + (s + 0.5) / sub
                xs = [(xa + (y - ya) * sl, d) for ya, yb, xa, sl, d in edges if ya <= y < yb]
                if len(xs) < 2:
                    continue
                xs.sort()
                wind = 0
                row = py * w
                for k in range(len(xs) - 1):
                    wind += xs[k][1]
                    if wind == 0:
                        continue
                    a = max(0.0, xs[k][0])
                    b = min(float(w), xs[k + 1][0])
                    if b <= a:
                        continue
                    ia, ib = int(a), int(b)
                    if ia == ib:
                        cov[row + ia] += (b - a) * weight
                    else:
                        cov[row + ia] += (ia + 1 - a) * weight
                        for x in range(ia + 1, min(ib, w)):
                            cov[row + x] += weight
                        if ib < w:
                            cov[row + ib] += (b - ib) * weight
        return [min(1.0, c) for c in cov]

    def paint(self, polys, color, alpha=1.0):
        r, g, b = hexrgb(color)
        cov = self.coverage(polys)
        px = self.px
        for i, c in enumerate(cov):
            if c <= 0:
                continue
            a = c * alpha
            k = i * 4
            inv = 1 - a
            px[k] = r * a + px[k] * inv
            px[k + 1] = g * a + px[k + 1] * inv
            px[k + 2] = b * a + px[k + 2] * inv
            px[k + 3] = a + px[k + 3] * inv

    def fill(self, subs, color, alpha=1.0):
        self.paint(fill_polys(subs), color, alpha)

    def stroke(self, subs, color, width, alpha=1.0):
        self.paint(stroke_polys(subs, width), color, alpha)

    def rgba_rows(self, white=False):
        """Straight-alpha RGBA bytes, rows top to bottom."""
        rows = []
        px = self.px
        for y in range(self.h):
            row = bytearray()
            for x in range(self.w):
                k = (y * self.w + x) * 4
                a = px[k + 3]
                if white:
                    row += bytes((255, 255, 255, int(round(min(1, a) * 255))))
                elif a <= 1e-6:
                    row += bytes((0, 0, 0, 0))
                else:
                    row += bytes((int(round(min(1, px[k] / a) * 255)), int(round(min(1, px[k + 1] / a) * 255)),
                                  int(round(min(1, px[k + 2] / a) * 255)), int(round(min(1, a) * 255))))
            rows.append(bytes(row))
        return rows


def hexrgb(h):
    h = h.lstrip("#")
    return int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255


# Files ------------------------------------------------------------------------------------

def write_tga(path, w, h, rows):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
    out = bytearray(header)
    for row in reversed(rows):  # bottom-left origin
        for x in range(w):
            r, g, b, a = row[x * 4:x * 4 + 4]
            out += bytes((b, g, r, a))
    with open(path, "wb") as f:
        f.write(out)


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


META = {}


def save(name, canvas, white=False):
    rows = canvas.rgba_rows(white)
    write_tga(os.path.join(MEDIA, name + ".tga"), canvas.w, canvas.h, rows)
    write_png(os.path.join(PREVIEW, name + ".png"), canvas.w, canvas.h, rows)
    META[name] = (canvas.x0, canvas.y0, canvas.x1, canvas.y1)
    print("%-16s %4dx%-4d" % (name, canvas.w, canvas.h))


def bbox(subs, pad):
    xs = [x for p, _ in subs for x, _ in p]
    ys = [y for p, _ in subs for _, y in p]
    return (min(xs) - pad, min(ys) - pad, max(xs) + pad, max(ys) + pad)


# The demo's shapes --------------------------------------------------------------------------

HEAD = ("M2,-10C-3,-22 0,-40 16,-48C28,-55 48,-55 60,-49C68,-45 72,-39 79,-36C88,-33 99,-32 104,-26"
        "C109,-21 108,-12 102,-9C92,-6 72,-6 58,-7C40,-8 18,-6 2,-10Z")
JAWP = [(12, -10), (14, -2), (28, 1), (50, 1), (72, 1), (90, -1), (98, -6), (101, -8), (100, -11), (96, -12),
        (80, -14), (50, -16), (30, -16), (20, -16), (12, -14), (12, -10)]
JAW = "M%g,%g" % JAWP[0] + "".join("C%g,%g %g,%g %g,%g" % (JAWP[i] + JAWP[i + 1] + JAWP[i + 2])
                                   for i in range(1, 16, 3)) + "Z"
HORN_BACK = "M24,-49Q8,-60 -14,-74Q12,-68 38,-53Z"
FIN = "M4,-28Q-14,-36 -24,-24Q-10,-24 3,-16Z"
HORN_FRONT = "M14,-44Q-2,-48 -26,-60Q2,-63 30,-52Z"
FANG = "M89,-9L92,-3L95,-9Z"
SPADE = "M-3,0C4,-11 13,-11 21,0C13,11 4,11 -3,0Z"
CLAWS = "M10,-5L18,-3L11,-1ZM11,1L19,3L11,5Z"
TOES = "M3,-6Q6,0 3,6M-4,-7Q-1,0 -4,7"
HEART = "M0,4C-7,-2 -4,-9 0,-4.5C4,-9 7,-2 0,4Z"
GEM = "M0,-6L6,-1L0,6L-6,-1Z"
GEM_LINE = "M-6,-1L6,-1"
GEMS = [("GemRed", "#E24B4A", "#791F1F"), ("GemBlue", "#378ADD", "#0C447C"), ("GemGreen", "#639922", "#27500A")]
# Pinto's colours: the demo's Ruby preset (body, belly, spikes), with the shades worked out
# the way Render/Pinto.lua's palette() does
RUBY = {"dk": "#580600", "bd": "#e2574c", "wg": "#bb1306", "sh": "#820a00", "bl": "#fac775", "pl": "#d58608",
        "sp": "#faeeda", "hn": "#a18b68"}

# the demo's coin field, from its seeded random numbers
G = 392


class Rnd:
    def __init__(self, seed=11):
        self.seed = seed

    def __call__(self):
        self.seed = self.seed * 16807 % 2147483647
        return self.seed / 2147483647


def js_round(v):
    return math.floor(v + 0.5)


def r1(v):
    return js_round(v * 10) / 10


def coin_field():
    rnd = Rnd()
    cols = ["#FAC775", "#EF9F27", "#FAC775", "#EF9F27", "#FAEEDA"]
    coins = []
    for r in range(18):
        for c in range(48):
            x = r1(24 + c * 13.5 + (r % 2) * 6.7 + (rnd() - 0.5) * 6)
            y = r1(G - 2 - r * 8.6 + (rnd() - 0.5) * 3)
            a = js_round((rnd() - 0.5) * 40)
            col = cols[int(math.floor(rnd() * 5))]
            coins.append((x, y, a, col))
    return coins


# Textures ---------------------------------------------------------------------------------

def make_basics():
    # Tri: the triangle the SetTexCoord trick maps onto any triangle. Corners at pixel
    # (8,8), (248,8) and (8,248) of 256; everything outside is transparent.
    c = Canvas((0, 0, 256, 256), 1, fixed=(256, 256))
    c.fill([([(8, 8), (248, 8), (8, 248)], True)], "#FFFFFF")
    save("Tri", c, white=True)

    # Circle: a disc of radius 1 in a box of +-64/60.
    k = 64 / 60
    c = Canvas((-k, -k, k, k), 1, fixed=(128, 128))
    c.fill(ellipse(0, 0, 1, 1, n=180), "#FFFFFF")
    save("Circle", c, white=True)

    # Mote: a soft glow for the quest-eaten animation.
    c = Canvas((-1, -1, 1, 1), 1, fixed=(64, 64))
    for i in range(24):
        r = 1 - i / 24
        c.fill(ellipse(0, 0, r, r, n=64), "#FFFFFF", alpha=0.07)
    save("Mote", c, white=True)


def piece(name, d, pad, ppu=3.0, kind="fill", width=0.0, dilate=0.0):
    subs = parse(d)
    box = bbox(subs, pad)
    c = Canvas(box, ppu)
    if kind == "fill":
        c.fill(subs, "#FFFFFF")
        if dilate:
            c.stroke([(p, True) for p, _ in subs], "#FFFFFF", dilate * 2)
    else:
        c.stroke(subs, "#FFFFFF", width)
    save(name, c, white=True)


def make_head():
    piece("HeadFill", HEAD, 6)
    piece("HeadOutline", HEAD, 6, dilate=2.7)
    piece("JawFill", JAW, 6)
    piece("JawOutline", JAW, 6, dilate=2.7)
    piece("HornBackFill", HORN_BACK, 4)
    piece("HornBackStroke", HORN_BACK, 4, kind="stroke", width=2.5)
    piece("FinFill", FIN, 4)
    piece("FinStroke", FIN, 4, kind="stroke", width=2.3)
    piece("HornFrontFill", HORN_FRONT, 4)
    piece("HornFrontStroke", HORN_FRONT, 4, kind="stroke", width=2.5)
    piece("FangFill", FANG, 3, ppu=4)
    piece("FangStroke", FANG, 3, ppu=4, kind="stroke", width=1.2)
    piece("SpadeFill", SPADE, 4)
    piece("SpadeStroke", SPADE, 4, kind="stroke", width=2.5)


def make_paw():
    box = (-17, -12, 23, 12)
    for name, draw in (
        ("PawClaws", lambda c: c.fill(parse(CLAWS), "#FFFFFF")),
        ("PawClawsStroke", lambda c: c.stroke(parse(CLAWS), "#FFFFFF", 1.5)),
        ("PawFill", lambda c: c.fill(ellipse(0, 0, 13, 8), "#FFFFFF")),
        ("PawStroke", lambda c: (c.stroke(ellipse(0, 0, 13, 8), "#FFFFFF", 2.5), c.stroke(parse(TOES), "#FFFFFF", 1.5))),
    ):
        c = Canvas(box, 4)
        draw(c)
        save(name, c, white=True)


def draw_haunch(c):
    bone = parse("M4,-3L14,-10")
    c.stroke(bone, "#633806", 7)
    c.stroke(bone, "#FAEEDA", 4)
    for cx, cy in ((15, -12.5), (17.5, -9)):
        c.fill(ellipse(cx, cy, 3.6, 3.6), "#FAEEDA")
        c.stroke(ellipse(cx, cy, 3.6, 3.6), "#633806", 1.5)
    meat = ellipse(-4, 3, 11, 8.5, rot=-35)
    c.fill(meat, "#BA7517")
    c.stroke(meat, "#633806", 2)
    c.stroke(parse("M-11,2Q-8,-4 -1,-4"), "#EF9F27", 2)


def make_colour_pieces():
    c = Canvas((-18, -20, 24, 16), 6)
    draw_haunch(c)
    save("Haunch", c)

    c = Canvas((-9, -11, 9, 7), 3.5)
    c.fill(parse(HEART), "#ED93B1")
    c.stroke(parse(HEART), "#993556", 1.5)
    save("Heart", c)

    for name, fill, edge in GEMS:
        c = Canvas((-9, -9, 9, 9), 3.5)
        c.fill(parse(GEM), fill)
        c.stroke(parse(GEM), edge, 1.5)
        c.stroke(parse(GEM_LINE), edge, 1.5)
        save(name, c)

    for name, rx, ry, fill in (("CoinRimGold", 6.8, 3, "#FAC775"), ("CoinRimPale", 6.8, 3, "#FAEEDA"),
                               ("CoinLoose", 6.2, 2.2, "#FAC775")):
        c = Canvas((-8.5, -4.5, 8.5, 4.5), 3.5)
        c.fill(ellipse(0, 0, rx, ry), fill)
        c.stroke(ellipse(0, 0, rx, ry), "#BA7517", 1)
        save(name, c)


def make_hoard():
    # 1 pixel per scene unit: x 0..1024, y 232..488 (only y <= 392 is ever shown)
    c = Canvas((0, 232, 1024, 488), 1, fixed=(1024, 256))
    c.fill([([(0, 232), (1024, 232), (1024, 488), (0, 488)], True)], "#EF9F27")
    for x, y, a, col in coin_field():
        e = ellipse(x, y, 6.4, 2.9, rot=a, n=36)
        c.fill(e, col)
        c.stroke(e, "#BA7517", 1)
    save("Hoard", c)


def make_minimap_head():
    # Pinto's head in the Ruby colours, tilted up a little, in a round icon
    c = Canvas((-14, -84, 116, 46), 0.5, fixed=(64, 64))

    def rot(subs, ang=-12, cx=50, cy=-28):
        ca, sa = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        return [([(cx + (x - cx) * ca - (y - cy) * sa, cy + (x - cx) * sa + (y - cy) * ca) for x, y in p], cl)
                for p, cl in subs]

    bg = ellipse(51, -19, 63, 63)
    c.fill(bg, "#2a1714")
    c.fill(rot(parse(HORN_BACK)), RUBY["hn"])
    c.stroke(rot(parse(HORN_BACK)), RUBY["dk"], 2.5)
    head, jaw = rot(parse(HEAD)), rot(parse(JAW))
    c.fill(head, RUBY["dk"])
    c.stroke([(p, True) for p, _ in head], RUBY["dk"], 5.4)
    c.fill(jaw, RUBY["dk"])
    c.stroke([(p, True) for p, _ in jaw], RUBY["dk"], 5.4)
    c.fill(head, RUBY["bd"])
    c.fill(jaw, RUBY["bd"])
    c.fill(rot(parse(FIN)), RUBY["wg"])
    c.stroke(rot(parse(FIN)), RUBY["dk"], 2.3)
    c.stroke(rot(parse("M62,-12Q80,-8 101,-9")), RUBY["dk"], 2.3)
    c.fill(rot(ellipse(50, -28, 7.5, 9)), "#FFFFFF")
    c.fill(rot(ellipse(51.5, -27.5, 4.6, 4.6)), RUBY["dk"])
    c.fill(rot(ellipse(53.1, -29.7, 1.7, 1.7)), "#FFFFFF")
    c.stroke(rot(ellipse(50, -28, 7.5, 9)), RUBY["dk"], 2.2)
    c.stroke(rot(parse("M41,-39.5Q50,-44 59,-42.5")), RUBY["dk"], 3)
    c.stroke(rot(parse("M91,-26Q94,-29 97,-25")), RUBY["dk"], 2.3)
    c.fill(rot(parse(HORN_FRONT)), RUBY["bl"])
    c.stroke(rot(parse(HORN_FRONT)), RUBY["dk"], 2.5)
    # keep only the round icon
    keep = c.coverage(fill_polys(bg))
    for i, k in enumerate(keep):
        for j in range(4):
            c.px[i * 4 + j] *= k
    save("MinimapHead", c)


def make_quest_mark():
    # the quest list's bullet: a yellow disc with a dark red-brown rim and a soft yellow
    # glow, like the game's quest markers, with a bold exclamation mark in the middle
    c = Canvas((-32, -32, 32, 32), 1, fixed=(64, 64))
    for i in range(18):
        r = 30 - i * 0.75
        c.fill(ellipse(0, 0, r, r, n=96), "#FFC93C", alpha=0.05)
    disc = ellipse(0, 0, 17, 17, n=120)
    c.fill(disc, "#F2B02A")
    c.fill(ellipse(0, -2.5, 15.5, 14, n=120), "#FFD84A")
    c.fill(ellipse(-4.5, -9, 7.5, 4, rot=-18, n=60), "#FFF2B0", alpha=0.75)
    c.stroke(disc, "#5A1A0B", 3)
    ink = "#4A1208"
    c.fill([([(-3.5, -11.5), (3.5, -11.5), (2.2, 3.6), (-2.2, 3.6)], True)], ink)
    c.fill(ellipse(0, -11.5, 3.5, 2.2, n=40), ink)
    c.fill(ellipse(0, 3.6, 2.2, 1.4, n=32), ink)
    c.fill(ellipse(0, 9.8, 2.9, 2.9, n=40), ink)
    save("QuestMark", c)


def write_meta():
    os.makedirs(os.path.dirname(DATA_LUA), exist_ok=True)
    with open(DATA_LUA, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- Written by tools/textures.py: each texture in Media/ and the box of its own\n")
        f.write("-- local units it covers, as { path, x0, y0, x1, y1 } (x0, y0 is the top-left pixel).\n")
        f.write("local ADDON, ns = ...\n\nns.RenderMedia = {\n")
        for name in sorted(META):
            x0, y0, x1, y1 = META[name]
            f.write('  %s = { "%s%s", %.4f, %.4f, %.4f, %.4f },\n' % (name, WOW_PATH, name, x0, y0, x1, y1))
        f.write("}\n")


def main():
    os.makedirs(MEDIA, exist_ok=True)
    os.makedirs(PREVIEW, exist_ok=True)
    make_basics()
    make_head()
    make_paw()
    make_colour_pieces()
    make_hoard()
    make_minimap_head()
    make_quest_mark()
    write_meta()
    print("wrote", len(META), "textures and", DATA_LUA)


if __name__ == "__main__":
    main()
