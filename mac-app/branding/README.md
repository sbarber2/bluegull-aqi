# Branding assets

`AppIcon-1024.png` is the source-of-truth 1024x1024 app icon master --
full-bleed (no pre-existing corner rounding; macOS applies its own squircle
mask to whatever a `.appiconset` provides). Derived from the "rounded
square" concept in the branding asset zip Steve supplied (bluegull-aqi-b3r):
that source had actual white pixels filled into its corners rather than
transparency, which is the wrong shape for an AppIcon source (the OS masks
the icon itself; feeding it something already masked double-masks and
leaves artifacts). Fixed by flood-filling those corners with the interior
background blue (`srgb(112,181,236)`) to make it genuinely edge-to-edge.

To regenerate `mac-app/BluegullAQI/Assets.xcassets/AppIcon.appiconset/`
from this master (only needed if the artwork changes -- the checked-in
`.appiconset` is what Xcode actually builds from):

```bash
SRC=mac-app/branding/AppIcon-1024.png
DEST=mac-app/BluegullAQI/Assets.xcassets/AppIcon.appiconset
sips -z 16 16     "$SRC" --out "$DEST/icon_16x16.png"
sips -z 32 32     "$SRC" --out "$DEST/icon_16x16@2x.png"
sips -z 32 32     "$SRC" --out "$DEST/icon_32x32.png"
sips -z 64 64     "$SRC" --out "$DEST/icon_32x32@2x.png"
sips -z 128 128   "$SRC" --out "$DEST/icon_128x128.png"
sips -z 256 256   "$SRC" --out "$DEST/icon_128x128@2x.png"
sips -z 256 256   "$SRC" --out "$DEST/icon_256x256.png"
sips -z 512 512   "$SRC" --out "$DEST/icon_256x256@2x.png"
sips -z 512 512   "$SRC" --out "$DEST/icon_512x512.png"
cp "$SRC" "$DEST/icon_512x512@2x.png"
```

`make app-package` also derives a `.icns` volume icon for the DMG from this
same master at package time (not committed -- see that target's own
comment in the root `Makefile`).

`dmg-background.png` is the DMG Finder-window background (drag-to-Applications
arrow + instructions), sized to match `app-package`'s `create-dmg
--window-size`. Regenerate together if you resize the window.
