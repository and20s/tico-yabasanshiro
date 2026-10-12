# Store screenshots

The localized App Store marketing screenshots: a device frame, a headline and
a line of copy per feature, four per device family.

The layout comes from the Claude Design project "YabaSanshiro AppStore
プロモーション画像". `build.py` reproduces one artboard per page at its exact
store pixel size and shoots it with headless Chrome, so the wording can be
translated per locale without redrawing anything.

## Assets

`assets/` is not in git: the images are ~24 MB of exported PNGs. Export the
`assets/` folder of the design project into `tools/store_screenshots/assets`
before building. The build needs:

    bezel-iphone.png  bezel-ipad.png  bezel-ipad11.png
    ip-ui-blur.png    ip-play-blur.png  ip-cloud.png  ip-enh.png
    ipad-ui-blur.png  ipad-play-blur.png  ipad-cloud.png  ipad-enh-blur.png
    ra-logo.webp

## Build

    python3 tools/store_screenshots/build.py                 # every store locale
    python3 tools/store_screenshots/build.py --locale ja     # one locale

Output lands in `screenshots/marketing/YabaSnashiro/<locale>/`, named so the
order in App Store Connect matches the canvas.

The copy lives in `strings.json`, keyed by App Store locale code, which is what
fastlane deliver accepts as a directory name -- `ja`, not `ja-JP`; `es-MX`, not
`es`. It also carries Russian, which the Snapfile captures but the listing has
no localization for, so `build.py` renders it only when asked for by name.

Chrome loads Archivo and IBM Plex from Google Fonts at render time, so the
build needs a network connection. Japanese, Chinese and Russian fall back to
the system faces named in `strings.json`.

## Upload

    tools/upload_screenshots.sh "" ./screenshots/marketing/YabaSnashiro

This replaces the screenshots of every locale it finds, on the version being
prepared in App Store Connect.
