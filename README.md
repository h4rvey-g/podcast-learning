# Learn · Podcast Learning

A native **iOS 18+ SwiftUI app** for learning English from podcasts and transcripts. The UI follows [`designs/podcast-learning.fig`](designs/podcast-learning.fig): inset rounded cards, purple actions, New York transcript typography, source-specific highlights, and system light/dark appearances.

The backend runs **on the device** in Swift, as specified in [`docs/PLAN.md`](docs/PLAN.md). There is no server, account system, or backend deployment.

## Run

1. Open **`PodcastLearning.xcodeproj`** with **Xcode 26+** (Swift 6.2+; built here with Xcode 27.2).
2. Change the identifiers in **`Config.xcconfig`** to your registered bundle ID and App Group. Select your signing team for **both** `PodcastLearning` and `ShareExtension`. App Groups require appropriate developer-account provisioning.
3. Select the **PodcastLearning** scheme and an iPhone or installed iOS simulator. Run.
4. Tap **+** to paste English text, import a UTF-8 TXT/SRT/VTT file, or import an Apple Podcasts **episode** link (`?i=…`).
5. Optional: Settings → **Provider** to enter the hostname/base path and enable AI, **Model** to choose a model, and **API Key** → **Save API Key** → back to **Test Connection**. The defaults are `api.openai.com`, `/v1`, `gpt-4.1`. Unsaved key edits are not used by the connection test.

Nothing is seeded into your library. Offline text imports, CEFR marking, manual word selection, TTS, and dictation work without an AI key. Translation requires Apple's English/Chinese language packs; use the Translate action in a word or sentence sheet to install them.

### Learning flow

- **Library:** search imported transcripts and see practice/analysis status. Podcast-link import previews the episode, transcript count, audio lookup, and target level before saving.
- **Reader:** tap any word for its lemma/meaning; add or remove it from dictation, or jump to it in Items. Long-press a sentence to translate or ask AI to explain it. Blue solid underlines = list, orange wavy underlines with `*` = AI, teal dotted underlines with `+` = manual; yellow backgrounds = key sentences. Optional AI word details include IPA pronunciation; offline pronunciation audio remains available without AI.
- **Items:** source chips show counts. Filter by source or CEFR level, swipe to remove, restore removed words, and long-press an item to change its example sentence. Rows show the example and current review box.
- **Dictation:** tap blanks and type directly in the paragraph, with no separate answer fields. On the second attempt, the same blank becomes a connected word with underscores instead of cells or borders: supplied first/last/every-third-index letters stay fixed, typing fills the underscores and advances through missing letters, and backspace/paste work in place. The original wrong attempt is retained in answer history. Check grades the visible blanks together; a second miss reveals that answer. Overlapping word/phrase blanks become editable in successive checks within the same paragraph. Correct answers stay completed while you retry the others. Progress counts paragraphs; grades and global Leitner reviews remain per word and save immediately, even if you close the session. Replay uses the full paragraph audio or paragraph TTS. For downloaded, timed audio, tap or drag the smooth waveform to preview a position; release starts playback there within the current paragraph. Blanks have no visible number labels. Answers show incorrect attempt history and pronunciation audio. The completion screen shows elapsed time and can start a new round containing only missed words.
- **Review:** boxes 1–5 schedule 1/2/4/8/16-day intervals. Box 5 is skipped unless “Include Mastered Words” is enabled in the reader's More menu.
- **Share extension:** Podcasts → Share → Learn → Save. Open Learn to process pending imports. A failed shared import stays queued for retry; the app never silently discards it.

### Audio and network behavior

Podcast imports call PodText directly, then resolve audio through iTunes lookup and RSS GUID/title matching. Downloaded audio stays in Application Support, excluded from backup; it can be deleted in Settings without deleting transcripts or review history. Missing audio on another device can be downloaded in the reader or its More menu. The reader shows byte-based download progress (indeterminate when the size is unknown) and an inline Retry Audio Download action on failure, including failed audio-link resolution. Interrupted downloads can be restarted from the reader after relaunch. Downloads and AI analysis do not block reading or text-to-speech practice. A missing transcript shows an error; paste/file import remains available.

AI uses the pinned **MacPaw/OpenAI** SDK and a single long-context analysis call per import. Strict JSON-schema output falls back to JSON-object mode only for response-format rejection. Responses are decoded and checked against real sentence/item IDs, verbatim text boundaries, duplicates, and previously removed words. Interrupted/failed analysis can be retried. AI is opt-in: enabling it sends transcript content to your selected provider and may incur usage charges. Keys are stored in device-only Keychain storage, never SwiftData or iCloud.

## Optional iCloud sync

Local storage is the default; no CloudKit provisioning is required to build it. To enable sync **before first use**:

1. Register the `CLOUD_CONTAINER_ID` from `Config.xcconfig` in your Apple developer account and associate it with the app's identifier.
2. In the app target, enable **iCloud → CloudKit** and **Background Modes → Remote notifications**. Use `PodcastLearning/Cloud.entitlements` as `CODE_SIGN_ENTITLEMENTS` (or add the equivalent CloudKit entries to the default entitlements). Keep the App Group entitlement on both targets.
3. Set `ENABLE_CLOUD_SYNC = YES` in `Config.xcconfig`. Sign into iCloud on both devices and run the signed app.

Models use optional relationships/defaulted fields, no unique constraints, and duplicate word-memory keys are merged by most recent review. MP3 files do not sync. CloudKit provisioning, cross-device synchronization, and migration of an existing local library must be verified on your devices; do not toggle storage modes on valuable data without a backup. A store-open failure displays an error and never resets your library.

## Build and test

```sh
# Core unit/integration tests on macOS; no simulator, key, or network required
swift test
node scripts/check-waveform.mjs  # render the real SwiftUI waveform on macOS

# App + share extension, both simulator architectures; no signing required
xcodebuild -project PodcastLearning.xcodeproj \
  -scheme PodcastLearning -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

# Rebuild vocabulary data from the checked-in source lists
uv run --with openpyxl scripts/build_wordlist.py

# Regenerate the dependency-free Xcode project after adding/removing Swift files
python3 scripts/generate_project.py
```

The project generator owns `project.pbxproj` and the shared scheme. It preserves `Config.xcconfig`, source files, plists, and entitlements; reapply any target-setting edits after regeneration. Package revisions are pinned in the project and `Package.resolved`.

Tests cover answer normalization, hint/attempt states, Leitner transitions and queues, SwiftData persistence/cascade deletion, duplicate memories, subtitle parsing, CEFR lookup/lemmatization, names and thresholds, PodText/iTunes/RSS fixtures, HTTP failures, shared payloads, and AI response/schema validation. No live API calls run in tests.

### Device verification checklist

- Import a podcast with audio and replay a paragraph; check pause, 15-second skips, speed, tap/drag paragraph seeking, headphones disconnect, and interruptions.
- Install the en/zh-Hans translation packs and translate both a word and sentence.
- Test share-extension URL/text/file import with signed App Groups.
- Test a real long-context AI provider, including retry and schema fallback.
- Verify all 15 Figma states (including the Download & Paragraph States page) on small/large phones, in dark mode, Dynamic Type, and VoiceOver.
- If enabled, verify CloudKit sync on two signed devices and re-download missing audio.

## Layout

```
PodcastLearning/         SwiftUI screens, app orchestration, AI, Keychain, audio
ShareExtension/          Share-sheet UI and atomic App Group queue
Sources/PodcastCore/     SwiftData models, imports, vocabulary, dictation, review
Tests/PodcastCoreTests/  Swift Testing tests and trimmed network fixtures
resources/              Original lists and generated bundled wordlist.json
scripts/                Vocabulary preprocessing and Xcode project generation
designs/                Authoritative Figma file and exported references
```

## Vocabulary credits

- **CEFR-J Wordlist Version 1.6** — compiled by Yukio Tono, Tokyo University of Foreign Studies, Tono Lab. [Project and source information](https://www.cefr-j.org/).
- **Octanove Vocabulary Profile C1/C2 Version 1.0** — [Octanove wordlists](https://github.com/openlanguageprofiles/olp-en-cefrj), [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); retain the upstream license and attribution when redistributing derived data. See [`resources/ATTRIBUTION.md`](resources/ATTRIBUTION.md).

`Sources/PodcastCore/Resources/wordlist.json` is a symlink to the canonical generated `resources/wordlist.json`; SwiftPM copies the resolved file into the app bundle.

The bundled derived list merges slash-separated spellings, normalizes POS (including `vern` → `verb`), lowercases lookup keys, and keeps the lowest level per headword/POS. The supplied files produce **8,860 unique lowercase headwords / 9,946 headword–POS entries** across all six CEFR levels. The plan's >9,000 self-check is applied to entries, not unique headwords.

Transcripts and episode audio remain the property of their publishers. This project is intended for personal study.
