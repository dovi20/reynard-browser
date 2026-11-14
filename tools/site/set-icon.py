#!/usr/bin/env python3
"""
Set the app icon (AppIcon.appiconset) before building, and export the icons the
app shows at runtime (loading screen, hub switcher).

Usage:
    set-icon.py --sites "Name=https://a.example, https://b.example"
                [--icon URL_OR_PATH] [--export DIR]

App icon: --icon when given; otherwise the site's apple-touch-icon (or its largest
<link rel=icon>) for a single site, or a generated icon for a hub of several sites.
If nothing usable is found, the default icon is kept and the script exits 0.

--export DIR writes app.png and one <site id>.png per site (256px); the packaging
step copies them into the app as SiteIcons/.

Requires Pillow (pip install pillow).
"""

import argparse
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
    for path in ("/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/favicon.ico"):
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


def parse_sites(spec):
    """Same rules as SiteCatalog in the app: returns [(id, name, url)]."""
    sites = []
    for entry in re.split(r"[,;\n]", spec):
        entry = entry.strip()
        if not entry:
            continue
        name, url = "", entry
        if "=" in entry:
            left, right = entry.split("=", 1)
            if "/" not in left and "?" not in left:
                name, url = left.strip(), right.strip()
        if "://" not in url:
            url = "https://" + url
        host = (urllib.parse.urlsplit(url).hostname or "").lower()
        if "." not in host:
            print(f"skip {entry}: not a website address")
            continue
        if host.startswith("www."):
            host = host[4:]
        site_id, suffix = host, 2
        while any(existing[0] == site_id for existing in sites):
            site_id = f"{host}-{suffix}"
            suffix += 1
        sites.append((site_id, name or host, url))
    return sites


def site_icon(url, minimum_side):
    for source in candidate_urls(url):
        try:
            image = load_image(source)
        except Exception as error:  # noqa: BLE001
            print(f"skip {source}: {error}")
            continue
        if min(image.size) < minimum_side:
            print(f"skip {source}: too small ({image.size[0]}x{image.size[1]})")
            continue
        print(f"icon for {url}: {source} ({image.size[0]}x{image.size[1]})")
        return to_app_icon(image)
    print(f"warning: no usable icon found on {url}")
    return None


def hub_icon():
    """A plain original icon for hubs: four tiles on a dark gradient."""
    from PIL import ImageDraw

    scale = 2
    side = SIZE * scale
    top, bottom = (40, 38, 72), (17, 16, 34)
    column = Image.new("RGB", (1, side))
    for y in range(side):
        t = y / (side - 1)
        column.putpixel((0, y), tuple(round(top[c] + (bottom[c] - top[c]) * t) for c in range(3)))
    canvas = column.resize((side, side))
    draw = ImageDraw.Draw(canvas)

    margin = side * 0.21
    gap = side * 0.06
    tile = (side - 2 * margin - gap) / 2
    colors = [(246, 242, 255), (168, 152, 255), (112, 196, 255), (255, 176, 120)]
    for index, color in enumerate(colors):
        x = margin + (index % 2) * (tile + gap)
        y = margin + (index // 2) * (tile + gap)
        draw.rounded_rectangle((x, y, x + tile, y + tile), radius=tile * 0.28, fill=color)
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description="Set the site app icon and export runtime icons")
    parser.add_argument("--sites", required=True, help='"Name=https://a.example, https://b.example"')
    parser.add_argument("--icon", default="", help="app icon URL or path (optional)")
    parser.add_argument("--export", default="", help="folder for app.png and <site id>.png")
    args = parser.parse_args()

    sites = parse_sites(args.sites)
    if not sites:
        print("error: --sites has no usable website address")
        return 1
    is_hub = len(sites) > 1
    explicit = args.icon.strip()

    icons = {}
    for site_id, _name, url in sites:
        if is_hub or not explicit:
            # A hub shows site icons small; an app icon needs more pixels
            icons[site_id] = site_icon(url, 32 if is_hub else 57)

    app_icon = None
    if explicit:
        try:
            app_icon = to_app_icon(load_image(explicit))
            print(f"App icon set from {explicit}")
        except Exception as error:  # noqa: BLE001
            print(f"error: could not use icon {explicit}: {error}")
            return 1
    elif is_hub:
        app_icon = hub_icon()
        print("App icon generated for the hub")
    else:
        app_icon = icons.get(sites[0][0])
        if app_icon is None:
            print("warning: keeping the default app icon")

    if app_icon is not None:
        for name in ICON_FILES:
            app_icon.save(os.path.join(ICONSET, name), "PNG")

    if args.export:
        os.makedirs(args.export, exist_ok=True)
        export_side = 256
        if app_icon is not None:
            app_icon.resize((export_side, export_side), Image.LANCZOS).save(os.path.join(args.export, "app.png"), "PNG")
        for site_id, icon in icons.items():
            if icon is not None:
                icon.resize((export_side, export_side), Image.LANCZOS).save(
                    os.path.join(args.export, f"{site_id}.png"), "PNG"
                )
        print(f"Exported icons to {args.export}: {sorted(os.listdir(args.export))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
