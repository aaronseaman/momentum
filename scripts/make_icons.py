"""Generates Momentum's app icons (iOS full-bleed + macOS rounded) into the asset catalog."""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "Momentum", "Assets.xcassets", "AppIcon.appiconset")
S = 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, top=(79, 70, 229), bottom=(6, 182, 212)):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x * 0.35 + y * 0.65) / size
            px[x, y] = lerp(top, bottom, min(1, t))
    return img


def glyph(size):
    """Two forward chevrons: momentum."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w = int(size * 0.085)
    def chevron(cx, alpha):
        h = size * 0.22
        pts = [(cx - h * 0.55, size / 2 - h), (cx + h * 0.45, size / 2), (cx - h * 0.55, size / 2 + h)]
        d.line(pts, fill=(255, 255, 255, alpha), width=w, joint="curve")
        for p in (pts[0], pts[2]):
            d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=(255, 255, 255, alpha))
        p = pts[1]
        d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=(255, 255, 255, alpha))
    chevron(size * 0.42, 150)
    chevron(size * 0.60, 255)
    return layer


def ios_icon():
    base = gradient(S).convert("RGBA")
    base.alpha_composite(glyph(S))
    return base.convert("RGB")


def mac_icon():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    inset, radius = 100, 185
    box = (inset, inset, S - inset, S - inset)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 12, box[2], box[3] + 12), radius, fill=(0, 0, 0, 90))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    body = gradient(S).convert("RGBA")
    g = glyph(S - 2 * inset)
    body.alpha_composite(g, (inset, inset))
    canvas.paste(body, (0, 0), mask)
    return canvas


def main():
    os.makedirs(OUT, exist_ok=True)
    images = []
    ios_icon().save(os.path.join(OUT, "ios-1024.png"))
    images.append({"filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"})
    mac = mac_icon()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"mac-{points}@{scale}x.png"
            mac.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    main()
