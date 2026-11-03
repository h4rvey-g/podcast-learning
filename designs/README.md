# Podcast Learning designs

- `podcast-learning.fig`: 22 iPhone states in light and dark appearances. The original 11 screens are on **Page 1**; **Download & Paragraph States** adds grouped dictation, grouped retry, downloading, and download-failed states. **Bilibili & Transcription** adds Bilibili import (16), media settings (17), Azure/OpenRouter speech setup (18), upload progress (19), and interrupted/retry recovery (20), AI settings with thinking effort (21), and the thinking-level picker (22).
- `png/`: exports made with SF Pro, New York and PingFang SC.

Dictation progress counts paragraphs. **Both attempts are edited directly in the paragraph**, never in separate answer fields below it. Blanks have no visible `[1]`/`[2]` labels. The first attempt uses an inline text input and insertion caret. On retry, the missed word becomes connected letters and underscores, with no cells, borders, backgrounds or extra letter spacing. Given first/last/every-third-index letters stay fixed; typing fills the underscores and advances to the next editable letter. Backspace and paste work within the same word. Each answer remains one accessible input, not tiny independent letter targets.

Blanks are checked together, with per-word grades and immediately saved reviews. Correct answers stay locked while the learner retries only the missed words. The paragraph scrolls above the native keyboard as needed; Check and Reveal remain reachable. Light/dark states 07–08 and 12–13 share this interaction.

The paragraph waveform (07–09, 12–13) is a seek control with a 44pt-high touch target. Tap or drag to preview a playback position; release starts downloaded audio at that point, clamped to the current paragraph's timestamps. Played fill and the playhead move continuously instead of changing one whole bar at a time. VoiceOver gets an adjustable slider, and interpolation respects Reduce Motion. Without timed downloaded audio, text-to-speech keeps its existing replay/progress behavior. Canvas comments record both input and seeking contracts.

Download progress uses actual received bytes, with indeterminate progress while resolving audio or when the response size is unknown. Failure offers an inline retry; text to speech, reading, and dictation remain available. Canvas comments record these behaviors.

Bilibili imports accept au/BV/av links, video parts, and b23.tv shares. Audio-only downloads/uploads are the default. Keep Bilibili Video optionally retains a local MP4 with sound; only the prepared audio is uploaded to Microsoft MAI-Transcribe-2. Transcription has independent consent, endpoint, model, and Keychain credentials. It supports direct Azure or OpenRouter’s microsoft/mai-transcribe-2. OpenRouter uploads use five-minute WAV parts below 25 MB, with completed-part checkpoints and correctly offset combined timestamps. Reader clips use validated word timestamps.

Text AI uses Swift AI SDK with Chat Completions or Responses routing. Thinking Level is a native navigation-link picker with Provider Default, None, Minimal, Low, Medium, High, Extra High, and Max. Provider Default preserves existing behavior. Supported levels vary; higher effort can increase latency and cost, and unsupported selections fail before sending rather than silently dropping the preference. Reasoning text is not surfaced or persisted.

Transfers wait for connectivity and retry temporary failures, honoring Retry-After. Download/upload progress reflects transferred bytes; recognition and result delivery use indeterminate progress. Keep the app open: these flows do not promise iOS background-session completion. Interrupted imports persist for manual retry after relaunch and reuse complete local checkpoints. A lost synchronous response can require another upload and provider charge; there is no retrievable result job ID. Canvas comments document the contract. Settings storage includes retained video and intermediate transfer files.

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
