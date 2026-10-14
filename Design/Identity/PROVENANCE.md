# Clauto identity assets

These original vector assets were authored for Nathan Fennel's Clauto macOS app by
Codex on 2026-10-14. All shapes use explicitly drawn paths and pure geometry. No
SF Symbols, copied icon library, stock artwork, generated bitmap imagery, scanned
texture, private media, external service, or newly licensed font is used.

The design interprets the app's real mechanism—brief, local files, and conversation
produce a named cut that remains revisable—as an open cut bracket and a movable
citron strip. A clipped upper-right corner and diagonal splice define the emblem;
the supporting icons use a 24-unit grid, a 1.7-unit square stroke, and restrained
filled control shapes. The canvas is warm ivory, the rail is viridian, and the
primary foreground is deep ink. Terracotta is reserved for a signal, not decoration.

## Editable sources

- `geometry.json` records the authored paths and exact palette. It is the canonical
  source for regeneration.
- `emblem.svg` is the transparent viridian/citron mark for light compositions.
- `emblem-reversed.svg` is the transparent ivory/citron mark for dark compositions.
- `app-icon.svg` contains the complete clipped viridian tile and reversed mark on
  a transparent 1024 × 1024 canvas.
- `icons/*.svg` contains 21 standalone editable interface symbols. Each inherits
  `currentColor`; no linked resources or raster content is embedded.
- `identity-board.svg` is an editable overview of the palette and icon family.

SVG files remain directly editable. Edit `geometry.json` before regenerating to
preserve a change across SVGs and native paths.

## Native use

`Clauto Editor/Clauto Editor/Views/ClautoIcon.swift` is generated from the same
path source. It defines `ClautoIconName`, `ClautoIcon`, `ClautoIconShape`, and
`ClautoEmblem`. The view inherits the caller's foreground style:

```swift
ClautoIcon(.project, size: 18).foregroundStyle(inkColor)
ClautoEmblem(bracketColor: ivoryColor, stripColor: citronColor)
```

Icons are decorative and hidden from accessibility. The surrounding button or
label supplies its action name. `size` is the rendered square in points;
`strokeWidth` is measured on the 24-unit source grid, defaulting to 1.7. No
runtime SVG parser, asset lookup, or system symbol is needed by the app.

`Assets.xcassets/AppIcon.appiconset` has all ten macOS entries: 16, 32, 128, 256,
and 512 points at 1× and 2×. Their filenames include point size and scale.
Every raster derives from `app-icon.svg` through the renderer below. Transparency
around the authored tile is intentional.

## Font and rendering provenance

The preview boards use the existing repository font
`assets/fonts/WorkSans[wght].ttf` by the Work Sans Project Authors. Its existing
license is `assets/fonts/OFL-worksans.txt` (SIL Open Font License 1.1). The renderer
registers it for its own process; it does not install fonts on the machine.
Emblems, interface symbols, and app icons contain no lettering or font dependency.

`scripts/generate_identity.py` uses only the Python standard library to write the
SVG assets and native SwiftUI path file. `scripts/render_assets.swift` uses only
macOS CoreGraphics, CoreText, AppKit, and ImageIO to rasterize those SVG paths.
It handles the small SVG subset these sources use; it is not a general SVG engine.
It does not launch the app, inspect a user's screen, or interact with Final Cut.

From the repository root:

```sh
python3 Design/Identity/scripts/generate_identity.py
swift -module-cache-path /tmp/clauto-identity-module-cache Design/Identity/scripts/render_assets.swift
python3 Design/Identity/scripts/verify_assets.py
swiftc -typecheck -module-cache-path /tmp/clauto-identity-module-cache 'Clauto Editor/Clauto Editor/Views/ClautoIcon.swift'
```

The preview PNGs are synthetic asset renders:

- `previews/identity-board.png` shows every icon at 16, 20, 24, and 36 pixels.
- `previews/small-size-silhouette.png` shows the app icon at native 16, 20, 24, 32,
  48, and 64 pixels, then at 4× or 2× nearest-neighbor magnification.
- `previews/app-icon-1024.png` is a full-size transparent export.
- `previews/verification.json` records source/output hashes, PNG dimensions and
  alpha checks, and palette contrast measurements.

No source media or product screenshots appear in these previews.
