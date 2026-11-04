# PodLearn · Podcast Learning

A native **iOS 18+ SwiftUI app** for learning English from podcasts and transcripts. The UI follows [`designs/podcast-learning.fig`](designs/podcast-learning.fig): inset rounded cards, theme-colored actions (purple by default), New York transcript typography, source-specific highlights, and system light/dark appearances.

The backend runs **on the device** in Swift, as specified in [`docs/PLAN.md`](docs/PLAN.md). There is no server, account system, or backend deployment.

## Run

1. Open **`PodcastLearning.xcodeproj`** with **Xcode 26+** (Swift 6.2+; built here with Xcode 27.2).
2. Change the identifiers in **`Config.xcconfig`** to your registered bundle ID and App Group. Select your signing team for **both** `PodcastLearning` and `ShareExtension`. App Groups require appropriate developer-account provisioning.
3. Select the **PodcastLearning** scheme and an iPhone or installed iOS simulator. Run.
4. Tap **+**. Use **Link** for an Apple Podcasts **episode** (`?i=…`) or Bilibili audio/video URL. Use **Text** to paste English text or **Import File** for PDF, Word DOC/DOCX, or UTF-8 TXT/SRT/VTT files.
5. Optional: Settings → **Provider** to enable AI, choose an API, enter the full **Base URL**, and enter your key directly below it → **Save API Key**. Open **Model** to automatically fetch available models using the saved key, select one, or **Add Custom Model** by its exact ID. Custom IDs are saved locally; providers without a model-list endpoint can still use them. **Refresh Models** reloads the list. Then **Test Connection** sends a 32-token probe with provider-default thinking and a 15-second deadline; it checks selected-model access, not the configured thinking level or structured analysis support. Model listing also has a 15-second deadline. The defaults are `https://api.openai.com/v1`, `gpt-4.1`, OpenAI-Compatible Chat, and Provider Default thinking. Provider supports OpenAI-Compatible Chat, OpenAI Responses, Anthropic Messages, and Google Gemini. Use `https://api.anthropic.com/v1` for native Anthropic or `https://generativelanguage.googleapis.com/v1beta` for native Gemini, with a matching model and key. Existing hostname/base-path settings are preserved as a full Base URL. Thinking Level offers Provider Default, None, Minimal, Low, Medium, High, Extra High, and Max; support varies by model and higher levels can cost more or take longer. Unsaved key edits are not used by the connection test.

Nothing is seeded into your library. Offline text imports, CEFR marking, manual word selection, TTS, and dictation work without an AI key. Speaking rate defaults to **1.0×** (the system speech rate); existing saved rates are preserved. Translation requires Apple's English/Chinese language packs; use the Translate action in a word or sentence sheet to install them.

### Standalone installation with SideStore

Use **`build/PodcastLearning-SideStore.ipa`**, not `build/PodcastLearning-LiveContainer.ipa`. The LiveContainer package deliberately removes `PlugIns` and disables App Groups; installing that package through SideStore does not restore sharing.

The standalone package must retain `PlugIns/ShareExtension.appex` and the same nonempty App Group in both targets' Info plists and signing entitlements. SideStore re-signs the IPA; when prompted, choose **Keep App Extensions (Register App ID for Each Extension)**, not Remove. Update the existing app with the same bundle ID/signing account rather than uninstalling it to preserve its local library. The app and extension read the matching App Group from their installed provisioning profiles, with `ALTAppGroups` and the configured identifier as fallbacks. This supports SideStore versions that rename the group without writing `ALTAppGroups`; iOS still enforces the actual signed container entitlement.

After installation, open PodLearn once, then share an episode/video and look for **PodLearn** under **More** at the end of the share sheet's app-icon row. Tap **Save**, then reopen PodLearn to process the import. Actual SideStore provisioning and the end-to-end share flow still need verification on the phone.

### Learning flow

- **Appearance:** Settings → Appearance → **Accent Theme** offers Purple (default), Blue, Teal, Rose, and Amber. Your choice is saved on this device and follows the system's light/dark appearance and Increase Contrast setting. Vocabulary-source colors, key-sentence highlights, and success/error colors stay unchanged.
- **Library:** search imported transcripts and see practice/analysis status. Swipe left or long-press a card → **Remove from Library**, then confirm to delete that transcript and its downloaded media; global word-review history is preserved. Already-started provider requests may still be billed; their results are discarded if the transcript was removed. Podcast-link import previews the episode, transcript count, audio lookup, and target level before saving.
- **Reader:** tap any word for its lemma/meaning; add or remove it from dictation, or jump to it in Items. Long-press a sentence to translate or ask AI to explain it. Blue solid underlines = list, orange wavy underlines with `*` = AI, teal dotted underlines with `+` = manual; yellow backgrounds = key sentences. Optional AI word details include IPA pronunciation; offline pronunciation audio remains available without AI.
- **Items:** source chips show counts. Filter by source or CEFR level, swipe to remove, restore removed words, and long-press an item to change its example sentence. Rows show the example and current review box.
- **Dictation:** tap blanks and type directly in the paragraph, with no separate answer fields. On the second attempt, the same blank becomes a connected word with underscores instead of cells or borders: supplied first/last/every-third-index letters stay fixed, typing fills the underscores and advances through missing letters, and backspace/paste work in place. The original wrong attempt is retained in answer history. Check grades the visible blanks together; a second miss reveals that answer. Overlapping word/phrase blanks become editable in successive checks within the same paragraph. Correct answers stay completed while you retry the others. Progress counts paragraphs; grades and global Leitner reviews remain per word and save immediately, even if you close the session. Replay uses the full paragraph audio or paragraph TTS. For downloaded, timed audio, tap or drag the smooth waveform to preview a position; release starts playback there within the current paragraph. Blanks have no visible number labels. Answers show incorrect attempt history and pronunciation audio. The completion screen shows elapsed time and can start a new round containing only missed words.
- **Review:** boxes 1–5 schedule 1/2/4/8/16-day intervals. Box 5 is skipped unless “Include Mastered Words” is enabled in the reader's More menu.
- **Share extension:** Podcasts → Share → PodLearn → Save. The extension checks URL representations across attachments before falling back to transcript text, asks Foundation to load native URL objects (including iOS's archived NSURL representation), and extracts supported links from shared text or the share item's body. A video/episode preview shows **Link** with its URL, not just the shared title. Open PodLearn to process pending imports. A failed shared import stays queued for retry; the app never silently discards it.

### PDF / Word → cleaned text → generated audio

1. Settings → **Speech → Generated Audio** → enter an OpenRouter key → **Save TTS Key**. The defaults are **`elevenlabs/eleven-v4-turbo`** and **`george`**. Model and voice IDs can be changed together to another OpenRouter model that supports MP3. This key has its own device-only Keychain entry, separate from AI analysis and speech transcription keys.
2. Enable AI and save your text-AI provider/model/key in **Settings → Provider**. Document cleanup uses that provider, separately from OpenRouter speech generation.
3. Tap **+ → Text**. The same tab has a paste editor and **Import File** for PDF, DOC, DOCX, TXT, SRT, or VTT. **Importing a PDF or Word document immediately creates and opens a saved learning session.** No Clean Text, Generate Audio toggle, or Import button is needed for these documents. Opening a supported document directly in PodLearn uses the same automatic flow.
4. The session automatically runs **on-device text extraction → AI cleanup and piece planning → vocabulary marking → parallel TTS generation**, with progress in the reader and Library. The entire raw extracted document is sent in **one AI request**, using a JSON schema for `{"pieces":["first cleaned piece","next cleaned piece"]}`. The model cleans and chooses coherent boundaries with full-document context. Each piece must be nonblank and at most 4,000 Unicode characters; additional fields, malformed output, oversized pieces, and truncated responses are rejected before synthesis. Schema rejection does not fall back to a second request or an unstructured format. The selected model must fit the complete document in its context and return the complete result in one response (the app caps cleanup output at 32,768 tokens); an oversized document fails visibly with its original file kept. The cleaned transcript becomes readable before audio finishes. AI can still omit or alter content.

The source document is staged locally, excluded from backups and iCloud, so an interrupted extraction/cleanup offers **Retry Document Processing** after relaunch. Files and extracted text are limited to 5 MB. Locked PDFs and pages with no selectable text show a processing error; OCR is not included. Document binaries are never uploaded. The source and intermediate files are removed only after the cleaned transcript and generated audio are saved. Cleanup retries resend extracted text; audio-generation retries reuse completed speech parts. Missing AI consent or keys leaves a saved session with a settings link and retry action rather than silently skipping cleanup.

Word extraction runs entirely on-device. DOCX uses pinned **ZIPFoundation 0.9.20** (MIT) to read only the main document XML, with bounded decompression, CRC checks, namespace-aware XML parsing, and no external entity resolution or linked-resource loading. Legacy Word 97–2003 binary DOC uses a bounds-checked compound-file and [MS-DOC piece-table reader](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-doc/01d5d8c4-cf9c-4ef9-80fd-439e763cfe01), preserving logical text order, Unicode, paragraph/cell boundaries, and displayed field results rather than field instructions. Password-protected, damaged, and older unsupported binary Word documents fail with an explanation rather than importing partial text. This is main-body text extraction, not a Word layout renderer: images, comments, headers/footers, and separate footnote/endnote stories are not narrated. Binary DOC tracked changes are not resolved; accept or reject revisions in Word before importing. The ZIPFoundation license is included in Settings → Acknowledgments.

Pasted text and TXT/SRT/VTT imports retain their optional **Clean Text with AI**, **Restore Original Text**, and **Generate Audio After Import → Import & Generate** controls. You can also use the reader’s **More → Generate Audio** later.

The app calls OpenRouter’s [`POST /api/v1/audio/speech`](https://openrouter.ai/docs/guides/overview/multimodal/tts) with explicit MP3 output, Bearer authentication, and a supported voice. AI-planned pieces are sent independently and **in parallel**, without re-splitting valid AI-planned document pieces; legacy/manual paragraphs longer than 4,000 characters are split locally as a safety fallback. One app-wide adaptive limiter starts at **2 concurrent requests**, increases after successful responses up to an **app safety ceiling of 8**, and halves concurrency on HTTP 429. OpenRouter [does not publish a fixed paid-TTS concurrency quota](https://openrouter.ai/docs/api/reference/limits); its key API’s `rate_limit` field is deprecated, so it is not used to invent a quota. The limiter follows actual throttling responses, shares cooldowns across sessions, honors `Retry-After` and exhausted `X-RateLimit-Remaining`/`X-RateLimit-Reset` windows, and uses exponential backoff when no retry hint is supplied. Only explicit 429 responses are automatically retried, at most four times; resets more than an hour away stop for manual retry. Network failures/lost responses and other HTTP errors are not automatically replayed.

Responses must have a successful HTTP status, an MP3 content type, nonempty bytes, and a readable positive audio duration before being saved. Completed parts are cached by text/model/voice and reused on **Retry Audio Generation**; duplicate identical pieces share a cached response, and changing model or voice generates new parts. Audio is always joined in document order, not response-completion order. A lost response can still cause a second charge on manual retry.

Parts are combined on-device into one M4A file with measured paragraph ranges, so full playback, paragraph replay, seeking, and dictation use the generated audio. Timestamps are not estimated from word count: AVFoundation measures each generated part’s duration, and the concatenation cursor supplies its start/end. A paragraph split across several requests spans its first part’s start through its last part’s end. These are paragraph-level boundaries, not STT word timestamps. For example, durations of 8.2 s and 5.3 s produce ranges 0–8.2 s and 8.2–13.5 s. Individual-word pronunciation still uses the offline system voice. Audio is labeled AI-generated, excluded from backups, and never synced to iCloud. Settings → **Downloaded Media** includes completed audio, staged documents, and unfinished generation parts; deleting it keeps saved transcript text and learning history, but a document session without saved cleaned text will need its original file imported again.

**Keep PodLearn open while generating.** Interrupted generation offers retry after relaunch. AI cleanup sends text to your configured AI provider; speech generation sends the cleaned text to OpenRouter and its speech provider, and both can incur charges. No real keys, document text, or paid provider calls are used in normal tests. Automated tests cover PDF extraction and rejection paths, real DOC/DOCX fixtures, Unicode and logical binary-text ordering, Word field/table handling, malformed/encrypted/cyclic/oversized files, ZIP CRC failures, XML entities, single-call cleanup/schema validation and truncation, the speech request contract, invalid-audio rejection, out-of-order parallel responses, shared concurrency limits, quota cooldowns, bounded 429 retries, cancellation, cached-part retries, and real audio joining/timing using synthetic tone fixtures.

### Bilibili and Microsoft transcription

Settings → **Audio Transcription**: enable transcription, enter your speech provider base URL and key, then **Save Speech Key**. Use an Azure Speech resource root URL (for example, `https://your-resource.cognitiveservices.azure.com`) for direct MAI-Transcribe-2, or `https://openrouter.ai/api/v1` with model `microsoft/mai-transcribe-2` and an OpenRouter key. This uses a separate device-only Keychain entry, not the text AI key; existing saved Speech keys are preserved. No microphone permission is needed for downloaded audio.

Paste or share Bilibili `/audio/au…`, `/video/BV…`, `/video/av…`, or `b23.tv` links. Shared titles containing a Bilibili link are accepted. `?p=2` selects one video part; parts are imported separately. Audio posts use the [requested music-stream API](https://github.com/Goooler/bilibili-API-collect/blob/trunk/docs/audio/musicstream_url.md); videos resolve signed WBI/DASH audio. Downloads send the required Referer and User-Agent and fall back to backup CDNs. Only freely accessible full recordings are supported: paid previews and login-restricted content are rejected. Video thumbnails use the documented [`/x/web-interface/view` → `data.pic`](https://github.com/Goooler/bilibili-API-collect/blob/trunk/docs/video/info.md) cover URL; HTTP and protocol-relative Bilibili image URLs are normalized to HTTPS, including covers already saved in the library.

**Audio only is the default.** Enable **Keep Bilibili Video** to also retain a local MP4 with sound, playable from the reader’s More menu. Video is never uploaded for STT. Turning the setting off also skips video on retry. M4A audio is converted on-device to mono 16 kHz PCM WAV for the [documented MAI API](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe). Recordings must be shorter than two hours and prepared audio smaller than 250 MB. Direct Azure keeps its existing multipart API. OpenRouter uses its [OpenAI-compatible multipart transcription API](https://openrouter.ai/docs/guides/overview/multimodal/stt), Bearer authentication, `verbose_json`, and segment/word timestamps. It caps multipart uploads at 25 MB, so prepared audio is split into five-minute WAV parts (about 9.6 MB each). Completed part results are checkpointed separately; retry sends only unfinished parts and combines timestamps using each part’s original audio offset. Models without usable timestamps are rejected rather than inventing timing. Word timestamps become sentence-sized practice clips; recognition can make mistakes.

Bilibili imports are saved before transferring, with visible download/upload/transcription states. Alamofire 5.10.2 uses disk-backed multipart encoding, connectivity waits, five bounded exponential-backoff retries for temporary connection failures and HTTP 408/429/5xx responses, and Retry-After delays (up to one hour; longer delays stop for manual retry). Authentication and permanent validation failures are not automatically retried. Upload progress is not transcription progress; waiting for recognition/results is indeterminate.

**Keep PodLearn open while transferring.** This is a foreground Alamofire session, not an iOS background-transfer guarantee. After termination, imports offer **Retry Transcription** in the reader. Completed audio, prepared WAV, optional video tracks, and validated JSON results remain local until the transcript is durably saved. Completed checkpoints are reused; partial media never replaces good media. Successful imports remove intermediate transfer files. Settings → Downloaded Media counts and deletes audio, video, and intermediate files without deleting transcript text or reviews.

The Speech API is synchronous: the transcript arrives in the upload response, with no resumable upload token or retrievable result job ID. A lost response is recovered by replaying the request and **may cause another provider charge**. Exactly-once billing and completion while force-quit/offline are not guaranteed. Transcription is separate from optional AI analysis consent; keys, audio, and transfer checkpoints never enter SwiftData or iCloud.

### Audio and network behavior

Podcast imports call PodText directly, then resolve audio through iTunes lookup and RSS GUID/title matching. Downloaded audio stays in Application Support, excluded from backup; it can be deleted in Settings without deleting transcripts or review history. Missing audio on another device can be downloaded in the reader or its More menu. The reader shows byte-based download progress (indeterminate when the size is unknown) and an inline Retry Audio Download action on failure, including failed audio-link resolution. Interrupted downloads can be restarted from the reader after relaunch. Downloads and AI analysis do not block reading or text-to-speech practice. A missing transcript shows an error; paste/file import remains available.

AI uses the pinned **[teunlao/swift-ai-sdk](https://github.com/teunlao/swift-ai-sdk)** (`4e0230a06092583c4dd541071b1ce8e181821bf9`), with explicit Chat Completions, Responses, Anthropic Messages, or Gemini routing and a single long-context analysis call per import. The shared `PodcastAI` module is used by both the app and live tests; the share extension remains dependent only on PodcastCore. Selected thinking effort is checked on the outgoing request: unsupported levels fail before sending rather than silently falling back. Provider Default omits reasoning effort. Reasoning text is not displayed or stored. Transcript analysis and individual word details each request their own JSON schema; word details require string fields `glossZh`, `definitionEn`, and `phonetic`, with no additional properties. Structured JSON-schema output falls back only for response-format rejection: JSON-object mode for OpenAI/Gemini, or prompted JSON for Anthropic. Native thinking uses the SDK’s effort or token-budget mapping; unsupported effort substitutions fail before sending rather than silently changing the selected level. Responses are decoded and checked against real sentence/item IDs, verbatim text boundaries, duplicates, and previously removed words. Interrupted/failed analysis can be retried. AI is opt-in: enabling it sends transcript content to your selected provider and may incur usage charges. Keys are stored in device-only Keychain storage, never SwiftData or iCloud.

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
node scripts/check-themes.mjs  # theme defaults/persistence and light/dark contrast
node scripts/check-waveform.mjs  # render the real SwiftUI waveform on macOS
node scripts/check-reader-playback.mjs  # assert playback ticks don't re-render transcript rows

# App + share extension, both simulator architectures; no signing required
xcodebuild -project PodcastLearning.xcodeproj \
  -scheme PodcastLearning -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

# Rebuild vocabulary data from the checked-in source lists
uv run --with openpyxl scripts/build_wordlist.py

# Regenerate the Xcode project after adding/removing app Swift files
python3 scripts/generate_project.py
```

The project generator owns `project.pbxproj` and the shared scheme. It preserves `Config.xcconfig`, source files, plists, and entitlements; reapply any target-setting edits after regeneration. Package revisions are pinned in the project and `Package.resolved`.

### Releases

`.github/workflows/release.yml` publishes an IPA. Bump `CFBundleShortVersionString` in `PodcastLearning/Info.plist` (and `ShareExtension/Info.plist`), commit, then tag that exact version:

```sh
swift test
git tag v1.0 && git push origin v1.0
```

The tag must equal `v<CFBundleShortVersionString>` or the job fails before building. The IPA is **unsigned** — SideStore and LiveContainer re-sign it on the phone with your own account, so no certificates are stored in GitHub. The share extension is included; use `build/PodcastLearning-SideStore.ipa` only when installing through SideStore. Manual runs (`gh workflow run release.yml`) build from the current commit and republish the same tag.

### SideStore source

Add this URL to SideStore (**Sources → +**) to install PodLearn and receive in-place updates:

```
https://raw.githubusercontent.com/h4rvey-g/podcast-learning/main/source.json
```

`source.json` is committed at the repository root and regenerated after every release by `scripts/build_source.py` (run locally with `GH_TOKEN=… python3 scripts/build_source.py`). It lists every published `PodLearn-*-unsigned.ipa` with its version, size, and download URL, newest first.

The source advertises `APP_BUNDLE_ID` from `Config.xcconfig`. SideStore matches updates by that identifier: changing it makes the released app a *different* app, so an existing install is not updated. Keep the ID stable, or update SideStore by hand and let it replace the app of the same ID (which preserves its data).

Tests cover answer normalization, hint/attempt states, Leitner transitions and queues, SwiftData persistence/cascade deletion, duplicate memories, subtitle parsing, CEFR lookup/lemmatization, names and thresholds, PodText/iTunes/RSS fixtures, HTTP failures, shared payloads, and AI response/schema validation. Bilibili/STT tests cover canonical/shared links, WBI signatures, audio-only versus video resolution, paid-preview rejection, backup CDNs, interrupted uploads and response bodies, throttling, retry exhaustion, authentication failures, disk-backed multipart contents, cached-result reuse, timestamp validation, real WAV conversion, and MP4 audio/video muxing. Normal test runs do not make live API calls; the opt-in suite below does.

### Opt-in live provider tests

For local automated checks, put credentials in **`.env.live.json` at the repository root**. It is gitignored and never bundled into the app, test resources, or LiveContainer. Use `.env.live.json.example` as the template:

```sh
# Only if the local file doesn't already exist:
cp -n .env.live.json.example .env.live.json
chmod 600 .env.live.json
```

Fill `azureSpeechEndpoint`, `azureSpeechModel`, and `azureSpeechKey` for direct Azure or OpenRouter speech; then `aiBaseUrl` (full HTTPS base URL), `aiKey`, `aiModel`, `aiProvider`, and `thinking`. `aiProvider: "OpenAIProvider"` (or `"responses"`) selects the SDK’s Responses API; `"OpenAICompatibleProvider"` (or `"chat"`) selects Chat Completions; `"AnthropicProvider"` (or `"anthropic"`) selects native Anthropic Messages; `"GoogleProvider"` (or `"gemini"`) selects native Gemini. Set `aiBaseUrl` to the matching API base URL listed above. Thinking values are `provider-default`, `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Legacy `aiHost`/`aiBasePath` fields are still accepted, with Chat Completions as their default. Do not paste keys into chat, source files, Xcode build settings, or shell commands.

```sh
RUN_LIVE_PROVIDER_TESTS=1 swift test --filter LiveProviderTests
```

Normal `swift test` runs **skip all live checks**, even if keys are present. The opt-in suite uploads one short synthetic English recording through the production MAI client, validates timed transcript application and saved-result reuse, then requests a small structured analysis through the production `PodcastAI` client and pinned Swift AI SDK and analysis schema. No real transcript is sent, no Keychain entries are changed, and temporary audio/results are deleted. The AI check mirrors response-format fallback; it is a provider integration check, not an iOS UI test.

For a full Bilibili download-to-transcription integration check, run the separate opt-in test:

```sh
RUN_LIVE_BILIBILI_TESTS=1 swift test --filter bilibiliDownloadsAndTranscribesTimedAudio
```

It resolves `https://www.bilibili.com/video/BV1iu4y1K7UE/` through the production Bilibili client, downloads the **entire audio track** (no video), converts it to WAV, and transcribes the full recording through the configured speech provider. It checks downloaded duration against Bilibili metadata, validates timed Reader segments (including timestamps beyond the first five-minute OpenRouter part for longer recordings), reports segment/word timestamp counts, and verifies saved-result reuse after deleting the WAV. Word timing is reported when supplied; only usable segment timing is required. Temporary media/results are deleted, and no transcript text, signed CDN URLs, or credentials are logged. This test is independent of `RUN_LIVE_PROVIDER_TESTS`; the small provider checks never trigger the full Bilibili upload. Freely accessible source availability and network restrictions can affect this live test.

Live calls may incur provider charges for the **full recording**. Speech application-level retries are disabled for live tests to avoid repeated billable uploads; network-recovery tests remain mocked. AI schema rejection can make one additional JSON-mode request. Provider response bodies and raw SDK errors are deliberately withheld from failure logs, and credentials are never printed. macOS's local Samantha voice is used for the synthetic recording.

### Device verification checklist

- Import a podcast with audio and replay a paragraph; check pause, 15-second skips, speed, tap/drag paragraph seeking, headphones disconnect, and interruptions.
- Install the en/zh-Hans translation packs and translate both a word and sentence.
- Test share-extension URL/text/file import with signed App Groups.
- Test a real long-context AI provider, including retry and schema fallback.
- Import Bilibili au/BV/av/b23 links with an Azure resource; toggle airplane mode during upload and response delivery, retry after relaunch, and verify timed practice clips. Test Keep Video and media deletion. Live provider billing, long recordings, and device background/suspension behavior need hardware verification.
- Verify all 22 Figma states (including the Download & Paragraph States and Bilibili & Transcription pages) on small/large phones, in dark mode, Dynamic Type, and VoiceOver.
- If enabled, verify CloudKit sync on two signed devices and re-download missing audio.

## Layout

```
PodcastLearning/         SwiftUI screens, app orchestration, AI, Keychain, audio
Sources/PodcastAI/       Shared Swift AI SDK client, thinking levels, provider routing
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
