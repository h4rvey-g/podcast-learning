import Foundation
import SwiftData
import Testing
import PDFKit
import CoreText
import CoreGraphics
@testable import PodcastCore

private func pdf(_ pages: [String], to url: URL) throws {
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    for text in pages {
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 500)
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 16, nil)]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        context.endPDFPage()
    }
    context.closePDF()
}

@MainActor @Test func pdfCreatesSavedSessionBeforeCleanupAndPreservesItsIdentityAndSourceForRetry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Learning.pdf")
    try pdf(["Extracted page text."], to: source)
    let transcript = try DocumentTextImporter.session(from: source, level: "C1")
    let id = transcript.id
    defer { try? AudioStore.delete(id) }
    let container = try testContainer(), context = container.mainContext
    context.insert(transcript); try context.save()
    #expect(transcript.title == "Learning" && transcript.author == "PDF document")
    #expect(transcript.synthesisState == "preparing")
    #expect(transcript.orderedSegments.isEmpty && transcript.activeItems.isEmpty)
    try FileManager.default.removeItem(at: source)
    let staged = try DocumentTextImporter.sourceFile(id)
    #expect(try DocumentTextImporter.extract(from: staged) == "Extracted page text.")
    #expect(try staged.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    // A failed cleanup must leave the staged source and saved session intact.
    #expect(throws: ImportError.self) { try DocumentTextImporter.applyCleanedPieces([" \n "], to: transcript) }
    #expect(transcript.synthesisState == "preparing" && transcript.orderedSegments.isEmpty)
    let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<Transcript>()).first)
    #expect(reloaded.id == id && reloaded.synthesisState == "preparing")
    let pieces = ["Cleaned first sentence.\n\nAnother sentence!", "Second paragraph."]
    try DocumentTextImporter.applyCleanedPieces(pieces, to: transcript)
    try context.save()
    #expect(transcript.id == id && transcript.targetLevelOverride == "C1")
    #expect(transcript.synthesisState == "pending")
    #expect(transcript.orderedSegments.map(\.text) == pieces)
    #expect(transcript.sentences.map(\.index) == [0, 1, 2])
    #expect(transcript.sentences.first?.segment?.transcript?.id == id)
    #expect(throws: ImportError.self) { try DocumentTextImporter.applyCleanedPieces(["Replacement"], to: transcript) }
    #expect(FileManager.default.fileExists(atPath: staged.path))
}

@MainActor @Test(arguments: ["txt", "srt", "vtt"])
func textFilesCreateRetryableAutomaticSessionsWithoutModifyingTheSource(ext: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Listening.\(ext.uppercased())")
    let data = ext == "txt" ? Data("First paragraph.\n\nSecond paragraph.".utf8) : try fixture("transcript.\(ext)")
    try data.write(to: source)
    let expected = try TextImporter.paragraphs(String(decoding: data, as: UTF8.self), fileExtension: ext).joined(separator: "\n\n")
    let transcript = try DocumentTextImporter.session(from: source, level: "C1")
    defer { try? AudioStore.delete(transcript.id) }
    #expect(transcript.title == "Listening" && transcript.author == "Text file")
    #expect(transcript.synthesisState == "preparing" && transcript.orderedSegments.isEmpty)
    #expect(try Data(contentsOf: source) == data)
    let container = try testContainer()
    container.mainContext.insert(transcript); try container.mainContext.save()
    try FileManager.default.removeItem(at: source)
    let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<Transcript>()).first)
    #expect(reloaded.targetLevelOverride == "C1" && reloaded.synthesisState == "preparing")
    #expect(try DocumentTextImporter.extract(from: DocumentTextImporter.sourceFile(reloaded.id)) == expected)
    try DocumentTextImporter.applyCleanedPieces(["Cleaned text for generated audio."], to: reloaded)
    #expect(reloaded.synthesisState == "pending" && reloaded.spokenText == "Cleaned text for generated audio.")
}

@MainActor @Test func pastedTextIsSavedForAutomaticCleanupAndRetryBeforeAnyProviderCall() throws {
    let original = "Learning from pasted text.\n\nCafé and 中文 stay intact."
    let transcript = try DocumentTextImporter.session(text: original, title: "  My Paste  ", level: "B1")
    defer { try? AudioStore.delete(transcript.id) }
    let source = try DocumentTextImporter.sourceFile(transcript.id)
    #expect(try String(contentsOf: source, encoding: .utf8) == original)
    #expect(try source.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(transcript.title == "My Paste" && transcript.author == "Pasted text")
    #expect(transcript.synthesisState == "preparing" && transcript.orderedSegments.isEmpty)
    let container = try testContainer()
    container.mainContext.insert(transcript); try container.mainContext.save()
    let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<Transcript>()).first)
    #expect(reloaded.targetLevelOverride == "B1")
    #expect(try DocumentTextImporter.extract(from: DocumentTextImporter.sourceFile(reloaded.id)) == original)
    #expect(throws: ImportError.self) { try DocumentTextImporter.applyCleanedPieces(["  "], to: reloaded) }
    #expect(FileManager.default.fileExists(atPath: source.path))
    try DocumentTextImporter.applyCleanedPieces(["Cleaned paragraph."], to: reloaded)
    #expect(reloaded.synthesisState == "pending" && reloaded.spokenText == "Cleaned paragraph.")
    let untitled = try DocumentTextImporter.session(text: original, title: "  ")
    defer { try? AudioStore.delete(untitled.id) }
    #expect(untitled.title == "Learning from pasted text.")
}

@MainActor @Test func automaticTextImportsRejectEmptyOversizedInvalidAndUnsupportedSources() throws {
    #expect(throws: ImportError.self) { try DocumentTextImporter.session(text: " \n ", title: "Empty") }
    #expect(throws: ImportError.self) { try DocumentTextImporter.session(text: String(repeating: "é", count: 2_500_001), title: "Large") }
    #expect(throws: ImportError.self) { try DocumentTextImporter.session(text: "Some text.", title: "Unknown", fileExtension: "exe") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let invalid = directory.appendingPathComponent("invalid.txt")
    try Data([0xff, 0xfe, 0xff]).write(to: invalid)
    #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: invalid) }
    let folder = directory.appendingPathComponent("folder.txt")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(throws: ImportError.self) { try DocumentTextImporter.session(from: folder) }
    try Data(repeating: 32, count: 5_000_001).write(to: invalid)
    #expect(throws: ImportError.self) { try DocumentTextImporter.session(from: invalid) }
}

@Test func pdfExtractsEmbeddedTextInPageOrderAndRejectsInvalidScannedLockedAndLargeFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("text.pdf")
    try pdf(["First page for learning.", "Second page for listening."], to: source)
    #expect(try DocumentTextImporter.extract(from: source) == "First page for learning.\n\nSecond page for listening.")
    let document = try #require(PDFDocument(url: source))
    let locked = directory.appendingPathComponent("locked.pdf")
    #expect(document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
    #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: locked) }
    let blank = directory.appendingPathComponent("blank.pdf")
    try pdf([""], to: blank)
    #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: blank) }
    let broken = directory.appendingPathComponent("broken.pdf")
    try Data("not a PDF".utf8).write(to: broken)
    #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: broken) }
    try Data(repeating: 32, count: 5_000_001).write(to: broken)
    #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: broken) }
}
