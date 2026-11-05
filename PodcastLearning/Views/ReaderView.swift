import SwiftUI
import AVKit
import PodcastCore

private enum ReaderSelection: Identifiable {
    case word(String, Sentence), sentence(Sentence)
    var id: String { switch self { case .word(let word, let sentence): return sentence.id.uuidString + word; case .sentence(let sentence): return sentence.id.uuidString } }
}

struct ReaderView: View {
    @Environment(\.accentTheme) private var theme
    @Bindable var transcript: Transcript
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var player
    @State private var tab = 0
    @State private var selection: ReaderSelection?
    @State private var highlightedItemID: UUID?
    @State private var practice = false
    @State private var showVideo = false
    @State private var confirmSynthesis = false
    @State private var includeMastered = false
    @State private var dictationSession: DictationSession?
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CoverArt(transcript: transcript, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transcript.title).font(.headline).lineLimit(2)
                    Text([transcript.author, transcript.duration.map(timestamp), "\(transcript.activeItems.count) words"].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 16)
            ImportProgressView(transcript: transcript).padding(.horizontal, 20)
            Picker("Content", selection: $tab) { Text("Transcript").tag(0); Text("Items").tag(1) }.pickerStyle(.segmented).padding(.horizontal, 16)
            if tab == 0 {
                if transcript.practiceItems.isEmpty && !transcript.activeItems.isEmpty {
                    Text("Turn on a word source to include it in dictation.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        transcriptionStatus
                        synthesisStatus
                        analysisStatus
                        if let pieces = store.cleanupPreview[transcript.id] {
                            ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Paragraph \(index + 1) · Cleaning text").font(.footnote).foregroundStyle(.secondary)
                                    Text(piece).font(.system(.title3, design: .serif)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        ForEach(transcript.orderedSegments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    player.toggleParagraph(segment, transcript: transcript, settings: settings, readyAudio: store.paragraphAudio[segment.id])
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: player.isActive(segment, in: transcript) ? "pause.fill" : "play.fill")
                                            .font(.caption).frame(width: 28, height: 28)
                                            .foregroundStyle(player.isActive(segment, in: transcript) ? Palette.onAccent : theme.color)
                                            .background(player.isActive(segment, in: transcript) ? theme.color : theme.color.opacity(0.08), in: Circle())
                                        Text(segment.speaker ?? "Paragraph \(segment.index + 1)")
                                        if let start = segment.start { Text(timestamp(start)).monospacedDigit() }
                                    }.font(.footnote).foregroundStyle(.secondary).frame(minHeight: 36)
                                }.buttonStyle(.plain).accessibilityLabel("\(player.isActive(segment, in: transcript) ? "Pause" : "Play") \(segment.speaker ?? "paragraph")")
                                    .disabled(player.isWaitingForAudio(transcript, settings: settings) && store.paragraphAudio[segment.id] == nil)
                                ForEach(segment.orderedSentences) { sentence in
                                    HighlightedText(sentence: sentence, items: transcript.practiceItems) { word in
                                        // A long press already opened the paragraph sheet for this touch.
                                        if selection == nil { selection = .word(word, sentence) }
                                    }
                                        .padding(sentence.isKey && transcript.showKeySentences ? 10 : 0)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(sentence.isKey && transcript.showKeySentences ? Palette.key : .clear, in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(alignment: .leading) { if sentence.isKey && transcript.showKeySentences { Capsule().fill(.yellow).frame(width: 3).accessibilityHidden(true) } }
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
                    Section("Word Sources") {
                        ForEach(ItemSource.allCases, id: \.rawValue) { source in sourceToggle(source) }
                        Toggle("Key Sentence Highlights", isOn: $transcript.showKeySentences)
                    }
                    Toggle("Include Mastered Words", isOn: $includeMastered)
                    if let file = try? AudioStore.videoFile(transcript.id), FileManager.default.fileExists(atPath: file.path) {
                        Button("Play Downloaded Video", systemImage: "video") { player.stop(); showVideo = true }
                    }
                    if transcript.sourceURL == nil && transcript.remoteAudioURL == nil && !transcript.orderedSegments.isEmpty {
                        if settings.speechService == .openRouter && AudioStore.localURL(transcript.id) == nil {
                            Button("Generate Audio", systemImage: "waveform") { confirmSynthesis = true }.disabled(store.synthesizing.contains(transcript.id))
                        }
                        NavigationLink("Speech Settings") { SynthesisSettingsView() }
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
                PrimaryButton(title: dictationTitle, symbol: "pencil.line") { player.stop(); practice = true }
                    .disabled(transcript.practiceItems.isEmpty || player.isWaitingForAudio(transcript, settings: settings))
                    .opacity(transcript.practiceItems.isEmpty || player.isWaitingForAudio(transcript, settings: settings) ? 0.5 : 1)
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
        .confirmationDialog("Generate AI Audio?", isPresented: $confirmSynthesis, titleVisibility: .visible) {
            Button("Generate Audio") { player.stop(); store.synthesize(transcript) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Send \(transcript.spokenText.count.formatted()) characters to OpenRouter using \(settings.ttsModel) · \(settings.ttsVoice). Charges may apply. Keep PodLearn open. Completed parts are reused on retry; a lost response may be billed again.")
        }
        .onChange(of: transcript.excludedSources) { _, _ in loadDictationSession(); store.save() }
        .onChange(of: transcript.showKeySentences) { _, _ in store.save() }
        .fullScreenCover(isPresented: $practice, onDismiss: loadDictationSession) { DictationView(transcript: transcript, includeMastered: includeMastered) }
        .task { loadDictationSession() }
        .onDisappear { player.stop(); store.save() }
    }
    private var dictationTitle: String {
        guard let session = dictationSession, session.answeredCount > 0, !session.isFinished else { return "Start Dictation" }
        return "Continue Dictation (\(session.answeredCount)/\(session.wordCount))"
    }
    private func sourceToggle(_ source: ItemSource) -> some View {
        Toggle(source.label + " Words", isOn: Binding(get: { !transcript.excludedSources.contains(source.rawValue) }, set: { isOn in
            transcript.excludedSources.removeAll { $0 == source.rawValue }
            if !isOn { transcript.excludedSources.append(source.rawValue) }
        })).accessibilityHint("Show highlights and include these words in dictation")
    }
    private func loadDictationSession() {
        dictationSession = DictationSessionStore.load(for: transcript.id)?.filtered(to: Set(transcript.practiceItems.map(\.id)))
    }
    @ViewBuilder private var transcriptionStatus: some View {
        if transcript.transcriptionState == "pending" {
            Text("Keep PodLearn open. Temporary network failures retry automatically; downloaded audio and completed results are kept for retry.")
                .font(.footnote).foregroundStyle(.secondary)
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
    @ViewBuilder private var synthesisStatus: some View {
        if ["preparing", "pending"].contains(transcript.synthesisState) {
            Text("Your session is saved. Keep PodLearn open. Cleaned paragraphs appear as AI returns them. Each paragraph becomes playable as its audio arrives.")
                .font(.footnote).foregroundStyle(.secondary)
        } else if transcript.synthesisState == "preparationFailed" {
            VStack(alignment: .leading, spacing: 8) {
                Label("Document Processing Interrupted", systemImage: "exclamationmark.arrow.circlepath").font(.headline)
                Text(transcript.synthesisError ?? "The original document is kept for retry.").font(.footnote).foregroundStyle(.secondary)
                Text("Retry sends text to your configured providers and may incur charges.").font(.footnote).foregroundStyle(.secondary)
                Button("Retry Document Processing", systemImage: "arrow.clockwise") { store.synthesize(transcript) }.frame(minHeight: 44)
                NavigationLink("AI Settings") { SettingsView() }.frame(minHeight: 44)
                NavigationLink("Speech Settings") { SynthesisSettingsView() }.frame(minHeight: 44)
            }
        } else if transcript.synthesisState == "failed" {
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio Generation Interrupted", systemImage: "exclamationmark.arrow.circlepath").font(.headline)
                Text(transcript.synthesisError ?? "Completed parts are kept.").font(.footnote).foregroundStyle(.secondary)
                Button("Retry Audio Generation", systemImage: "arrow.clockwise") { confirmSynthesis = true }.frame(minHeight: 44)
                NavigationLink("Speech Settings") { SynthesisSettingsView() }.frame(minHeight: 44)
            }
        } else if transcript.synthesisState == "done", AudioStore.localURL(transcript.id) != nil {
            Label("AI-generated audio · Saved for offline playback", systemImage: "waveform").font(.footnote).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var analysisStatus: some View {
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
    var body: some View {
        HStack(spacing: 4) {
            Button("Back 15 Seconds", systemImage: "gobackward.15") { player.skip(-15) }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(AudioStore.localURL(transcript.id) == nil)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle(text: transcript.spokenText, transcript: transcript, settings: settings)
            }.labelStyle(.iconOnly).frame(width: 44, height: 44).foregroundStyle(Palette.cell).background(.primary, in: Circle())
                .disabled(player.isWaitingForAudio(transcript, settings: settings))
                .opacity(player.isWaitingForAudio(transcript, settings: settings) ? 0.5 : 1)
            Button("Forward 15 Seconds", systemImage: "goforward.15") { player.skip(15) }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(AudioStore.localURL(transcript.id) == nil)
            VStack(spacing: 3) {
                if AudioStore.localURL(transcript.id) != nil {
                    ProgressView(value: min(player.position, player.duration), total: max(1, player.duration)).tint(.primary)
                    HStack { Text(timestamp(player.position)); Spacer(); Text("−" + timestamp(max(0, player.duration - player.position))) }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(player.isWaitingForAudio(transcript, settings: settings) ? (["failed", "preparationFailed"].contains(transcript.synthesisState) ? "AI audio unavailable · Retry above" : "Waiting for AI audio…") : settings.speechService == .openRouter ? "OpenRouter Text to Speech" : "Apple Text to Speech")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        if AudioStore.localURL(transcript.id) == nil && !store.downloading.contains(transcript.id) {
            if let error = store.audioErrors[transcript.id] {
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
