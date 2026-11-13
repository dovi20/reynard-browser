#!/usr/bin/env python3
"""
Replace the app icon (AppIcon.appiconset) before building.

Usage:
    set-icon.py <site-url> [icon-url-or-path]

When no icon is given, the site's apple-touch-icon (or the largest <link rel=icon>)
is used. If nothing usable is found, the default icon is kept and the script exits 0.
Requires Pillow (pip install pillow).
"""

import io
import os
import re
import sys
import urllib.parse
import urllib.request
from html.parser import HTMLParser

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICONSET = os.path.join(ROOT, "browser", "Reynard", "Resources", "Assets.xcassets", "AppIcon.appiconset")
ICON_FILES = ("icon.png", "icon-dark.png", "icon-tint.png")
SIZE = 1024
USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"


def fetch(url, limit=10 * 1024 * 1024):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read(limit), response.geturl()


class IconLinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.candidates = []  # (priority, size, href)

    def handle_starttag(self, tag, attrs):
        if tag != "link":
            return
        attrs = {k.lower(): (v or "") for k, v in attrs}
        rel = attrs.get("rel", "").lower().split()
        href = attrs.get("href", "")
        if not href:
            return
        sizes = [int(n) for n in re.findall(r"(\d+)x\d+", attrs.get("sizes", ""))]
        size = max(sizes) if sizes else 0
        if "apple-touch-icon" in rel or "apple-touch-icon-precomposed" in rel:
            self.candidates.append((2, size or 180, href))
        elif "icon" in rel and not href.lower().endswith(".svg"):
            self.candidates.append((1, size, href))


def candidate_urls(site_url):
    urls = []
    try:
        html, final_url = fetch(site_url, limit=2 * 1024 * 1024)
        parser = IconLinkParser()
        parser.feed(html.decode("utf-8", "replace"))
        for _, _, href in sorted(parser.candidates, reverse=True):
            urls.append(urllib.parse.urljoin(final_url, href))
        base = final_url
    except Exception as error:  # noqa: BLE001
        print(f"warning: could not read {site_url}: {error}")
        base = site_url
    for path in ("/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"):
        urls.append(urllib.parse.urljoin(base, path))
    return urls


def load_image(source):
    if os.path.exists(source):
        with open(source, "rb") as handle:
            data = handle.read()
    else:
        data, _ = fetch(source)
    image = Image.open(io.BytesIO(data))
    image.load()
    return image


def to_app_icon(image):
    image = image.convert("RGBA")
    # Square it on an opaque canvas (iOS renders transparent icon pixels as black)
    side = max(image.size)
    background = (255, 255, 255, 255)
    corner = image.getpixel((0, 0))
    if corner[3] == 255:
        background = corner
    canvas = Image.new("RGBA", (side, side), background)
    canvas.paste(image, ((side - image.width) // 2, (side - image.height) // 2), image)
    return canvas.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    site_url = sys.argv[1]
    explicit = sys.argv[2].strip() if len(sys.argv) > 2 else ""
    sources = [explicit] if explicit else candidate_urls(site_url)

    for source in sources:
        try:
            image = load_image(source)
        except Exception as error:  # noqa: BLE001
            print(f"skip {source}: {error}")
            continue
        if min(image.size) < 57 and not explicit:
            print(f"skip {source}: too small ({image.size[0]}x{image.size[1]})")
            continue
        icon = to_app_icon(image)
        for name in ICON_FILES:
            icon.save(os.path.join(ICONSET, name), "PNG")
        print(f"App icon set from {source} ({image.size[0]}x{image.size[1]} -> {SIZE}x{SIZE})")
        return 0

    if explicit:
        print(f"error: could not use icon {explicit}")
        return 1
    print("warning: no usable icon found on the site; keeping the default icon")
    return 0


if __name__ == "__main__":
    sys.exit(main())
