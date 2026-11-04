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
