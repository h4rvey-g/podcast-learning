import SwiftUI
import AVKit
import PodcastCore

private enum ReaderSelection: Identifiable {
    case word(String, Sentence), sentence(Sentence)
    var id: String { switch self { case .word(let word, let sentence): return sentence.id.uuidString + word; case .sentence(let sentence): return sentence.id.uuidString } }
}

struct ReaderView: View {
    @Bindable var transcript: Transcript
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var player
    @State private var tab = 0
    @State private var selection: ReaderSelection?
    @State private var highlightedItemID: UUID?
    @State private var practice = false
    @State private var showVideo = false
    @State private var includeMastered = false
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CoverArt(transcript: transcript, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transcript.title).font(.headline).lineLimit(2)
                    Text([transcript.author, transcript.duration.map(timestamp), "\(transcript.activeItems.count) words"].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 16)
            Picker("Content", selection: $tab) { Text("Transcript").tag(0); Text("Items").tag(1) }.pickerStyle(.segmented).padding(.horizontal, 16)
            if tab == 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        Text("List").underline().foregroundStyle(Palette.list)
                        Text("AI*").customAttribute(WavyUnderline()).foregroundStyle(Palette.ai).textRenderer(SourceUnderlineRenderer())
                        Text("Manual+").underline(true, pattern: .dot).foregroundStyle(Palette.manual)
                        HStack(spacing: 4) { Capsule().fill(.yellow).frame(width: 3, height: 14); Text("Key sentence").foregroundStyle(.secondary) }
                    }.font(.footnote).padding(.horizontal, 20).padding(.vertical, 2)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        transcriptionStatus
                        analysisStatus
                        ForEach(transcript.orderedSegments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    player.toggleParagraph(segment, transcript: transcript, settings: settings)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: player.isActive(segment, in: transcript) ? "pause.fill" : "play.fill")
                                            .font(.caption).frame(width: 28, height: 28)
                                            .foregroundStyle(player.isActive(segment, in: transcript) ? Palette.onAccent : Palette.accent)
                                            .background(player.isActive(segment, in: transcript) ? Palette.accent : Palette.accent.opacity(0.08), in: Circle())
                                        Text(segment.speaker ?? "Paragraph \(segment.index + 1)")
                                        if let start = segment.start { Text(timestamp(start)).monospacedDigit() }
                                    }.font(.footnote).foregroundStyle(.secondary).frame(minHeight: 36)
                                }.buttonStyle(.plain).accessibilityLabel("\(player.isActive(segment, in: transcript) ? "Pause" : "Play") \(segment.speaker ?? "paragraph")")
                                ForEach(segment.orderedSentences) { sentence in
                                    HighlightedText(sentence: sentence, items: transcript.activeItems) { word in selection = .word(word, sentence) }
                                        .padding(sentence.isKey ? 10 : 0)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(sentence.isKey ? Palette.key : .clear, in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(alignment: .leading) { if sentence.isKey { Capsule().fill(.yellow).frame(width: 3).accessibilityHidden(true) } }
                                        .simultaneousGesture(LongPressGesture().onEnded { _ in selection = .sentence(sentence) })
                                        .accessibilityAction(named: "Translate Sentence") { selection = .sentence(sentence) }
                                }
                            }
                        }
                    }.padding(20)
                }.background(Palette.cell, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
            } else { ItemsView(transcript: transcript, focusedItemID: highlightedItemID) { item in if let sentence = item.sentence { selection = .word(item.text, sentence) } } }
        }
        .background(Palette.background).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Use Global (\(settings.targetLevel))") { store.changeLevel(transcript, to: nil) }
                    ForEach(CEFR.allCases, id: \.rawValue) { level in Button(level.rawValue + " and Above") { store.changeLevel(transcript, to: level.rawValue) } }
                } label: { Text((transcript.targetLevelOverride ?? settings.targetLevel) + "+").font(.headline) }.accessibilityLabel("Target Level")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Include Mastered Words", isOn: $includeMastered)
                    if let file = try? AudioStore.videoFile(transcript.id), FileManager.default.fileExists(atPath: file.path) {
                        Button("Play Downloaded Video", systemImage: "video") { player.stop(); showVideo = true }
                    }
                    Button("Analyze with AI", systemImage: "sparkles") { Task { await store.analyze(transcript) } }.disabled(transcript.analysisState == "pending" || transcript.orderedSegments.isEmpty)
                    if (transcript.remoteAudioURL != nil || transcript.sourceURL != nil) && AudioStore.localURL(transcript.id) == nil {
                        Button(store.audioErrors[transcript.id] == nil ? "Download Audio" : "Retry Audio Download", systemImage: "arrow.down.circle") { Task { await store.downloadAudio(transcript) } }.disabled(store.downloading.contains(transcript.id) || store.transcribing.contains(transcript.id))
                    }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if transcript.transcriptionState == "none" || transcript.transcriptionState == "done" { AudioDownloadStatus(transcript: transcript) }
                if tab == 0 && !transcript.orderedSegments.isEmpty { PlaybackBar(transcript: transcript) }
                PrimaryButton(title: "Start Dictation", symbol: "pencil.line") { player.stop(); practice = true }
                    .disabled(transcript.activeItems.isEmpty).opacity(transcript.activeItems.isEmpty ? 0.5 : 1)
            }.padding(.horizontal, 16).padding(.bottom, 8)
        }
        .sheet(item: $selection, onDismiss: { store.save() }) { value in
            switch value {
            case .word(let word, let sentence): WordSheet(word: word, sentence: sentence, transcript: transcript) { item in highlightedItemID = item.id; tab = 1 }
            case .sentence(let sentence): SentenceSheet(sentence: sentence, transcript: transcript)
            }
        }
        .sheet(isPresented: $showVideo) {
            if let file = try? AudioStore.videoFile(transcript.id) { DownloadedVideoView(url: file) }
        }
        .fullScreenCover(isPresented: $practice) { DictationView(transcript: transcript, includeMastered: includeMastered) }
        .onDisappear { player.stop(); store.save() }
    }
    @ViewBuilder private var transcriptionStatus: some View {
        if transcript.transcriptionState == "pending" {
            VStack(alignment: .leading, spacing: 10) {
                Label(store.transcriptionStatus[transcript.id] ?? "Preparing transcription…", systemImage: "waveform")
                    .font(.headline)
                ProgressView(value: store.transcriptionProgress[transcript.id].flatMap { $0 < 1 ? $0 : nil } ?? (store.transcriptionProgress[transcript.id] == nil ? store.downloadProgress[transcript.id] : nil))
                    .accessibilityLabel("Transcription Transfer")
                Text("Keep Learn open. Temporary network failures retry automatically; audio and completed results are kept for retry.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if transcript.transcriptionState == "failed" {
            VStack(alignment: .leading, spacing: 8) {
                Label("Transcription Interrupted", systemImage: "exclamationmark.arrow.circlepath").font(.headline)
                Text(transcript.transcriptionError ?? "Your downloaded audio is kept.").font(.footnote).foregroundStyle(.secondary)
                Button("Retry Transcription", systemImage: "arrow.clockwise") { Task { await store.transcribe(transcript) } }
                    .frame(minHeight: 44)
                NavigationLink("Audio Transcription Settings") { TranscriptionSettingsView() }.frame(minHeight: 44)
            }
        }
    }
    @ViewBuilder private var analysisStatus: some View {
        if transcript.analysisState == "pending" { HStack { ProgressView(); Text("Finding key sentences…").font(.footnote).foregroundStyle(Palette.ai) } }
        if let error = transcript.analysisError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                if transcript.analysisState == "aiFailed" { Button("Retry AI Analysis") { Task { await store.analyze(transcript) } } }
            }
        }
    }
}

struct PlaybackBar: View {
    let transcript: Transcript
    @Environment(ClipPlayer.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack(spacing: 4) {
            Button("Back 15 Seconds", systemImage: "gobackward.15") { player.skip(-15) }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(AudioStore.localURL(transcript.id) == nil)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle(text: transcript.spokenText, transcript: transcript, settings: settings)
            }.labelStyle(.iconOnly).frame(width: 44, height: 44).foregroundStyle(Palette.cell).background(.primary, in: Circle())
            Button("Forward 15 Seconds", systemImage: "goforward.15") { player.skip(15) }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(AudioStore.localURL(transcript.id) == nil)
            VStack(spacing: 3) {
                if AudioStore.localURL(transcript.id) != nil {
                    ProgressView(value: min(player.position, player.duration), total: max(1, player.duration)).tint(.primary)
                    HStack { Text(timestamp(player.position)); Spacer(); Text("−" + timestamp(max(0, player.duration - player.position))) }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else { Text(store.downloading.contains(transcript.id) ? "Text to Speech · Downloading" : "Text to Speech").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity)
            Button { player.changeSpeed() } label: { Text(String(format: "%g×", player.speed)).font(.headline).frame(minWidth: 44, minHeight: 44) }.disabled(AudioStore.localURL(transcript.id) == nil).accessibilityLabel("Playback Speed")
        }.buttonStyle(.plain).padding(8).background(.regularMaterial, in: Capsule())
            .alert("Playback Failed", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) { Button("Close", role: .cancel) { player.error = nil } } message: { Text(player.error ?? "") }
    }
}

private struct AudioDownloadStatus: View {
    let transcript: Transcript
    @Environment(AppStore.self) private var store
    var body: some View {
        if AudioStore.localURL(transcript.id) == nil {
            if store.downloading.contains(transcript.id) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(transcript.remoteAudioURL == nil ? "Finding Episode Audio…" : "Downloading Audio…")
                        Spacer()
                        if let fraction = store.downloadProgress[transcript.id] { Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                    }.font(.footnote)
                    ProgressView(value: store.downloadProgress[transcript.id]).tint(Palette.accent).accessibilityLabel("Audio Download")
                    Text("Keep reading or practice with text to speech.").font(.caption).foregroundStyle(.secondary)
                }.downloadCard()
            } else if let error = store.audioErrors[transcript.id] {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Audio Download Failed", systemImage: "exclamationmark.arrow.circlepath").font(.subheadline.weight(.semibold))
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Text("Text to speech is still available.").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry Audio Download", systemImage: "arrow.clockwise") { Task { await store.downloadAudio(transcript) } }.frame(minHeight: 44)
                }.frame(maxWidth: .infinity, alignment: .leading).downloadCard()
            } else if transcript.remoteAudioURL != nil || transcript.sourceURL != nil {
                Button("Download Episode Audio", systemImage: "arrow.down.circle") { Task { await store.downloadAudio(transcript) } }.font(.subheadline).frame(minHeight: 44)
            }
        }
    }
}
