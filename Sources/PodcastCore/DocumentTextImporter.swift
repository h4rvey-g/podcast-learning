import Foundation
import PDFKit

public enum DocumentTextImporter {
    public static func supports(_ url: URL) -> Bool { ["pdf", "doc", "docx"].contains(url.pathExtension.lowercased()) }
    public static func sourceFile(_ id: UUID) throws -> URL {
        let directory = try AudioStore.workDirectory(id)
        for ext in ["pdf", "doc", "docx"] {
            let file = directory.appendingPathComponent("source.\(ext)")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        throw ImportError.service("The original document is missing. Import the file again to start a new session.")
    }
    @MainActor public static func session(from url: URL, level: String? = nil) throws -> Transcript {
        guard supports(url) else { throw ImportError.service("Choose a PDF, DOC, or DOCX document.") }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
        let transcript = Transcript(title: url.deletingPathExtension().lastPathComponent, author: url.pathExtension.lowercased() == "pdf" ? "PDF document" : "Word document")
        transcript.targetLevelOverride = level; transcript.synthesisState = "preparing"
        do {
            let destination = try AudioStore.workDirectory(transcript.id).appendingPathComponent("source.\(url.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: url, to: destination)
            guard (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
        } catch { try? AudioStore.delete(transcript.id); throw error }
        return transcript
    }
    @MainActor public static func applyCleanedPieces(_ pieces: [String], to transcript: Transcript) throws {
        guard transcript.orderedSegments.isEmpty, (transcript.items ?? []).isEmpty else {
            throw ImportError.service("This document session already has text. Retry audio generation without replacing your learning progress.")
        }
        try SpeechText.validatePieces(pieces)
        transcript.segments = TextImporter.makeSegments(pieces)
        transcript.synthesisState = "pending"; transcript.synthesisError = nil
    }
    public static func extract(from url: URL) throws -> String {
        guard supports(url) else { throw ImportError.service("Choose a PDF, DOC, or DOCX document.") }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
        if url.pathExtension.lowercased() != "pdf" {
            do { return try WordTextImporter.extract(from: url) }
            catch is CancellationError { throw CancellationError() }
            catch let error as ImportError { throw error }
            catch { throw WordTextImporter.invalid }
        }
        guard let document = PDFDocument(url: url) else { throw ImportError.service("This PDF could not be opened. Choose a valid PDF file.") }
        guard !document.isLocked else { throw ImportError.service("This PDF is password protected. Unlock it before importing.") }
        var pages: [String] = [], bytes = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            // shortcut: PDFKit extracts embedded text only; add OCR when scanned PDFs are supported.
            guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw ImportError.service("Page \(index + 1) has no selectable text. Scanned PDFs need OCR before importing.")
            }
            bytes += text.utf8.count + 2
            guard bytes <= 5_000_000 else { throw ImportError.tooLarge }
            pages.append(text)
        }
        guard !pages.isEmpty else { throw ImportError.emptyText }
        return pages.joined(separator: "\n\n")
    }
}
