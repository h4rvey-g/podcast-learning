# Learn · Podcast Learning

A native **iOS 18+ SwiftUI app** for learning English from podcasts and transcripts. The UI follows [`designs/podcast-learning.fig`](designs/podcast-learning.fig): inset rounded cards, purple actions, New York transcript typography, source-specific highlights, and system light/dark appearances.

The backend runs **on the device** in Swift, as specified in [`docs/PLAN.md`](docs/PLAN.md). There is no server, account system, or backend deployment.

## Run

1. Open **`PodcastLearning.xcodeproj`** with **Xcode 26+** (Swift 6.2+; built here with Xcode 27.2).
2. Change the identifiers in **`Config.xcconfig`** to your registered bundle ID and App Group. Select your signing team for **both** `PodcastLearning` and `ShareExtension`. App Groups require appropriate developer-account provisioning.
3. Select the **PodcastLearning** scheme and an iPhone or installed iOS simulator. Run.
4. Tap **+** to paste English text, import a UTF-8 TXT/SRT/VTT file, or import an Apple Podcasts **episode** link (`?i=…`).
5. Optional: Settings → enter provider hostname, base path, model, and API key → **Save API Key** → **Test Connection** → enable AI analysis. The default provider is `api.openai.com`, `/v1`, `gpt-4.1`. Unsaved key edits are not used by the connection test.

Nothing is seeded into your library. Offline text imports, CEFR marking, manual word selection, TTS, and dictation work without an AI key. Translation requires Apple's English/Chinese language packs; use the Translate action in a word or sentence sheet to install them.

### Learning flow

- **Library:** search imported transcripts and see practice/analysis status.
- **Reader:** tap any word for its lemma/meaning; add or remove it from dictation. Long-press a sentence to translate or ask AI to explain it. Blue solid underlines = list, orange dashed = AI, teal dotted = manual; yellow backgrounds = key sentences.
- **Items:** filter by source or CEFR level, remove/restore words, and long-press an item to change its example sentence.
- **Dictation:** type the missing surface word/phrase, with a fixed-length blank. First miss reveals first/last/every-third-index letters; second miss reveals the answer. Replay uses the paragraph audio or sentence TTS. Each completed answer immediately saves a global Leitner review; closing a session keeps completed answers.
- **Review:** boxes 1–5 schedule 1/2/4/8/16-day intervals. Box 5 is skipped unless “Include Mastered Words” is enabled in the reader's More menu.
- **Share extension:** Podcasts → Share → Learn → Save. Open Learn to process pending imports. A failed shared import stays queued for retry; the app never silently discards it.

### Audio and network behavior

Podcast imports call PodText directly, then resolve audio through iTunes lookup and RSS GUID/title matching. Downloaded audio stays in Application Support, excluded from backup; it can be deleted in Settings without deleting transcripts or review history. Missing audio on another device can be downloaded from the reader's More menu. Downloads and AI analysis do not block reading. A missing transcript shows an error; paste/file import remains available.

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

- Import a podcast with audio and replay a paragraph; check pause, 15-second skips, speed, headphones disconnect, and interruptions.
- Install the en/zh-Hans translation packs and translate both a word and sentence.
- Test share-extension URL/text/file import with signed App Groups.
- Test a real long-context AI provider, including retry and schema fallback.
- Verify all 11 Figma states on small/large phones, in dark mode, Dynamic Type, and VoiceOver.
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
