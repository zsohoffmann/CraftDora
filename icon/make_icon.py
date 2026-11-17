# CraftDora app icon generator – © 2026 Zsolt Hoffmann. Licensed under the GNU GPL v3.
# Usage: python3 make_icon.py <output folder>   (needs Pillow)
from PIL import Image, ImageDraw, ImageFilter
import os, sys

ART = [
    "................",
    "..O....OO....O..",
    ".OLO..OLPO..OPO.",
    ".OLPOOLPPPOOPDO.",
    ".OLPPLPPPPPPPDO.",
    ".OLPPPPPPPPPPDO.",
    ".OLPPPPPPPPPPDO.",
    "..OLPPPPPPPPDO..",
    "..OLPPPPPPPPDO..",
    "...OPPPPPPPDDO..",
    "....OODDDDDOO...",
    "......OGgO......",
    ".O....OGgO....O.",
    ".OO...OGgO...OO.",
    ".OGO..OGgO..OgO.",
    ".OGGO.OGgO.OggO.",
    "..OGGOOGgOOggO..",
    "...OGGGGggggO...",
    "....OOOOOOOO....",
]
PAL = {
    "O": (122, 22, 66),     # dark outline (petals)
    "L": (255, 196, 222),   # light pink highlight
    "P": (247, 110, 166),   # pink
    "D": (205, 58, 118),    # deep pink shadow
    "G": (98, 186, 92),     # green
    "g": (52, 132, 64),     # dark green
}
GREEN_OUTLINE = (30, 82, 44)

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Apple icon grid: 824x824 body with a 100 px margin, ~185 px corner radius
body = (100, 100, 924, 924)
R = 185

# shadow
sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sh).rounded_rectangle((100, 112, 924, 936), R, fill=(0, 0, 0, 90))
sh = sh.filter(ImageFilter.GaussianBlur(14))
img.alpha_composite(sh)

# background: soft cream → pale pink gradient
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
top, bot = (255, 247, 240), (255, 222, 234)
for y in range(S):
    t = min(1, max(0, (y - 100) / 824))
    c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    gd.line((0, y, S, y), fill=c + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(body, R, fill=255)

# subtle pixel grid in the background (embroidery fabric look)
grid = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gdr = ImageDraw.Draw(grid)
H, W = len(ART), len(ART[0])
px = 34
ox = (S - W * px) // 2
oy = (S - H * px) // 2 + 6
for x in range(ox % px, S, px):
    gdr.line((x, 0, x, S), fill=(214, 120, 160, 28), width=2)
for y in range(oy % px, S, px):
    gdr.line((0, y, S, y), fill=(214, 120, 160, 28), width=2)
grad.alpha_composite(grid)

img.paste(grad, (0, 0), mask)

# tulip pixels (with a soft shadow underneath)
tul = Image.new("RGBA", (S, S), (0, 0, 0, 0))
td = ImageDraw.Draw(tul)
for r, row in enumerate(ART):
    for c, ch in enumerate(row):
        if ch == ".":
            continue
        col = PAL[ch]
        if ch == "O" and r >= 11:
            col = GREEN_OUTLINE
        x0, y0 = ox + c * px, oy + r * px
        td.rectangle((x0, y0, x0 + px - 1, y0 + px - 1), fill=col + (255,))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.paste((150, 40, 90, 70), (0, 10), tul.split()[3])
shadow = shadow.filter(ImageFilter.GaussianBlur(8))
img.alpha_composite(shadow)
img.alpha_composite(tul)

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
img.save(os.path.join(out, "icon_1024.png"))

# .iconset (for iconutil) + a ready-made .icns
iconset = os.path.join(out, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        size = base * scale
        name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
        img.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
img.save(os.path.join(out, "AppIcon.icns"), sizes=[(16,16),(32,32),(64,64),(128,128),(256,256),(512,512),(1024,1024)])
