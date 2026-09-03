#!/usr/bin/env python3
"""Renders the WRACKBOX MK1 Instagram story series in the Sound Matters look.

The look is not invented here. Every value below is the same one the app
draws with — palette from `Core/Brand/Brand.swift`, faces from
`Core/Brand/Typography.swift`, the softened and dimmed ground and the card
furniture from `Core/Services/StillExporter.swift` and
`Core/Services/CardRenderer.swift`. This script only lays the story copy into
that furniture, because the copy is a one-off and does not belong in the app.

It writes 1080x1920 PNGs by driving headless Chromium over one generated HTML
page per story, which is what makes it runnable away from macOS; the app
itself stays the only renderer that ships.
"""

from __future__ import annotations

import base64
import mimetypes
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
FONTS = REPO / "Sources/ABCutter/Resources/Schriften"
SOURCE = HERE / "source"
PHOTOS = HERE / "photos"
OUT = HERE / "out"
WORK = HERE / ".build"

# MARK: - The family (Brand.swift)

KNOCHEN = "#EFE6D2"
OCKER = "#D9962B"
VERDIGRIS = "#2F8F7A"
TINTE = "#101014"

# MARK: - Measures

W, H = 1080, 1920
SIDE = round(W * 0.055)              # FrameRenderer.sideMarginFraction
SAFE_TOP = round(H * 0.10)           # ExportSettings.chromeSafeTop
SAFE_BOTTOM = round(H * 0.06)        # ExportSettings.chromeSafeBottom
RULE = max(2, round(H * 0.0016))     # Brand.ruleFraction
STRIP = round(H * 0.030)             # FrameRenderer.stripFraction
FOOT_SIZE = max(13, round(H * 0.019))  # CardRenderer.drawFoot
GRAIN = 0.26                         # the website's ::before
DIM = 0.38                           # StillSettings.dimStrength, opened up for type
BLUR = 6                             # StillSettings.blurStrength, far under the app's 45:
#                                      a story has to stay recognisable as the rack


def blur_px(strength: float) -> float:
    """StillExporter.soften: radius = height * 0.0009 * strength."""
    return round(H * 0.0009 * strength, 1)


# MARK: - The series

# Two voices, not five. The lead face carries the sentence, the mono carries
# everything small — the strip, the list, the foot. There is one size per
# story, and the accent is a colour, never a second size: as soon as a slide
# holds three sizes it stops reading as one piece of print.
#
# The size is set by the longest line, since a line that wraps breaks the
# rhythm of the block: roughly 962 / (characters * 0.667) at this margin.

STORIES = [
    {
        "n": 1,
        "photo": "rack-front-stage.jpg",
        "crop": (0.50, 0.50),
        "blocks": [
            {"kind": "fett", "size": 62, "lines": [
                "hey event people!",
                "i built a recording rig",
                "for festivals.",
            ]},
            {"kind": "bar", "size": 78, "text": "wrackbox mk1"},
            {"kind": "note", "text": "here’s what it does →"},
        ],
    },
    {
        # The one slide that is only the machine: sharp, no scrim, no type.
        # After the hook the viewer wants to see the thing before being told
        # anything more about it.
        "n": 2,
        "photo": "rack-front-stage.jpg",
        "crop": (0.55, 0.54),
        "zoom": 1.28,
        "plain": True,
        "blocks": [],
    },
    {
        "n": 3,
        "photo": "bench-build.jpg",
        "crop": (0.50, 0.50),
        "blur": 9,
        "dim": 0.46,
        "blocks": [
            {"kind": "fett", "size": 48, "lines": [
                "recording a whole festival",
                "is a babysitting job.",
            ]},
            {"kind": "fett", "size": 48, "lines": [
                "someone checks the laptop",
                "between sets.",
                "someone swaps the card at 3am.",
                "someone hopes the power holds.",
            ]},
            {"kind": "fett", "size": 48, "accent": True, "lines": [
                "and usually that someone",
                "is you.",
            ]},
        ],
    },
    {
        "n": 4,
        "photo": "rack-closed-back.jpg",
        "crop": (0.52, 0.50),
        "blocks": [
            {"kind": "fett", "size": 48, "lines": [
                "so i built a box",
                "that doesn’t need you.",
            ]},
            {"kind": "fett", "size": 48, "accent": True, "lines": [
                "plug in power. plug in audio.",
                "walk away.",
            ]},
            {"kind": "fett", "size": 48, "lines": [
                "it records the entire weekend",
                "on its own.",
            ]},
        ],
    },
    {
        "n": 5,
        "photo": "rack-open-workshop.jpg",
        "crop": (0.52, 0.50),
        "blocks": [
            {"kind": "fett", "size": 40, "lines": [
                "the timetable goes in once.",
            ]},
            {"kind": "fett", "size": 40, "accent": True, "lines": [
                "all three days — every slot,",
                "every break.",
            ]},
            {"kind": "fett", "size": 40, "lines": [
                "the box follows the plan by itself.",
                "records what should be recorded,",
                "stays quiet when nothing’s on.",
            ]},
        ],
    },
    {
        "n": 6,
        "photo": "rack-front-stage.jpg",
        "crop": (0.34, 0.56),
        "zoom": 1.9,
        "blur": 9,
        "dim": 0.48,
        "blocks": [
            {"kind": "list", "size": 34, "items": [
                "15 days of recording on two cards",
                "both cards run in parallel — one dies, the set lives",
                "power cut? it reboots and picks the recording back up",
                "files split automatically, no 300GB monsters",
            ]},
        ],
    },
    {
        "n": 7,
        "photo": "rack-back-stage.jpg",
        "crop": (0.45, 0.50),
        "blur": 9,
        "dim": 0.48,
        "blocks": [
            {"kind": "list", "size": 34, "items": [
                "XLR + RCA out → livestream, radio, broadcast",
                "remote status and control over LTE, from anywhere",
            ]},
            {"kind": "fett", "size": 52, "lines": [
                "one timetable. one weekend.",
                "no babysitter.",
            ]},
            {"kind": "bar", "size": 72, "text": "wrackbox mk1"},
            {"kind": "note", "text": "DM me if you run stages."},
        ],
    },
]

# The end card, in the sticker's own arrangement (CardRenderer.endCard).
END_CARD = {"top": "sound is what", "bar": "matters.", "address": "soundmatters.audio"}


# MARK: - Markup

def font_face(name: str, file: str) -> str:
    data = base64.b64encode((FONTS / file).read_bytes()).decode()
    return (
        f"@font-face{{font-family:'{name}';"
        f"src:url(data:font/ttf;base64,{data}) format('truetype');"
        "font-weight:normal;font-style:normal;font-display:block}"
    )


# Two of the three house faces. The didone is deliberately left out here: on
# a photograph at story size its hairlines break away, and a third voice is
# what made the first set read as five different posts.
FACES = "".join([
    font_face("Archivo Black", "ArchivoBlack-Regular.ttf"),
    font_face("Space Mono", "SpaceMono-Bold.ttf"),
])

# Grain: fractal noise over the finished picture, as in FrameRenderer.grain.
NOISE = (
    "data:image/svg+xml;utf8,"
    "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='240'>"
    "<filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' "
    "numOctaves='3' stitchTiles='stitch'/></filter>"
    "<rect width='240' height='240' filter='url(%23n)'/></svg>"
)

CSS = f"""
*{{margin:0;padding:0;box-sizing:border-box}}
{FACES}
html,body{{width:{W}px;height:{H}px;background:{TINTE};overflow:hidden}}
.canvas{{position:relative;width:{W}px;height:{H}px;overflow:hidden}}

/* Ground: the frame filled to the canvas, softened and dimmed so type can
   sit on it — StillExporter.titleCard. */
.ground{{position:absolute;inset:-70px;background-size:cover;background-position:center;
  background-repeat:no-repeat}}
.ground.sharp{{inset:0}}
.scrim{{position:absolute;inset:0}}
/* The website's ::after — a radial darkening that keeps type readable. */
.veil{{position:absolute;inset:0;background:radial-gradient(ellipse 70% 60% at 50% 46%,
  rgba(16,16,20,.10) 0%, rgba(16,16,20,.62) 100%)}}
/* The website's ::before. */
.grain{{position:absolute;inset:0;background-image:url("{NOISE}");
  mix-blend-mode:overlay;opacity:{GRAIN}}}

.plate{{position:absolute;left:0;right:0;top:{SAFE_TOP}px;bottom:{SAFE_BOTTOM}px;
  padding:0 {SIDE}px;display:flex;flex-direction:column}}

/* The two mono strips, with one hard rule facing the picture. */
.strip{{display:flex;justify-content:space-between;align-items:center;
  height:{STRIP}px;border-bottom:{RULE}px solid rgba(239,230,210,.3)}}
.strip span{{font-family:'Space Mono',monospace;font-size:26px;letter-spacing:.14em;
  text-transform:uppercase;color:rgba(239,230,210,.66)}}

.body{{flex:1;display:flex;flex-direction:column;justify-content:center;
  align-items:center;text-align:center;gap:46px;padding:60px 0}}

/* The lead: one size per story, bone, or ocker where a line carries the turn. */
.fett{{font-family:'Archivo Black','Arial Black',sans-serif;text-transform:uppercase;
  letter-spacing:-.045em;line-height:1.06;color:{KNOCHEN}}}
.fett.accent{{color:{OCKER}}}
/* The small type: the strip, the list, the note, the foot — nothing else. */
.note{{font-family:'Space Mono',monospace;text-transform:uppercase;letter-spacing:.14em;
  font-size:28px;line-height:1.5;color:rgba(239,230,210,.66)}}

/* The bar: a field in the accent with a hard contour in ink — CardRenderer.drawBar. */
.bar{{display:inline-block;font-family:'Archivo Black','Arial Black',sans-serif;
  text-transform:uppercase;letter-spacing:-.045em;color:{TINTE};background:{OCKER};
  border:6px solid {TINTE};border-radius:10px;padding:.13em .16em .19em}}

.list{{display:flex;flex-direction:column;gap:34px;text-align:left;width:100%}}
.item{{display:flex;gap:26px;align-items:flex-start;
  font-family:'Space Mono',monospace;text-transform:uppercase;letter-spacing:.10em;
  line-height:1.45;color:{KNOCHEN}}}
.tick{{flex:none;width:.62em;height:.62em;margin-top:.42em;background:{OCKER};
  border:3px solid {TINTE}}}

.foot{{border-top:{RULE}px solid rgba(239,230,210,.3);padding-top:34px;text-align:center}}
.foot .address{{font-family:'Space Mono',monospace;font-size:{FOOT_SIZE}px;
  letter-spacing:.18em;text-transform:uppercase;color:{OCKER}}}

/* The end card: ink ground, the wordmark in two lines. */
.end .body{{gap:0}}
.end .top{{white-space:nowrap;font-family:'Archivo Black','Arial Black',sans-serif;text-transform:uppercase;
  letter-spacing:-.045em;font-size:104px;color:{KNOCHEN};line-height:1}}
.end .bar{{font-size:126px;margin-top:26px}}
"""


def block_html(block: dict) -> str:
    kind = block["kind"]
    if kind == "fett":
        accent = " accent" if block.get("accent") else ""
        lines = "<br>".join(block["lines"])
        return f'<div class="fett{accent}" style="font-size:{block["size"]}px">{lines}</div>'
    if kind == "note":
        return f'<div class="note">{block["text"]}</div>'
    if kind == "bar":
        return f'<div><span class="bar" style="font-size:{block["size"]}px">{block["text"]}</span></div>'
    if kind == "list":
        items = "".join(
            f'<div class="item" style="font-size:{block["size"]}px">'
            f'<span class="tick"></span><span>{text}</span></div>'
            for text in block["items"]
        )
        return f'<div class="list">{items}</div>'
    raise ValueError(kind)


def data_uri(path: pathlib.Path) -> str:
    kind = mimetypes.guess_type(path.name)[0] or "image/jpeg"
    return f"data:{kind};base64," + base64.b64encode(path.read_bytes()).decode()


def story_html(story: dict, count: int) -> str:
    photo = data_uri(PHOTOS / f"story-{story['n']:02d}.jpg")
    blur = blur_px(story.get("blur", BLUR))
    dim = story.get("dim", DIM)
    if story.get("plain"):
        # Nothing is softened, dimmed or written over: only the grain, so the
        # slide still belongs to the series.
        return f"""<!doctype html><meta charset="utf-8"><style>{CSS}</style>
<div class="canvas">
  <div class="ground sharp" style="background-image:url('{photo}')"></div>
  <div class="grain"></div>
</div>"""

    blocks = "".join(block_html(b) for b in story["blocks"])
    return f"""<!doctype html><meta charset="utf-8"><style>{CSS}</style>
<div class="canvas">
  <div class="ground" style="background-image:url('{photo}');filter:blur({blur}px)"></div>
  <div class="scrim" style="background:rgba(0,0,0,{dim})"></div>
  <div class="veil"></div><div class="grain"></div>
  <div class="plate">
    <div class="strip"><span>wrackbox mk1</span><span>{story['n']:02d} / {count:02d}</span></div>
    <div class="body">{blocks}</div>
  </div>
</div>"""


def end_html(count: int) -> str:
    return f"""<!doctype html><meta charset="utf-8"><style>{CSS}</style>
<div class="canvas end" style="background:{TINTE}">
  <div class="grain"></div>
  <div class="plate">
    <div class="strip"><span>wrackbox mk1</span><span>{count:02d} / {count:02d}</span></div>
    <div class="body">
      <div class="top">{END_CARD['top']}</div>
      <div><span class="bar">{END_CARD['bar']}</span></div>
    </div>
    <div class="foot"><div class="address">{END_CARD['address']}</div></div>
  </div>
</div>"""


# MARK: - The ground

def prepare_photos() -> None:
    """Crops each source photo to the canvas, the way `place(_:into:mode:)`
    fills a rect: scale to cover, then keep the part the pan asks for.

    The zoom is the part CSS cannot do here. A 3:4 photo is already wider than
    a 9:16 canvas, so covering it crops the sides and leaves no vertical slack
    at all — without scaling in first, the pan up and down does nothing.
    """
    from PIL import Image, ImageOps

    PHOTOS.mkdir(parents=True, exist_ok=True)
    for story in STORIES:
        image = ImageOps.exif_transpose(Image.open(SOURCE / story["photo"])).convert("RGB")
        width, height = image.size
        zoom = story.get("zoom", 1.0)
        box_width = min(width, height * W / H) / zoom
        box_height = box_width * H / W
        x, y = story["crop"]
        left = (width - box_width) * x
        top = (height - box_height) * y
        image.resize(
            (W, H), Image.LANCZOS,
            box=(left, top, left + box_width, top + box_height),
        ).save(PHOTOS / f"story-{story['n']:02d}.jpg", quality=90, optimize=True)


# MARK: - Rendering

def chromium() -> str:
    for pattern in ("/opt/pw-browsers/chromium-*/chrome-linux/chrome",
                    "/opt/pw-browsers/chromium/chrome-linux/chrome"):
        for candidate in sorted(pathlib.Path("/").glob(pattern.lstrip("/"))):
            return str(candidate)
    for name in ("chromium", "chromium-browser", "google-chrome"):
        found = shutil.which(name)
        if found:
            return found
    sys.exit("Kein Chromium gefunden.")


def shoot(browser: str, html: pathlib.Path, png: pathlib.Path) -> None:
    subprocess.run(
        [browser, "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
         "--force-device-scale-factor=1", f"--window-size={W},{H}",
         f"--screenshot={png}", html.as_uri()],
        check=True, capture_output=True,
    )


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    prepare_photos()
    browser = chromium()
    count = len(STORIES) + 1

    for story in STORIES:
        html = WORK / f"story-{story['n']:02d}.html"
        html.write_text(story_html(story, count), encoding="utf-8")
        png = OUT / f"wrackbox-story-{story['n']:02d}.png"
        shoot(browser, html, png)
        print(png.name)

    html = WORK / f"story-{count:02d}.html"
    html.write_text(end_html(count), encoding="utf-8")
    png = OUT / f"wrackbox-story-{count:02d}-endcard.png"
    shoot(browser, html, png)
    print(png.name)


if __name__ == "__main__":
    main()
