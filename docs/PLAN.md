# Podcast Learning — Plan

A personal iOS app for learning English through intensive reading of podcast transcripts. You import an episode transcript, words at or above your target CEFR level are marked automatically, AI adds key sentences and other hard words or phrases, and you practice the result as word dictation over the real podcast audio.

## 1. Decisions

| Area | Decision |
|---|---|
| Users | Just me. No accounts, billing, or server. |
| Platform | iOS 18+, SwiftUI + SwiftData, iCloud sync (CloudKit). Installed with Xcode, not the App Store. |
| Languages | English content, Chinese (zh-Hans) translations and glosses. |
| Content | Apple Podcasts episodes (transcript + audio). Plain text as secondary input. |
| Podcast transcript | PodText backend `POST https://pod-text.com/api/transcript`, called directly (no wrapper or fallback). |
| Podcast audio | MP3 resolved via iTunes lookup → RSS guid → RSS title match, downloaded and kept locally, deletable. |
| Text import | Paste, share sheet, `.txt` / `.srt` / `.vtt` files. No audio: dictation uses TTS. |
| Word lists | CEFR-J 1.6 (A1–B2) + Octanove C1/C2 1.0, preprocessed into one bundled JSON. |
| Target level | Global setting (e.g. B2+) with a per-transcript override. |
| Lemmatizer | Apple NaturalLanguage (`NLTagger`, `.lemma` + `.lexicalClass` + `.nameType`). |
| AI | Your own API key (Keychain). `MacPaw/OpenAI` Swift package with any OpenAI-compatible host. One long-context call per transcript, run automatically on import. |
| AI role | Pick key sentences, find hard words or phrases in them that the lists miss (auto-added, you remove), and write Chinese glosses for all dictation items. Explains a sentence on demand. |
| Ads | Kept and treated as normal text. |
| Tap translation | Word: popover (lemma, level, gloss, add/remove, 🔊). Sentence (long-press): Apple Translation framework + "AI explain". |
| Dictation | Per transcript, word cloze only. One item per word/phrase, at its first occurrence. |
| Dictation audio | Plays the whole paragraph (PodText segment) clip from the MP3 via AVPlayer. Without audio, the sentence is spoken with `AVSpeechSynthesizer`. |
| Hint ladder | Attempt 1: blank, length hidden. Attempt 2: first + last + every 3rd letter. Then reveal. |
| Answer check | Exact surface form, case-insensitive, trimmed, apostrophes normalized. |
| Review | Leitner boxes 1–5, global memory per word. Mastered (box 5) words are skipped by default, with a toggle to include them. |
| Repo | Xcode project (app + share extension + unit tests), `scripts/`, `resources/`, `docs/`. |

### Not in v1
- Sentence dictation, multiple-choice quizzes, a global "due today" queue across transcripts.
- Showing exact sentence spans inside a paragraph (word-level alignment).
- Ad filtering, transcript summaries, comprehension questions.
- Android, web, other native languages, accounts.
- Wrapping PodText behind an abstraction or adding a fallback (chosen: just call it).

## 2. Verified external facts (2026-11-02)

**PodText** (endpoint read from pod-text.com page source and tested with `https://podcasts.apple.com/us/podcast/want-to-enjoy-music-more-go-for-a-run/id1200361736?i=1000799212333`):

```
POST https://pod-text.com/api/transcript
Content-Type: application/json
{"url": "<apple podcasts episode url>", "uid": "<random uuid, generated once and stored>"}

200 → {"success": true, "data": {
  "platform": "apple_podcast", "id": "1000799212333", "title": "...", "author": "...",
  "releaseDate": "2026-11-01", "duration": "36:12", "cover": "<url>", "description": "...",
  "totalWords": 5997, "totalSegments": 207,
  "segments": [{"start": "01:12", "startSeconds": 72.9, "end": "01:13", "endSeconds": 73.8,
                "speaker": "Speaker 2", "text": "What are you listening to?"}]
}}
error → {"success": false, "error": "...", "code": "no_transcript" | ...}
```
- Segments are paragraphs (speaker turns). In the test episode, segment duration was 4.8s median, 32s at the 90th percentile and 44s max, with 17 words median and 108 max.
- The endpoint is undocumented, so it may change or block requests. If it fails, the app shows the error, and paste import still works.

**MP3 resolution**
1. Parse `showId` (`/id(\d+)`) and `episodeId` (`?i=`) from the URL. `data.id` == episodeId.
2. `GET https://itunes.apple.com/lookup?id=<showId>&entity=podcastEpisode&limit=200`, then match `trackId == episodeId` and take `episodeUrl` (`episodeGuid` is available for step 3). In the test this failed: The Daily's index returns only 44 thinned-out episodes.
3. `results[0].feedUrl` → fetch the RSS feed and match the `<item>` by `<guid>` (if known), otherwise by normalized `<title>` == `data.title`. Take `<enclosure url>`. This worked for the test episode (a podtrac redirect URL).
4. If no match is found, import without audio and use TTS.

**Apple Podcasts TTML** (the approach used by the linked repos) needs the macOS Podcasts cache or a FairPlay-signed token, so it can't be used on iOS. Rejected.

**MacPaw/OpenAI**: actively maintained (~3k★). Supports iOS 13+. `OpenAI.Configuration(token:host:basePath:...)` targets any OpenAI-compatible provider. Structured output via `ChatQuery(responseFormat: .jsonSchema(... .derivedJsonSchema(T.self)))`.

**Word lists** in `resources/`:
- `CEFR-J Wordlist Ver1.6.xlsx`: use sheet `ALL_sep`, columns `headword, pos, CEFR, ...`. 7,988 rows: A1 1200, A2 1443, B1 2486, B2 2859. Some headwords have variants separated by `/` (e.g. `a.m./A.M./am/AM`).
- `octanove-vocabulary-profile-c1c2-1.0.csv`: columns `headword,pos,CEFR,notes` with CRLF line endings. 2,136 rows: C1 1111, C2 1025. 50 headwords contain `/` variants (`favorably/favourably`). Contains repeated headwords with sense notes (`cast,verb,...`), one typo `vern`, and one empty POS.

## 3. Architecture

```
PodcastLearning (app target)
├── Import/      PodTextClient, AudioResolver (iTunes+RSS), AudioDownloader, TextImporter (txt/srt/vtt)
├── Analysis/    Segmenter (NLTokenizer sentences), Lemmatizer (NLTagger), LevelMarker, AIAnalyzer
├── Reader/      TranscriptView, WordPopover, SentenceSheet (Translation + AI explain)
├── Dictation/   DictationSession, ClozeView, HintMask, AnswerChecker, ClipPlayer (AVPlayer) / Speaker (TTS)
├── Review/      Leitner
├── Model/       SwiftData models
└── Settings/    target level, AI host/model/key, TTS voice/rate
ShareExtension   accepts URL / text / file → writes a pending import into the App Group → app imports on foreground
Tests            pure-logic unit tests
scripts/build_wordlist.py → resources/wordlist.json (bundled)
```

There's no server, and all network calls go straight from the phone: PodText, iTunes, RSS, the MP3 host and the LLM provider.

## 4. Data model (SwiftData, CloudKit-compatible)

CloudKit rules: no `@Attribute(.unique)`, every property optional or defaulted, and every relationship optional. Code dedupes by key on fetch.

```swift
@Model Transcript
  title, author, coverURL, sourceURL, episodeID?   // episodeID set for podcasts
  remoteAudioURL?                                  // resolved MP3 URL
  hasLocalAudio: Bool                              // file at AppSupport/Audio/<id>.mp3, not synced, excluded from backup
  targetLevelOverride: String?                     // nil = global setting
  analysisState: String                            // pending | marked | aiDone | aiFailed
  createdAt
  segments: [Segment]?   items: [DictationItem]?

@Model Segment          // PodText segment = paragraph; text import: one per paragraph / SRT cue
  index, speaker?, start: Double?, end: Double?, text
  sentences: [Sentence]?

@Model Sentence
  index (global within transcript), text, isKey: Bool, keyNoteZh?

@Model DictationItem    // one per word/phrase per transcript
  text            // surface form to type (may be multi-word)
  key             // lowercased lemma, or the lowercased phrase → WordMemory
  level?          // A1…C2 from the lists, nil for AI-only items
  source          // list | ai | manual
  glossZh?, definitionEn?
  sentence: Sentence?   // first occurrence by default, user can change it
  isRemoved: Bool       // soft delete so re-running analysis doesn't bring it back

@Model WordMemory       // global, keyed by DictationItem.key
  key, box (1…5), dueAt, attempts, correct, lastPracticedAt
```

Settings live in `@AppStorage`. The API key is stored in Keychain.

## 5. Flows

### 5.1 Podcast import
1. The link arrives via paste or the share extension (Podcasts app → Share → Learn).
2. `PodTextClient` posts the URL and creates a `Transcript`, its `Segment`s and its `Sentence`s (NLTokenizer within each segment).
3. In the background, `AudioResolver` → `AudioDownloader` saves the MP3 and sets `hasLocalAudio`. A failure here doesn't block anything.
4. List marking runs (5.3). The transcript can be opened right away.
5. AI analysis runs (5.4). AI items appear when the call returns.

### 5.2 Text import
Paste, share or open `.txt` / `.srt` / `.vtt`. For SRT/VTT, cue numbers, timestamps and tags are stripped and cues are merged into paragraphs (the timings are dropped, since there's no audio). Plain text is split on blank lines. Then the same marking and AI steps run.

### 5.3 List marking (offline, instant)
For each sentence, `NLTagger` returns token, lemma, lexical class and name type.
- Skip personal, place and organization names, numbers and punctuation.
- Look up `(lemma, pos)` in `wordlist.json`, then `lemma` alone (lowest level), then the lowercased surface form.
- If `level >= target`, create a `DictationItem(source: .list)` at the first occurrence only. Later occurrences are just highlighted in the reader.

### 5.4 AI analysis (one call)
- Input: the sentences with ids, the target level, and the list items (id, text, sentence id) that need glosses.
- Output (JSON schema):
  ```json
  { "keySentences": [{"sentenceId": 12, "noteZh": "..."}],
    "extraItems":   [{"text": "go for a run", "sentenceId": 12, "kind": "phrase", "glossZh": "...", "definitionEn": "..."}],
    "glosses":      [{"itemId": "...", "glossZh": "...", "definitionEn": "..."}] }
  ```
- Validation (trust boundary): drop an `extraItem` unless its `text` appears in that sentence (case-insensitive). Drop duplicates of existing or removed items, and unknown ids. Extra items get `source: .ai` and are auto-added.
- If the call fails, set `analysisState = aiFailed` and show a retry button. List items remain usable without glosses.
- Long-context model required (a 6k-word episode is about 8k tokens in and several thousand out). Set max output tokens generously.

### 5.5 Reader
- The transcript is shown by segment with speaker labels. Key sentences get a background tint. Item words are colored by source (list, AI or manual). Removed items aren't highlighted.
- **Tap a word** to open a popover: surface form, lemma, CEFR level, Chinese gloss (the item's gloss if there is one, otherwise Apple Translation of the word), 🔊 TTS, and add/remove for this transcript's dictation. Manual adds become `source: .manual`. Their gloss comes from Apple Translation, with an optional "AI gloss" button.
- **Long-press a sentence** to open a sheet: Apple Translation (`.translationTask`, en → zh-Hans, on-device language pack), 🔊 (plays the paragraph clip or TTS), and "AI explain" (grammar and meaning in Chinese, generated on demand and not stored).
- **Item list tab**: every item for the transcript, filterable by source and level, with removed items in a "Removed" section where they can be restored. You can change an item's sentence here.

### 5.6 Dictation (per transcript)
- **Queue**: the transcript's non-removed items, minus mastered ones (`box == 5`) unless the toggle is on. Due and low-box items come first, then the rest in transcript order.
- **Card**: the sentence with the item's text blanked out as `____`, with no length shown. Phrases blank the whole phrase. The paragraph clip auto-plays: `AVPlayer` seeks to `segment.start - 0.3s` and stops at `segment.end + 0.3s` via a boundary time observer. Without audio, `AVSpeechSynthesizer` speaks the sentence (voice and rate from Settings). There's a replay button.
- **Attempt 1**: no letters shown.
- **Attempt 2** (after a wrong answer): show the first letter, last letter and every 3rd letter (indices 0, 3, 6, … and the last). Example: `important` → `i _ _ o _ _ a _ t`. Spaces and punctuation in phrases are always shown.
- **Reveal** (after a second wrong answer): show the answer, gloss and replay.
- **Check**: `trim`, lowercase, map `’` to `'`, then compare with the surface form exactly.
- **Grade** for Leitner: correct on attempt 1 → box +1. Correct on attempt 2 → box stays. Revealed → box = 1. Intervals for boxes 1–5 are 1, 2, 4, 8 and 16 days. Each result updates `WordMemory.attempts`, `correct` and `lastPracticedAt`.
- **End screen**: correct counts per attempt, plus a list of the words you missed.

### 5.7 Settings
Target level (A1…C2, default B2). AI: host, base path, model and API key, plus a "Test" button. TTS voice (en-US / en-GB) and rate. Storage: per-transcript audio size with a "Delete audio" button. Credits for CEFR-J and Octanove.

## 6. Word list preprocessing — `scripts/build_wordlist.py`

Run with `uv run --with openpyxl scripts/build_wordlist.py`.
- Read CEFR-J `ALL_sep` and the Octanove CSV (strip CRLF, fix `vern` → `verb`, treat empty POS as any POS, ignore `notes`).
- Split `/` variants into separate entries. Lowercase headwords, but keep the original case only if it's all caps.
- Map POS to `noun | verb | adjective | adverb | other`.
- If a `(headword, pos)` pair appears more than once (across lists or across Octanove senses), keep the **lowest** level.
- Output `resources/wordlist.json` as `{"lemma": {"noun": "B2", "verb": "C1"}, ...}`, and print counts per level as a self-check (asserts: total > 9,000, and all six levels present).

## 7. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | `scripts/build_wordlist.py` + `wordlist.json` | Script asserts pass. JSON is bundled in the app. |
| M1 | Xcode project, models, text import, reader with word popover + sentence sheet (Apple Translation) | You can paste text, tap words and translate sentences on the device. |
| M2 | List marking, target level (global + override), item list with add/remove/restore | A B2+ setting marks the expected words in a sample text. |
| M3 | Dictation with TTS, hint ladder, Leitner, skip mastered | You can finish a session, and the boxes and due dates update. |
| M4 | Podcast import: PodText, MP3 resolver/downloader, share extension, AVPlayer paragraph clips | Importing the test URL gives 207 segments, the MP3 plays, and dictation plays the paragraph clip. |
| M5 | AI analysis (MacPaw/OpenAI), key sentences, extra items, glosses, "AI explain", retry | The test episode gets key sentences, AI phrases auto-added, glosses on all items. |
| M6 | Turn on iCloud sync (CloudKit container), handle missing audio on a second device | Data appears on a second device. Audio shows "Download" there. |

## 8. Tests (unit, no UI)
- `HintMask`: lengths 1–3, phrases, punctuation.
- `AnswerChecker`: case, whitespace, curly apostrophes.
- `Leitner`: transitions and intervals.
- `LevelMarker`: inflections (`studied` → `study`, `abilities` → `ability`), names skipped, first occurrence only, threshold.
- `TextImporter`: SRT/VTT stripping.
- `PodTextClient` / `AudioResolver`: decode trimmed fixtures (a few segments, a small RSS sample).
- AI response validation: drops items not found in their sentence, unknown ids and duplicates.

## 9. Risks
- **PodText disappears or changes**: podcast transcript import breaks, and paste import is the only way in. Accepted.
- **Paragraph clips are long** (up to ~44s): accepted. Exact sentence spans are left for later.
- **SwiftData + CloudKit**: no unique constraints, so a duplicate `WordMemory` can appear when syncing. Merge rows by key on fetch.
- **Translation framework**: the en → zh-Hans language pack must be downloaded on first use, and the system prompts for it.
- **Free Apple ID signing** expires every 7 days. A $99/yr developer account removes this.
- **AI providers** without strict `json_schema` support: fall back to `json_object` plus the same decoding and validation.
- **Licensing**: CEFR-J and Octanove (CC BY-SA) need attribution, which goes in the Settings credits. Personal use only.

## 10. Glossary
- **Transcript**: one imported episode or text.
- **Segment**: one paragraph or speaker turn, which has audio start/end for podcasts.
- **Sentence**: an NLTokenizer sentence inside a segment, and the unit for translation and key highlighting.
- **Item (DictationItem)**: a word or phrase in a transcript's dictation set, with source list, AI or manual.
- **Target level**: the minimum CEFR level that list marking keeps.
- **Word memory**: global Leitner state for each lemma or phrase key.
- **Mastered**: Leitner box 5.
