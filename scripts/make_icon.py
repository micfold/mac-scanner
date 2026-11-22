"""Draws the Skener app icon and writes Resources/AppIcon.icns (+ a 1024 px PNG preview).

Run: python3 scripts/make_icon.py   (needs Pillow)
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 4                      # supersampling factor
N = 1024 * S               # working canvas


def px(v):
    return int(round(v * S))


def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def vertical_gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def sheet(draw, x, y, w, h, fold, fill, outline=None):
    """A sheet of paper with a folded top-right corner."""
    r = px(26)
    x0, y0, x1, y1 = px(x), px(y), px(x + w), px(y + h)
    f = px(fold)
    draw.rounded_rectangle((x0, y0, x1, y1), radius=r, fill=fill)
    # cut the corner and draw the fold
    draw.polygon([(x1 - f, y0), (x1 + 1, y0), (x1 + 1, y0 + f)], fill=(0, 0, 0, 0))
    return (x1 - f, y0, x1, y0 + f)


def draw_icon():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # --- body (Apple macOS grid: 824 px square, 100 px margin) with soft shadow
    body = (px(100), px(100), px(924), px(924))
    radius = px(186)
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + px(14), body[2], body[3] + px(14)),
                                             radius=radius, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(18))))

    grad = vertical_gradient((N, N), (40, 132, 255), (16, 64, 196)).convert("RGBA")
    img.paste(grad, (0, 0), rounded_mask((N, N), body, radius))

    # subtle top highlight (composited, so the body stays opaque)
    hl_mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(hl_mask).rectangle((0, 0, N, px(380)), fill=255)
    hl_mask = hl_mask.filter(ImageFilter.GaussianBlur(px(120)))
    hl_alpha = ImageChops.multiply(hl_mask, rounded_mask((N, N), body, radius)).point(lambda v: v * 40 // 255)
    hl = Image.new("RGBA", (N, N), (255, 255, 255, 0))
    hl.putalpha(hl_alpha)
    img.alpha_composite(hl)

    # --- stacked sheets (a batch)
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    sx, sy, sw, sh, fold = 300, 238, 410, 532, 104

    for dx, dy, alpha in ((44, 40, 120), (22, 20, 175)):
        sheet(d, sx + dx, sy + dy, sw, sh, fold, (255, 255, 255, alpha))

    # sheet shadow
    sh_layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(sh_layer).rounded_rectangle((px(sx), px(sy + 10), px(sx + sw), px(sy + sh + 10)),
                                               radius=px(26), fill=(0, 20, 80, 110))
    layer.alpha_composite(sh_layer.filter(ImageFilter.GaussianBlur(px(16))))
    d = ImageDraw.Draw(layer)
    fold_box = sheet(d, sx, sy, sw, sh, fold, (255, 255, 255, 255))
    fx0, fy0, fx1, fy1 = fold_box
    d.polygon([(fx0, fy0), (fx0, fy1), (fx1, fy1)], fill=(205, 220, 244, 255))

    # text lines on the front sheet
    line_color = (178, 196, 226, 255)
    lx = sx + 54
    lines = [(lx, 330, 190, 26, (40, 100, 230, 255))]          # heading in accent blue
    for i, w in enumerate((300, 280, 300, 230, 300, 260, 180)):
        lines.append((lx, 392 + i * 50, w, 16, line_color))
    for x, y, w, h, c in lines:
        d.rounded_rectangle((px(x), px(y), px(x + w), px(y + h)), radius=px(h / 2), fill=c)

    img.alpha_composite(layer)

    # --- scanning beam with glow, and a tint on the already-scanned part
    beam_y = 600
    tint = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(tint).rectangle((px(sx), px(sy), px(sx + sw), px(beam_y)), fill=(70, 210, 190, 26))
    front_mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(front_mask).rounded_rectangle((px(sx), px(sy), px(sx + sw), px(sy + sh)), radius=px(26), fill=255)
    img.paste(Image.alpha_composite(img, tint), (0, 0), front_mask)

    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((px(190), px(beam_y - 20), px(834), px(beam_y + 20)),
                                           radius=px(20), fill=(90, 255, 215, 150))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(px(26))))
    beam = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(beam).rounded_rectangle((px(210), px(beam_y - 7), px(814), px(beam_y + 7)),
                                           radius=px(7), fill=(225, 255, 245, 255))
    img.alpha_composite(beam)

    # keep everything inside the body shape
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    body_mask = rounded_mask((N, N), body, radius)
    out.alpha_composite(img)  # shadow outside body is intended
    clipped = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    clipped.paste(img, (0, 0), body_mask)
    shadow_only = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    shadow_only.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(18))))
    shadow_only.alpha_composite(clipped)
    return shadow_only.resize((1024, 1024), Image.LANCZOS)


def png_bytes(im, size):
    b = io.BytesIO()
    im.resize((size, size), Image.LANCZOS).save(b, format="PNG")
    return b.getvalue()


def write_icns(master, path):
    entries = [("icp4", 16), ("icp5", 32), ("ic07", 128), ("ic08", 256), ("ic09", 512),
               ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
    body = b""
    for kind, size in entries:
        data = png_bytes(master, size)
        body += kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    icon = draw_icon()
    (root / "Resources").mkdir(exist_ok=True)
    icon.save(root / "Resources" / "AppIcon.png")
    write_icns(icon, root / "Resources" / "AppIcon.icns")
    print("wrote", root / "Resources" / "AppIcon.icns")
