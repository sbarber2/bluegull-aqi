#!/usr/bin/env python3
"""Regenerate mac-app/branding/dmg-background.png.

Run this after changing app-package's DMG_WINDOW_W/H, DMG_ICON_X/Y,
DMG_APPLINK_X/Y, or DMG_UNINSTALL_X/Y in the root Makefile -- the arrow
and text positions here are hand-tuned to those exact numbers. Needs
Pillow: `pip install pillow` (not part of this repo's normal Python
deps, since this only runs when someone touches the branding).

Layout notes (found by actually building a DMG with create-dmg and
screenshotting the real Finder window, not by assuming):

- The arrow must leave an even gap to each icon's bounding box (icon
  center +/- icon-size/2), or the arrowhead point overlaps the
  Applications icon -- this is what shipped originally (bluegull-aqi-b3r)
  and Steve caught visually.
- A Finder icon-view window's *visible* content height comes out
  noticeably shorter than the --window-size height passed to create-dmg
  (measured ~340pt of usable content for a requested 400pt window, i.e.
  roughly 60pt of title bar + unexplained overhead eaten off the bottom,
  confirmed empirically rather than derived from any documented Finder
  behavior). Anything placed too close to the bottom of the canvas gets
  silently clipped. Keep bottom text well clear of the requested window
  height, below the icon name labels Finder draws itself.
"""

from PIL import Image, ImageDraw, ImageFont

SCALE = 4  # supersample for anti-aliasing, then downsample
W, H = 660, 620  # must match Makefile's DMG_WINDOW_W/H

BG = (234, 244, 252)
NAVY = (20, 40, 70)
ARROW_BLUE = (112, 181, 236)

FONT_PATH = "/System/Library/Fonts/HelveticaNeue.ttc"
TITLE_FONT = ImageFont.truetype(FONT_PATH, 24 * SCALE, index=1)  # Bold
BODY_FONT = ImageFont.truetype(FONT_PATH, 20 * SCALE, index=0)   # Regular

img = Image.new("RGB", (W * SCALE, H * SCALE), BG)
draw = ImageDraw.Draw(img)


def center_text(text, font, cy, color):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (W * SCALE - tw) / 2 - bbox[0]
    y = cy * SCALE - th / 2 - bbox[1]
    draw.text((x, y), text, font=font, fill=color)


center_text("BlueGull AQI", TITLE_FONT, 44.5, NAVY)

# Arrow -- must match Makefile's DMG_ICON_X/Y (180,170) and
# DMG_APPLINK_X/Y (480,170) with DMG_ICON_SIZE 128: left icon right edge
# = 180+64 = 244, right icon left edge = 480-64 = 416. A 16pt gap on each
# side keeps the arrowhead clear of both icons symmetrically.
LEFT_ICON_RIGHT_EDGE = 244
RIGHT_ICON_LEFT_EDGE = 416
GAP = 16
x_start = LEFT_ICON_RIGHT_EDGE + GAP
x_tip = RIGHT_ICON_LEFT_EDGE - GAP
head_len = (x_tip - x_start) * 0.30
x_head_start = x_tip - head_len
y_c = 170
shaft_half = 5
head_half = 25

pts = [
    (x_start, y_c - shaft_half),
    (x_head_start, y_c - shaft_half),
    (x_head_start, y_c - head_half),
    (x_tip, y_c),
    (x_head_start, y_c + head_half),
    (x_head_start, y_c + shaft_half),
    (x_start, y_c + shaft_half),
]
draw.polygon([(x * SCALE, y * SCALE) for x, y in pts], fill=ARROW_BLUE)

# Bottom instruction text -- see the clipping note in the module
# docstring for why this sits at y=302 rather than nearer the bottom.
center_text("Drag to Applications to install", BODY_FONT, 302, NAVY)

# Utility scripts row (bluegull-aqi-8iz, kill-all added after): well
# below the install row/caption above (302), matching DMG_UTILITY_ROW_Y
# (490) with room on both sides for the icons (DMG_ICON_SIZE 128, so
# +/-64) plus Finder's own filename labels under them. One caption for
# both, not one each -- the two icons sit at the SAME X positions as the
# app/Applications-link pair above (180/480), so labeling them
# individually here would either sit awkwardly off-center from each icon
# or require repeating the arrow's own layout math for a second row;
# Finder's own filename label under each icon already says which is
# which.
center_text("Troubleshooting: uninstall, or force-quit if something's stuck", BODY_FONT, 400, NAVY)

img = img.resize((W, H), Image.LANCZOS)
out_path = __file__.rsplit("/", 1)[0] + "/dmg-background.png"
img.save(out_path)
print(f"wrote {out_path}")
