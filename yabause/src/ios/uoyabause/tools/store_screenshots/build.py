#!/usr/bin/env python3
"""Render the localized App Store marketing screenshots.

The layout comes from the Claude Design canvas ("YabaSanshiro AppStore
プロモーション画像"); this reproduces one artboard per page at its exact store
pixel size and shoots it with headless Chrome, once per locale in
strings.json. The device images and bezels live in ./assets, exported from
that same canvas.

    python3 tools/store_screenshots/build.py [--variant YabaSnashiro-Lite]
                                            [--locale ja] [--only-html]

Output: screenshots/marketing/<variant>/<locale>/*.png, named so the App Store
order matches the canvas order.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
ASSETS = os.path.join(HERE, "assets")
WORK = os.path.join(HERE, "build")
OUT = os.path.join(PROJECT, "screenshots", "marketing")

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# The locales the App Store listing actually has. strings.json also carries ru,
# which the Snapfile captures but the listing has no localization for, so it is
# rendered only when asked for by name: deliver aborts on a folder whose locale
# the app does not have.
STORE_LOCALES = ["en-US", "ja", "es-MX", "pt-BR", "zh-Hans"]

FONTS = ("https://fonts.googleapis.com/css2?family=Archivo:wght@500;700;900"
         "&family=IBM+Plex+Sans:wght@400;500&family=IBM+Plex+Mono:wght@500&display=swap")

# One entry per artboard, in the order the App Store shows them. Each names
# the bezel it is framed in, since the captures come from more than one iPad.
SHOTS = [
    dict(key="ui",    device="phone", bezel="phone",  image="ip-ui-blur.png",     blurred=True,
         accent="#4d8dff", bg="#07090f", grad="1100px 1000px at 50% 6%, #16213c 0%, rgba(7,9,15,0) 70%"),
    dict(key="play",  device="phone", bezel="phone",  image="ip-play-blur.png",   blurred=True,
         accent="#ffb02e", bg="#121722", grad="1200px 1000px at 50% 6%, #223055 0%, rgba(18,23,34,0) 72%"),
    dict(key="cloud", device="phone", bezel="phone",  image="ip-cloud.png",       blurred=False,
         accent="#4d8dff", bg="#07090f", grad="1100px 1000px at 50% 6%, #16213c 0%, rgba(7,9,15,0) 70%"),
    dict(key="enh",   device="phone", bezel="phone",  image="ip-enh.png",         blurred=False,
         accent="#ffb02e", bg="#121722", grad="1200px 1000px at 50% 6%, #223055 0%, rgba(18,23,34,0) 72%"),
    dict(key="ui",    device="ipad",  bezel="ipad",   image="ipad-ui-blur.png",   blurred=True,
         accent="#4d8dff", bg="#07090f", grad="1500px 1400px at 10% 50%, #16213c 0%, rgba(7,9,15,0) 70%"),
    dict(key="play",  device="ipad",  bezel="ipad",   image="ipad-play-blur.png", blurred=True,
         accent="#ffb02e", bg="#121722", grad="1600px 1500px at 10% 50%, #223055 0%, rgba(18,23,34,0) 72%"),
    dict(key="cloud", device="ipad",  bezel="ipad11", image="ipad-cloud.png",     blurred=False,
         accent="#4d8dff", bg="#07090f", grad="1500px 1400px at 10% 50%, #16213c 0%, rgba(7,9,15,0) 70%"),
    dict(key="enh",   device="ipad",  bezel="ipad11", image="ipad-enh-blur.png",  blurred=True,
         accent="#ffb02e", bg="#121722", grad="1600px 1500px at 10% 50%, #223055 0%, rgba(18,23,34,0) 72%"),
]

# The Lite app shows ads, so the games screen is captured from it rather than
# shared. Only that artboard differs; the rest are the same in both apps. The
# phone capture has no hero cover art to blur, so it carries no footnote.
VARIANTS = {
    "YabaSnashiro": {},
    "YabaSnashiro-Lite": {
        ("ui", "phone"): dict(image="ip-ui-lite.png", blurred=False),
        ("ui", "ipad"): dict(image="ipad-ui-lite-blur.png", bezel="ipad11"),
    },
}

# The store's own numbering. The prefix decides the order in App Store Connect.
ORDER = {("ui", "phone"): 1, ("play", "phone"): 2, ("cloud", "phone"): 3, ("enh", "phone"): 4,
         ("ui", "ipad"): 1, ("play", "ipad"): 2, ("cloud", "ipad"): 3, ("enh", "ipad"): 4}

DEVICE = {
    # Store size, then the bezel and the screen window inside it. The cloud and
    # enhancement iPad frames use the 11-inch bezel, as the canvas does.
    "phone": dict(w=1320, h=2868, bezel="bezel-iphone.png",
                  frame=(980, 2004), screen=(52.3, 50.1, 875.1, 1903.4)),
    "ipad": dict(w=2752, h=2064, bezel="bezel-ipad.png",
                 frame=(1552, 1190), screen=(64.2, 61.1, 1423.7, 1067.8)),
    "ipad11": dict(w=2752, h=2064, bezel="bezel-ipad11.png",
                   frame=(1376, 980), screen=(57.3, 55.2, 1261.3, 869.4)),
}


def esc(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def pills(scale):
    """The Action Replay / RetroAchievements chips. Brand names, never translated."""
    size = 26 if scale == "phone" else 30
    pad = "14px 26px" if scale == "phone" else "16px 30px"
    pad2 = "10px 26px" if scale == "phone" else "12px 30px"
    gap = 18 if scale == "phone" else 20
    logo = 34 if scale == "phone" else 40
    return f"""
            <div style="display:flex;gap:{gap}px;flex-wrap:wrap">
              <div style="font-family:'IBM Plex Mono',monospace;font-size:{size}px;letter-spacing:0.12em;color:#dfe6f5;border:2px solid #37405a;border-radius:999px;padding:{pad}">ACTION REPLAY</div>
              <div style="display:flex;align-items:center;gap:{gap - 4}px;border:2px solid #37405a;border-radius:999px;padding:{pad2}"><img src="assets/ra-logo.webp" alt="" style="height:{logo}px;width:auto;display:block"><span style="font-family:'IBM Plex Mono',monospace;font-size:{size}px;letter-spacing:0.12em;color:#dfe6f5">RETROACHIEVEMENTS</span></div>
            </div>"""


def device_block(spec, image):
    left, top, sw, sh = spec["screen"]
    fw, fh = spec["frame"]
    return f"""
          <div style="position:relative;width:{fw}px;height:{fh}px;flex:none">
            <div style="position:absolute;left:{left}px;top:{top}px;width:{sw}px;height:{sh}px;overflow:hidden;background:#000">
              <img src="assets/{image}" alt="" style="width:100%;height:100%;object-fit:contain;display:block">
            </div>
            <img src="assets/{spec['bezel']}" alt="" style="position:absolute;left:0;top:0;width:100%;height:100%;display:block">
          </div>"""


def page(locale, copy, shot):
    key, device = shot["key"], shot["device"]
    accent, bg, grad = shot["accent"], shot["bg"], shot["grad"]
    image, blurred = shot["image"], shot["blurred"]
    text = copy["shots"][key]
    font = copy["font"]
    spec = DEVICE[shot["bezel"]]
    footnote = ""
    if blurred:
        pos = ("left:90px;bottom:44px;font-size:26px" if device == "phone"
               else "left:120px;bottom:52px;font-size:30px")
        footnote = (f'<div style="position:absolute;{pos};font-family:\'IBM Plex Sans\',sans-serif;'
                    f'color:#6f7b91;letter-spacing:0.02em">{esc(copy["footnote"])}</div>')
    extra = pills(device) if key == "enh" else ""

    if device == "phone":
        body = f"""
        <div style="display:flex;flex-direction:column;gap:28px;position:relative">
          <div style="font-family:'IBM Plex Mono',monospace;font-size:28px;letter-spacing:0.3em;color:{accent}">{esc(text['eyebrow'])}</div>
          <div style="font-size:88px;line-height:0.96;font-weight:900;letter-spacing:-0.02em;text-wrap:pretty">{esc(text['title'])}</div>
          <div style="font-family:'IBM Plex Sans',sans-serif;font-size:34px;line-height:1.4;color:#a8b1c4;text-wrap:pretty">{esc(text['body'])}</div>{extra}
        </div>
        <div style="align-self:center">{device_block(spec, image)}</div>"""
        layout = ("padding:120px 90px;display:flex;flex-direction:column;gap:70px")
    else:
        body = f"""
        <div style="width:820px;display:flex;flex-direction:column;gap:34px;position:relative">
          <div style="font-family:'IBM Plex Mono',monospace;font-size:32px;letter-spacing:0.3em;color:{accent}">{esc(text['eyebrow'])}</div>
          <div style="font-size:118px;line-height:0.95;font-weight:900;letter-spacing:-0.02em;text-wrap:pretty">{esc(text['title'])}</div>
          <div style="font-family:'IBM Plex Sans',sans-serif;font-size:44px;line-height:1.35;color:#a8b1c4;text-wrap:pretty">{esc(text['body'])}</div>{extra}
        </div>
        {device_block(spec, image)}"""
        layout = "padding:0 120px;display:flex;align-items:center;gap:70px"

    return f"""<!DOCTYPE html>
<html lang="{locale}">
<head>
<meta charset="utf-8">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="{FONTS}" rel="stylesheet">
<style>
  html,body {{ margin:0; padding:0; background:{bg}; }}
  #board {{ width:{spec['w']}px; height:{spec['h']}px; box-sizing:border-box; background:{bg};
            position:relative; overflow:hidden; color:#fff; font-family:{font}; {layout} }}
</style>
</head>
<body>
<div id="board">
  <div style="position:absolute;inset:0;background:radial-gradient({grad})"></div>
  {footnote}
  {body}
</div>
</body>
</html>
"""


def render(html_path, png_path, width, height):
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
         "--force-device-scale-factor=1", "--default-background-color=00000000",
         f"--window-size={width},{height}", "--virtual-time-budget=8000",
         f"--screenshot={png_path}", f"file://{html_path}"],
        check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--locale", action="append",
                        help="only this locale (repeatable); default is every locale")
    parser.add_argument("--only-html", action="store_true",
                        help="write the pages but skip the screenshots")
    parser.add_argument("--variant", choices=sorted(VARIANTS), default="YabaSnashiro",
                        help="which app's set to build; the Lite one shows ads")
    args = parser.parse_args()

    with open(os.path.join(HERE, "strings.json"), encoding="utf-8") as handle:
        strings = json.load(handle)
    locales = args.locale or STORE_LOCALES

    os.makedirs(WORK, exist_ok=True)
    work_assets = os.path.join(WORK, "assets")
    if os.path.islink(work_assets) or os.path.exists(work_assets):
        if not os.path.islink(work_assets):
            shutil.rmtree(work_assets)
        else:
            os.unlink(work_assets)
    os.symlink(ASSETS, work_assets)

    overrides = VARIANTS[args.variant]
    root = os.path.join(OUT, args.variant)

    for locale in locales:
        copy = strings[locale]
        out_dir = os.path.join(root, locale)
        os.makedirs(out_dir, exist_ok=True)
        for base in SHOTS:
            shot = dict(base, **overrides.get((base["key"], base["device"]), {}))
            key, device = shot["key"], shot["device"]
            spec = DEVICE[shot["bezel"]]
            stem = f"{args.variant}-{locale}-{device}-{ORDER[(key, device)]:02d}{key}"
            html_path = os.path.join(WORK, stem + ".html")
            with open(html_path, "w", encoding="utf-8") as handle:
                handle.write(page(locale, copy, shot))
            if args.only_html:
                continue
            name = ("iPhone 17 Pro Max" if device == "phone" else "iPad Pro 13-inch (M4)")
            png_path = os.path.join(out_dir, f"{name}-{ORDER[(key, device)]:02d}{key.capitalize()}.png")
            render(html_path, png_path, spec["w"], spec["h"])
            print(f"  {locale:8s} {os.path.basename(png_path)}")

    if not args.only_html:
        print(f"\nwrote {root}")


if __name__ == "__main__":
    sys.exit(main())
