import Foundation
import PDFKit

public enum DocumentTextImporter {
    private static let extensions = ["pdf", "doc", "docx", "txt", "srt", "vtt"]
    public static func supports(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    public static func sourceFile(_ id: UUID) throws -> URL {
        let directory = try AudioStore.workDirectory(id)
        for ext in extensions {
            let file = directory.appendingPathComponent("source.\(ext)")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        throw ImportError.service("The original document is missing. Import the file again to start a new session.")
    }
    @MainActor public static func session(from url: URL, level: String? = nil) throws -> Transcript {
        guard supports(url) else { throw ImportError.service("Choose a PDF, DOC, DOCX, TXT, SRT, or VTT file.") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ImportError.service("Choose a file, not a folder.") }
        guard (values.fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
        let ext = url.pathExtension.lowercased()
        let author = ext == "pdf" ? "PDF document" : ["doc", "docx"].contains(ext) ? "Word document" : "Text file"
        let transcript = Transcript(title: url.deletingPathExtension().lastPathComponent, author: author)
        transcript.targetLevelOverride = level; transcript.synthesisState = "preparing"
        do {
            let destination = try AudioStore.workDirectory(transcript.id).appendingPathComponent("source.\(url.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: url, to: destination)
            guard (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
        } catch { try? AudioStore.delete(transcript.id); throw error }
        return transcript
    }
    @MainActor public static func session(text: String, title: String, fileExtension: String = "txt", level: String? = nil) throws -> Transcript {
        let ext = fileExtension.lowercased()
        guard ["txt", "srt", "vtt"].contains(ext) else { throw ImportError.service("Choose TXT, SRT, or VTT text.") }
        let paragraphs = try TextImporter.paragraphs(text, fileExtension: ext)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = Transcript(title: name.isEmpty ? String(paragraphs[0].prefix(65)) : name, author: "Pasted text")
        transcript.targetLevelOverride = level; transcript.synthesisState = "preparing"
        do {
            let source = try AudioStore.workDirectory(transcript.id).appendingPathComponent("source.\(ext)")
            try Data(text.utf8).write(to: source, options: .atomic)
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
        guard supports(url) else { throw ImportError.service("Choose a PDF, DOC, DOCX, TXT, SRT, or VTT file.") }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
        let ext = url.pathExtension.lowercased()
        if ["txt", "srt", "vtt"].contains(ext) {
            let data = try Data(contentsOf: url)
            guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.service("Choose a UTF-8 text file.") }
            return try TextImporter.paragraphs(text, fileExtension: ext).joined(separator: "\n\n")
        }
        if ext != "pdf" {
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
