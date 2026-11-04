import Foundation
import Testing
import ZIPFoundation
@testable import PodcastCore

private let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private let sampleText = "Learning from documents.\nA café — “quoted” text and 中文.\n\nSecond paragraph for listening."
private func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func docx(_ xml: String, at url: URL, path: String = "word/document.xml", compression: CompressionMethod = .deflate) throws {
    let data = Data(xml.utf8), archive = try Archive(url: url, accessMode: .create)
    try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: compression) { position, size in
        data.subdata(in: Int(position)..<Int(position) + size)
    }
}

@MainActor @Test(arguments: ["doc", "docx"])
func wordDocumentsExtractUnicodeAndCreateTheSameRetryableSession(ext: String) throws {
    let source = try #require(Bundle.module.url(forResource: "word-sample", withExtension: ext, subdirectory: "Fixtures"))
    #expect(normalized(try DocumentTextImporter.extract(from: source)) == normalized(sampleText))
    let transcript = try DocumentTextImporter.session(from: source, level: "B2")
    defer { try? AudioStore.delete(transcript.id) }
    #expect(transcript.author == "Word document" && transcript.synthesisState == "preparing")
    let staged = try DocumentTextImporter.sourceFile(transcript.id)
    #expect(staged.pathExtension == ext)
    #expect(normalized(try DocumentTextImporter.extract(from: staged)) == normalized(sampleText))
    try DocumentTextImporter.applyCleanedPieces(["Cleaned document."], to: transcript)
    #expect(transcript.spokenText == "Cleaned document." && transcript.synthesisState == "pending")
    try AudioStore.delete(transcript.id)
    #expect(throws: ImportError.self) { try DocumentTextImporter.sourceFile(transcript.id) }
    #expect(DocumentTextImporter.supports(URL(fileURLWithPath: "UPPERCASE.\(ext.uppercased())")))
    #expect(!DocumentTextImporter.supports(URL(fileURLWithPath: "unsupported.xlsx")))
}

@Test func docxPreservesRunsParagraphsTablesAndVisibleFieldResults() throws {
    let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
    for ns in [wordNamespace, "http://purl.oclc.org/ooxml/wordprocessingml/main"] {
        let file = directory.appendingPathComponent(UUID().uuidString + ".docx")
        try docx("""
            <w:document xmlns:w="\(ns)"><w:body>
            <w:p><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:t>world &amp; 中文.</w:t><w:tab/><w:t>Next</w:t><w:br/><w:t>line.</w:t></w:r></w:p>
            <w:p><w:r><w:instrText>HYPERLINK private-instruction</w:instrText><w:t>Visible link</w:t></w:r><w:del><w:r><w:delText>deleted</w:delText></w:r></w:del></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell one.</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cell two.</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            </w:body></w:document>
            """, at: file)
        let text = try DocumentTextImporter.extract(from: file)
        #expect(normalized(text) == "Hello world & 中文. Next line. Visible link Cell one. Cell two.")
        #expect(text.contains("\n\n"))
        #expect(!text.contains("private-instruction") && !text.contains("deleted"))
    }
}

@Test func docxRejectsMalformedEmptyEntityExpandedOversizedAndCorruptedDocuments() throws {
    let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = "<w:document xmlns:w=\"\(wordNamespace)\"><w:body><w:p><w:r><w:t>"
    let end = "</w:t></w:r></w:p></w:body></w:document>"
    for xml in ["not XML", start + "broken", start + end,
                "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]>" + start + "&secret;" + end,
                "<!DOCTYPE x [<!ENTITY a 'expanded'>]>" + start + "&a;" + end,
                start + String(repeating: "x", count: 5_000_001) + end] {
        let file = directory.appendingPathComponent(UUID().uuidString + ".docx")
        try docx(xml, at: file)
        #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: file) }
    }
    let missing = directory.appendingPathComponent("missing.docx")
    try docx(start + "text" + end, at: missing, path: "other.xml")
    #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: missing) }
    let corrupt = directory.appendingPathComponent("corrupt.docx")
    try docx(start + "CHECKSUM-SENTINEL" + end, at: corrupt, compression: .none)
    var bytes = try Data(contentsOf: corrupt)
    let range = try #require(bytes.range(of: Data("CHECKSUM-SENTINEL".utf8)))
    bytes[range.lowerBound] ^= 1
    try bytes.write(to: corrupt)
    #expect(throws: ImportError.self) { try DocumentTextImporter.extract(from: corrupt) }
    let protected = directory.appendingPathComponent("protected.docx")
    try Data([0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1]).write(to: protected)
    do { _ = try DocumentTextImporter.extract(from: protected); Issue.record("Encrypted DOCX must fail") }
    catch { #expect(error.localizedDescription.contains("password protected")) }
}

private func set(_ value: Int, in data: inout Data, at offset: Int, width: Int = 4) {
    for index in 0..<width { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
}
private func int(_ data: Data, at offset: Int) -> Int {
    (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
}
private func binaryStreams() -> (word: Data, table: Data) {
    // Encode the compressed piece directly so the MS-DOC 0x93/0x94 mapping is tested.
    let ascii = [UInt8]("First \u{13}HYPERLINK ignored\u{14}visible\u{15} ".utf8) + [0x93] + [UInt8]("quoted".utf8) + [0x94, 46, 13]
    let second = "中文 and emoji 👋.\r", unicode = second.data(using: .utf16LittleEndian)!
    var word = Data(repeating: 0, count: 1024)
    set(0xa5ec, in: &word, at: 0, width: 2); set(0xc1, in: &word, at: 2, width: 2)
    set(14, in: &word, at: 32, width: 2); set(22, in: &word, at: 62, width: 2)
    set(ascii.count + second.utf16.count, in: &word, at: 76)
    set(93, in: &word, at: 152, width: 2)
    let secondAddress = word.count; word.append(unicode)
    let firstAddress = word.count; word.append(contentsOf: ascii)
    var plc = Data(repeating: 0, count: 28)
    set(ascii.count, in: &plc, at: 4); set(ascii.count + second.utf16.count, in: &plc, at: 8)
    set(0x40000000 | firstAddress * 2, in: &plc, at: 14)
    set(secondAddress, in: &plc, at: 22)
    var table = Data([1, 1, 0, 0xaa, 2, 28, 0, 0, 0]); table.append(plc)
    set(0, in: &word, at: 418); set(table.count, in: &word, at: 422)
    return (word, table)
}

@Test func binaryWordUsesLogicalPieceOrderAndRemovesFieldInstructions() throws {
    let streams = binaryStreams()
    let text = try LegacyWordDocument.text(document: streams.word, table: streams.table)
    #expect(normalized(text) == "First visible “quoted”. 中文 and emoji 👋.")
    #expect(!text.contains("HYPERLINK") && text.contains("\n\n"))
    var damaged = streams.table
    set(0xffffffff, in: &damaged, at: 23)
    #expect(throws: ImportError.self) { try LegacyWordDocument.text(document: streams.word, table: damaged) }
    var invalidUnicode = streams.word
    invalidUnicode[1024] = 0; invalidUnicode[1025] = 0xd8
    #expect(throws: ImportError.self) { try LegacyWordDocument.text(document: invalidUnicode, table: streams.table) }
}

@Test func binaryWordRejectsEncryptionTruncationFatCyclesAndMaliciousHeaderCounts() throws {
    let source = try fixture("word-sample.doc")
    for length in [0, 1, 100, 511, 512, 1000] {
        #expect(throws: ImportError.self) { try LegacyWordDocument.extract(Data(source.prefix(length))) }
    }
    let magic = try #require(source.range(of: Data([0xec, 0xa5, 0xc1, 0])))
    var encrypted = source; encrypted[magic.lowerBound + 11] |= 1
    do { _ = try LegacyWordDocument.extract(encrypted); Issue.record("Encrypted DOC must fail") }
    catch { #expect(error.localizedDescription.contains("password protected")) }
    var cyclic = source
    let fat = int(source, at: 76), directory = int(source, at: 48)
    set(directory, in: &cyclic, at: (fat + 1) * 512 + directory * 4)
    #expect(throws: ImportError.self) { try LegacyWordDocument.extract(cyclic) }
    for (offset, value, width) in [(72, 0x7fffffff, 4), (30, 65535, 2), (44, 0x7fffffff, 4)] {
        var damaged = source; set(value, in: &damaged, at: offset, width: width)
        #expect(throws: ImportError.self) { try LegacyWordDocument.extract(damaged) }
    }
}
