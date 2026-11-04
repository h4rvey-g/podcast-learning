import Foundation
import ZIPFoundation

// shortcut: narrate main-body text only (DOC revisions unresolved); add note/revision support when needed.
enum WordTextImporter {
    static let invalid = ImportError.service("This Word document is damaged or unsupported. Open it in Word and save a new DOCX copy.")
    static let protected = ImportError.service("This Word document is password protected. Save an unprotected copy before importing.")
    static let limit = 5_000_000

    static func extract(from url: URL) throws -> String {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw ImportError.tooLarge }
        let text: String
        if url.pathExtension.lowercased() == "doc" {
            text = try LegacyWordDocument.extract(Data(contentsOf: url))
        } else {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if try handle.read(upToCount: 8) == Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) { throw protected }
            let archive = try Archive(url: url, accessMode: .read)
            let entries = archive.filter { $0.path == "word/document.xml" }
            guard entries.count == 1, let entry = entries.first, entry.type == .file else { throw invalid }
            guard entry.uncompressedSize <= limit else { throw ImportError.tooLarge }
            var xml = Data()
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard xml.count + chunk.count <= limit else { throw ImportError.tooLarge }
                xml.append(chunk)
            }
            guard checksum == entry.checksum else { throw invalid }
            let reader = WordXMLReader(), parser = XMLParser(data: xml)
            parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = reader
            guard parser.parse(), reader.failure == nil else { throw reader.failure ?? invalid }
            text = reader.text
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.utf8.count <= limit else { throw ImportError.tooLarge }
        guard !result.isEmpty else { throw ImportError.service("No readable text was found in this Word document. Image-only documents need OCR first.") }
        return result
    }
}

private final class WordXMLReader: NSObject, XMLParserDelegate {
    var text = ""
    var failure: Error?
    private var inBody = false, inText = false, skippedDepth = 0, bytes = 0
    private let namespaces = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main", "http://purl.oclc.org/ooxml/wordprocessingml/main"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if skippedDepth > 0 { skippedDepth += 1; return }
        guard namespaces.contains(namespaceURI ?? "") else { return }
        if name == "body" { inBody = true }
        guard inBody else { return }
        switch name {
        case "del", "moveFrom": skippedDepth = 1
        case "t": inText = true
        case "tab": append("\t", parser)
        case "br", "cr": append("\n", parser)
        case "noBreakHyphen": append("-", parser)
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skippedDepth > 0 { skippedDepth -= 1; return }
        guard namespaces.contains(namespaceURI ?? ""), inBody else { return }
        switch name {
        case "t": inText = false
        case "p": append("\n\n", parser)
        case "tc": append("\t", parser)
        case "tr": append("\n", parser)
        case "body": inBody = false
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { append(string, parser) } }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if inText {
            guard let string = String(data: data, encoding: .utf8) else { failure = WordTextImporter.invalid; parser.abortParsing(); return }
            append(string, parser)
        }
    }
    private func append(_ string: String, _ parser: XMLParser) {
        do {
            try Task.checkCancellation()
            bytes += string.utf8.count
            guard bytes <= WordTextImporter.limit else { throw ImportError.tooLarge }
            text += string
        } catch { failure = error; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { rejectEntity(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { rejectEntity(parser) }
    private func rejectEntity(_ parser: XMLParser) { failure = WordTextImporter.invalid; parser.abortParsing() }
}
