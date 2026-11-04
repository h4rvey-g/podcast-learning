import Foundation

// Bounds-checked little-endian reads shared by the CFB container and MS-DOC piece table.
private struct WordBytes {
    let data: Data
    func int(_ offset: Int, _ width: Int = 4) throws -> Int {
        guard width > 0, width <= 8, offset >= 0, offset <= data.count, width <= data.count - offset else { throw WordTextImporter.invalid }
        var value: UInt64 = 0
        for index in 0..<width { value |= UInt64(data[data.startIndex + offset + index]) << (index * 8) }
        guard value <= Int.max else { throw WordTextImporter.invalid }
        return Int(value)
    }
    func slice(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { throw WordTextImporter.invalid }
        return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
    }
}

// Read-only CFB v3/v4; the 5 MB import limit fits the header's 109 inline FAT-sector slots.
private struct CompoundWordFile {
    let source: WordBytes
    let sectorSize: Int
    let fat: [Int]
    let miniFAT: [Int]
    let miniStream: Data
    let entries: [String: WordBytes]
    private static let end = 0xfffffffe
    private static let absent = 0xffffffff

    init(_ data: Data) throws {
        let source = WordBytes(data: data)
        guard try source.slice(0, 8) == Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]),
              try source.int(28, 2) == 0xfffe else { throw WordTextImporter.invalid }
        let version = try source.int(26, 2), shift = try source.int(30, 2)
        guard (version == 3 && shift == 9) || (version == 4 && shift == 12),
              try source.int(32, 2) == 6, try source.int(56) == 4096,
              try source.int(72) == 0 else { throw WordTextImporter.invalid }
        let sectorSize = 1 << shift
        guard data.count % sectorSize == 0 else { throw WordTextImporter.invalid }
        let fatCount = try source.int(44)
        guard fatCount > 0, fatCount <= 109, fatCount < data.count / sectorSize else { throw WordTextImporter.invalid }
        var fat: [Int] = []
        for index in 0..<fatCount {
            let id = try source.int(76 + index * 4)
            let sector = WordBytes(data: try source.slice((id + 1) * sectorSize, sectorSize))
            for offset in stride(from: 0, to: sectorSize, by: 4) { fat.append(try sector.int(offset)) }
        }
        let directory = try Self.chain(try source.int(48), table: fat, source: data, size: sectorSize, header: 1)
        guard directory.count >= 128 else { throw WordTextImporter.invalid }
        let records = stride(from: 0, to: directory.count, by: 128).map { WordBytes(data: directory.subdata(in: $0..<$0 + 128)) }
        let root = records[0]
        guard try root.int(66, 1) == 5 else { throw WordTextImporter.invalid }
        let rootSize = try root.int(120, 8)
        guard rootSize <= WordTextImporter.limit else { throw ImportError.tooLarge }
        let rootData = rootSize == 0 ? Data() : try Self.chain(try root.int(116), table: fat, source: data, size: sectorSize, header: 1)
        guard rootData.count >= rootSize else { throw WordTextImporter.invalid }
        let miniCount = try source.int(64)
        guard miniCount <= data.count / sectorSize else { throw WordTextImporter.invalid }
        let miniData = miniCount == 0 ? Data() : try Self.chain(try source.int(60), table: fat, source: data, size: sectorSize, header: 1)
        guard miniData.count >= miniCount * sectorSize else { throw WordTextImporter.invalid }
        let miniBytes = WordBytes(data: miniData)
        let miniFAT = try stride(from: 0, to: miniCount * sectorSize, by: 4).map { try miniBytes.int($0) }
        var stack = [try root.int(76)], seen = Set<Int>(), entries: [String: WordBytes] = [:]
        while let id = stack.popLast() {
            try Task.checkCancellation()
            if id == Self.absent { continue }
            guard id < records.count, seen.insert(id).inserted else { throw WordTextImporter.invalid }
            let entry = records[id], kind = try entry.int(66, 1)
            guard kind == 1 || kind == 2 else { throw WordTextImporter.invalid }
            stack += [try entry.int(68), try entry.int(72)]
            if kind == 2 {
                let length = try entry.int(64, 2)
                guard length >= 2, length <= 64, length % 2 == 0,
                      let name = String(data: try entry.slice(0, length - 2), encoding: .utf16LittleEndian)?.lowercased(),
                      entries[name] == nil else { throw WordTextImporter.invalid }
                entries[name] = entry
            }
        }
        self.source = source; self.sectorSize = sectorSize; self.fat = fat
        self.miniFAT = miniFAT; self.miniStream = Data(rootData.prefix(rootSize)); self.entries = entries
    }
    func stream(_ name: String) throws -> Data {
        guard let entry = entries[name.lowercased()] else { throw WordTextImporter.invalid }
        let count = try entry.int(120, 8)
        guard count <= WordTextImporter.limit else { throw ImportError.tooLarge }
        if count == 0 { return Data() }
        let small = count < 4096
        let data = try Self.chain(try entry.int(116), table: small ? miniFAT : fat,
            source: small ? miniStream : source.data, size: small ? 64 : sectorSize, header: small ? 0 : 1)
        guard data.count >= count else { throw WordTextImporter.invalid }
        return Data(data.prefix(count))
    }
    private static func chain(_ start: Int, table: [Int], source: Data, size: Int, header: Int) throws -> Data {
        var next = start, seen = Set<Int>(), result = Data()
        let bytes = WordBytes(data: source)
        while next != end {
            try Task.checkCancellation()
            guard next < table.count, seen.insert(next).inserted else { throw WordTextImporter.invalid }
            guard result.count + size <= WordTextImporter.limit else { throw ImportError.tooLarge }
            result.append(try bytes.slice((next + header) * size, size))
            next = table[next]
        }
        return result
    }
}

enum LegacyWordDocument {
    static func extract(_ data: Data) throws -> String {
        guard data.count <= WordTextImporter.limit else { throw ImportError.tooLarge }
        let compound = try CompoundWordFile(data)
        if compound.entries["encryptedpackage"] != nil { throw WordTextImporter.protected }
        let document = try compound.stream("WordDocument"), word = WordBytes(data: document)
        let flags = try word.int(10, 2)
        guard flags & 0x100 == 0 else { throw WordTextImporter.protected }
        return try text(document: document, table: compound.stream(flags & 0x200 == 0 ? "0Table" : "1Table"))
    }
    // MS-DOC §2.4.1: FIB → CLX → PlcPcd → physical text pieces, in logical CP order.
    static func text(document: Data, table: Data) throws -> String {
        let word = WordBytes(data: document)
        guard try word.int(0, 2) == 0xa5ec, try word.int(2, 2) >= 0xc1 else { throw WordTextImporter.invalid }
        let longCountOffset = 34 + (try word.int(32, 2)) * 2
        let longStart = longCountOffset + 2, longCount = try word.int(longCountOffset, 2)
        guard longCount >= 4 else { throw WordTextImporter.invalid }
        let characters = try word.int(longStart + 12)
        guard characters <= WordTextImporter.limit else { throw ImportError.tooLarge }
        let pairs = longStart + longCount * 4
        guard try word.int(pairs, 2) >= 34 else { throw WordTextImporter.invalid }
        let clxPair = pairs + 2 + 33 * 8
        let clx = WordBytes(data: try WordBytes(data: table).slice(try word.int(clxPair), try word.int(clxPair + 4)))
        var offset = 0
        while try clx.int(offset, 1) == 1 { offset += 3 + (try clx.int(offset + 1, 2)) }
        guard try clx.int(offset, 1) == 2 else { throw WordTextImporter.invalid }
        let size = try clx.int(offset + 1)
        guard size >= 4, (size - 4) % 12 == 0, offset + 5 + size == clx.data.count else { throw WordTextImporter.invalid }
        let pieces = WordBytes(data: try clx.slice(offset + 5, size)), count = (size - 4) / 12
        guard try pieces.int(0) == 0 else { throw WordTextImporter.invalid }
        var units: [UInt16] = []
        let extended: [UInt16] = [0x80,0x81,0x201a,0x192,0x201e,0x2026,0x2020,0x2021,0x2c6,0x2030,0x160,0x2039,0x152,0x8d,0x8e,0x8f,
                                  0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x2dc,0x2122,0x161,0x203a,0x153,0x9d,0x9e,0x178]
        for index in 0..<count {
            try Task.checkCancellation()
            let start = try pieces.int(index * 4), end = try pieces.int((index + 1) * 4)
            guard end >= start, end <= Int32.max else { throw WordTextImporter.invalid }
            if start >= characters { break }
            let length = min(end, characters) - start
            let fc = try pieces.int((count + 1) * 4 + index * 8 + 2)
            let compressed = fc & 0x40000000 != 0, address = fc & 0x3fffffff
            let raw = try word.slice(compressed ? address / 2 : address, length * (compressed ? 1 : 2))
            if compressed {
                units += raw.map { $0 >= 0x80 && $0 <= 0x9f ? extended[Int($0) - 0x80] : UInt16($0) }
            } else {
                for byte in stride(from: raw.startIndex, to: raw.endIndex, by: 2) {
                    units.append(UInt16(raw[byte]) | UInt16(raw[byte + 1]) << 8)
                }
            }
        }
        guard units.count == characters else { throw WordTextImporter.invalid }
        var visible: [UInt16] = [], fields: [Bool] = [], hidden = 0
        for unit in units {
            switch unit {
            case 0x13: fields.append(false); hidden += 1
            case 0x14:
                guard let shown = fields.last else { throw WordTextImporter.invalid }
                if !shown { fields[fields.count - 1] = true; hidden -= 1 }
            case 0x15:
                guard let shown = fields.popLast() else { throw WordTextImporter.invalid }
                if !shown { hidden -= 1 }
            default:
                guard hidden == 0 else { continue }
                switch unit {
                case 0x0d: visible += [10, 10]
                case 0x0b, 0x0c: visible.append(10)
                case 0x07, 0x09: visible.append(9)
                case 0x1e: visible.append(45)
                case 0x20...0xffff: visible.append(unit)
                default: break
                }
            }
        }
        guard fields.isEmpty else { throw WordTextImporter.invalid }
        var utf16 = Data(capacity: visible.count * 2)
        for unit in visible {
            utf16.append(UInt8(truncatingIfNeeded: unit)); utf16.append(UInt8(unit >> 8))
        }
        guard let text = String(data: utf16, encoding: .utf16LittleEndian) else { throw WordTextImporter.invalid }
        return text
    }
}
