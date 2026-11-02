# Podcast Learning designs

- `podcast-learning.fig`: 11 iPhone screens in light and dark appearances.
- `png/`: exports made with SF Pro, New York and PingFang SC.

## Regenerate

The manually edited `.fig` is the current source of truth. `generate.mjs` is the original scaffold; running it replaces manual changes. Reconcile those changes into the scaffold before regenerating. Exporting PNGs from the existing `.fig` preserves them.

```sh
node designs/check-fonts.mjs
node designs/generate.mjs       # replaces all generated screens and PNGs
node designs/generate.mjs 3,4   # replaces only screens 3 and 4, in both appearances
```

Requires macOS, Node.js, OpenPencil CLI 0.16 and ImageMagick (`magick`, for the regression test).
Install [Apple's SF Pro and New York design fonts](https://developer.apple.com/fonts/) in `~/Library/Fonts` (`SF-Pro.ttf` and `NewYork.ttf`). Restart OpenPencil after installing them so its font catalog refreshes. PingFang SC comes from the installed macOS font asset.

## Font-loading fix

The desktop app loads installed fonts. The 0.16 CLI doesn't configure a local-font host, so headless generation needs `load-local-fonts.mjs`. The generator preloads it automatically. It registers the actual local font files and selects the requested PingFang face from its collection, using the same approach as OpenPencil's desktop font loader.

It also starts the text-measurement engine **before the CLI reads the document**. The CLI recomputes auto-layout on read; without this ordering it uses estimated character widths. This made “Target Level” 44 pt high rather than 22 pt, until clicking the row in the editor triggered measurement with the real font. A successful font diagnostic or a correctly rendered PNG alone doesn't catch that saved-layout error.

For a standalone diagnostic or export, run from the project root:

```sh
NODE_OPTIONS="--import=file://$PWD/designs/load-local-fonts.mjs" \
  openpencil fonts designs/podcast-learning.fig --json

NODE_OPTIONS="--import=file://$PWD/designs/load-local-fonts.mjs" \
  openpencil export designs/podcast-learning.fig --node NODE_ID \
  --font-policy strict -o preview.png
```

The regression test checks all eight requested faces, strict export, and visible pixels in nine text samples, including Chinese, source markers and the dictation blank. It also checks row/segment alignment in a fresh CLI process and compares every text layer's geometry before and after saving/reopening the complete design. The generator uses `--font-policy strict` so unresolved fonts stop the export.

`*` and `+` provide source cues using supported glyphs. The decorative `✦` made OpenPencil suppress the entire text node. The dictation blank uses SF Pro so its underscores are visible.

The loader is local to this project; it doesn't patch the global CLI. Apple font binaries remain outside the project and are used for Apple-platform UI mockups under Apple's license.

Sources: [OpenPencil font diagnostics](https://openpencil.dev/programmable/cli/inspecting#font-diagnostics), [export font policies](https://openpencil.dev/programmable/cli/exporting#font-substitution-policy), [desktop collection-face loader](https://github.com/open-pencil/open-pencil/blob/master/desktop/src/fonts/sfnt.rs).
