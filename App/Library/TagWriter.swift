import Foundation

/// The tags Edit Info can change.
enum TagField: String, CaseIterable, Hashable, Sendable {
    case title, artist, albumArtist, album, track, disc, year

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .albumArtist: return "Album Artist"
        case .album: return "Album"
        case .track: return "Track"
        case .disc: return "Disc"
        case .year: return "Year"
        }
    }

    var isNumber: Bool { self == .track || self == .disc || self == .year }

    /// The track's current value, as the editor shows it.
    func value(of track: Track) -> String {
        switch self {
        case .title: return track.title
        case .artist: return track.artist == "Unknown Artist" ? "" : track.artist
        case .albumArtist: return track.albumArtist ?? ""
        case .album: return track.album ?? ""
        case .track: return track.trackNumber.map(String.init) ?? ""
        case .disc: return track.discNumber.map(String.init) ?? ""
        case .year: return track.year.map(String.init) ?? ""
        }
    }
}

/// New values for some tags; an empty string removes that tag. Tags not listed are left alone.
typealias TagChanges = [TagField: String]

enum TagWriteError: LocalizedError {
    case unsupported(String)
    case unreadable
    case checkFailed

    var errorDescription: String? {
        switch self {
        case let .unsupported(what): return "Can't edit \(what) files."
        case .unreadable: return "Couldn't read the file's tags."
        case .checkFailed: return "The edited file didn't check out, so the original was kept."
        }
    }
}

/// Writes tags into the music files themselves (FLAC, MP3 and M4A), so the changes travel with
/// the file: other players, backups and Soulseek all see them.
///
/// The edit is made on a copy. The copy is read back and checked (the new tags are there, the
/// length is unchanged) before it replaces the original, so a failed edit never damages a song.
/// The file keeps its date, so an edited song doesn't jump to the top of Recently Added.
enum TagWriter {
    private enum Format { case flac, mp3, mp4 }

    private static func format(of url: URL) -> Format? {
        switch url.pathExtension.lowercased() {
        case "flac": return .flac
        case "mp3": return .mp3
        case "m4a", "m4b", "mp4", "alac": return .mp4
        default: return nil
        }
    }

    static func canEdit(_ url: URL) -> Bool { format(of: url) != nil }

    static func write(_ changes: TagChanges, to url: URL) async throws {
        guard !changes.isEmpty else { return }
        guard let format = format(of: url) else { throw TagWriteError.unsupported(url.pathExtension.uppercased()) }
        let fileManager = FileManager.default
        let date = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let before = await MetadataReader.read(url: url)

        let folder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent)

        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .flac: try FLACTagWriter.write(changes, from: url, to: copy)
            case .mp3: try ID3TagWriter.write(changes, from: url, to: copy)
            case .mp4: try MP4TagWriter.write(changes, from: url, to: copy)
            }
        }.value

        let after = await MetadataReader.read(url: copy)
        guard check(after, has: changes), before.duration <= 0 || abs(after.duration - before.duration) < 1 else {
            throw TagWriteError.checkFailed
        }
        _ = try fileManager.replaceItemAt(url, withItemAt: copy)
        if let date { try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    /// Whether the file now reads back with the new values (removed tags aren't checked: the
    /// reader falls back to the file name for a missing title).
    static func check(_ info: TrackInfo, has changes: TagChanges) -> Bool {
        for (field, value) in changes {
            let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty else { continue }
            switch field {
            case .title: if info.title != wanted { return false }
            case .artist: if info.artist != wanted { return false }
            case .albumArtist: if info.albumArtist != wanted { return false }
            case .album: if info.album != wanted { return false }
            case .track: if info.trackNumber != Int(wanted) { return false }
            case .disc: if info.discNumber != Int(wanted) { return false }
            case .year: if info.year != Int(wanted) { return false }
            }
        }
        return true
    }

    /// "7" written over "3/12" keeps the total: "7/12".
    static func keepingTotal(_ new: String, old: String?) -> String {
        guard !new.isEmpty, let old, let slash = old.firstIndex(of: "/") else { return new }
        return new + old[slash...]
    }

    // MARK: File helpers

    static func makeOutput(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw TagWriteError.unreadable }
        return try FileHandle(forWritingTo: url)
    }

    /// Copies `input` from `offset` to its end (or `length` bytes) into `output`, a megabyte at a time.
    static func copy(_ input: FileHandle, from offset: UInt64, length: UInt64? = nil, to output: FileHandle) throws {
        try input.seek(toOffset: offset)
        var remaining = length ?? .max
        while remaining > 0 {
            let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        if let length, remaining > 0 { throw TagWriteError.unreadable }
    }

    static func be32(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func readBE32(_ bytes: [UInt8], _ at: Int) -> Int {
        Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
    }
}

// MARK: - FLAC

/// Rewrites the Vorbis comment block. Other blocks (cover art, seek table…) are kept as they
/// are; the padding block shrinks or grows to make room, as taggers do.
enum FLACTagWriter {
    private static let keys: [TagField: [String]] = [
        .title: ["TITLE"], .artist: ["ARTIST"], .albumArtist: ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"],
        .album: ["ALBUM"], .track: ["TRACKNUMBER"], .disc: ["DISCNUMBER"], .year: ["DATE", "YEAR"],
    ]
    private static let newKey: [TagField: String] = [
        .title: "TITLE", .artist: "ARTIST", .albumArtist: "ALBUMARTIST", .album: "ALBUM",
        .track: "TRACKNUMBER", .disc: "DISCNUMBER", .year: "DATE",
    ]

    static func write(_ changes: TagChanges, from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == Data("fLaC".utf8) else { throw TagWriteError.unsupported("this FLAC") }

        var blocks: [(type: UInt8, data: [UInt8])] = []
        while true {
            guard let header = try input.read(upToCount: 4), header.count == 4 else { throw TagWriteError.unreadable }
            let bytes = [UInt8](header)
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            let data = length > 0 ? [UInt8](try input.read(upToCount: length) ?? Data()) : []
            guard data.count == length, bytes[0] & 0x7F != 127 else { throw TagWriteError.unreadable }
            blocks.append((bytes[0] & 0x7F, data))
            if bytes[0] & 0x80 != 0 { break }
            guard blocks.count < 1000 else { throw TagWriteError.unreadable }
        }
        let audioStart = try input.offset()
        guard blocks.first?.type == 0 else { throw TagWriteError.unreadable }

        // The existing comments, minus the ones being replaced.
        var vendor = [UInt8]("colon3o".utf8)
        var comments: [[UInt8]] = []
        let commentIndex = blocks.firstIndex { $0.type == 4 }
        if let commentIndex {
            guard let parsed = parse(blocks[commentIndex].data) else { throw TagWriteError.unreadable }
            vendor = parsed.vendor
            comments = parsed.comments
        }
        func value(_ key: String) -> String? {
            comments.lazy.compactMap { comment -> String? in
                let text = String(decoding: comment, as: UTF8.self)
                guard let equals = text.firstIndex(of: "="), text[..<equals].uppercased() == key else { return nil }
                return String(text[text.index(after: equals)...])
            }.first
        }
        var added: [[UInt8]] = []
        for field in TagField.allCases {
            guard let raw = changes[field] else { continue }
            var new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if field == .track || field == .disc { new = TagWriter.keepingTotal(new, old: value(newKey[field]!)) }
            let doomed = Set(keys[field]!)
            comments.removeAll { comment in
                let text = String(decoding: comment, as: UTF8.self)
                guard let equals = text.firstIndex(of: "=") else { return false }
                return doomed.contains(text[..<equals].uppercased())
            }
            if !new.isEmpty { added.append([UInt8]("\(newKey[field]!)=\(new)".utf8)) }
        }
        comments += added

        var block = le32(vendor.count) + vendor + le32(comments.count)
        for comment in comments { block += le32(comment.count) + comment }
        guard block.count < 1 << 24 else { throw TagWriteError.unreadable }

        let grown = block.count - (commentIndex.map { blocks[$0].data.count } ?? -4)
        if let commentIndex {
            blocks[commentIndex].data = block
        } else {
            blocks.insert((4, block), at: 1)
        }
        // Let the padding absorb the change, so the audio stays where it was when it can.
        if let padding = blocks.firstIndex(where: { $0.type == 1 }), blocks[padding].data.count - grown >= 0 {
            blocks[padding].data = [UInt8](repeating: 0, count: blocks[padding].data.count - grown)
        }

        let output = try TagWriter.makeOutput(destination)
        defer { try? output.close() }
        var head = [UInt8]("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            let last: UInt8 = index == blocks.count - 1 ? 0x80 : 0
            let length = block.data.count
            head += [last | block.type, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
            head += block.data
        }
        try output.write(contentsOf: Data(head))
        try TagWriter.copy(input, from: audioStart, to: output)
    }

    private static func parse(_ block: [UInt8]) -> (vendor: [UInt8], comments: [[UInt8]])? {
        var offset = 0
        func u32() -> Int? {
            guard offset + 4 <= block.count else { return nil }
            let value = Int(block[offset]) | Int(block[offset + 1]) << 8 | Int(block[offset + 2]) << 16 | Int(block[offset + 3]) << 24
            offset += 4
            return value
        }
        guard let vendorLength = u32(), offset + vendorLength <= block.count else { return nil }
        let vendor = Array(block[offset..<(offset + vendorLength)])
        offset += vendorLength
        guard let count = u32() else { return nil }
        var comments: [[UInt8]] = []
        for _ in 0..<count {
            guard let length = u32(), offset + length <= block.count else { return nil }
            comments.append(Array(block[offset..<(offset + length)]))
            offset += length
        }
        return (vendor, comments)
    }

    private static func le32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }
}

// MARK: - MP3 (ID3v2)

/// Rewrites the ID3v2 tag at the start of the file, keeping every frame it doesn't change
/// (cover art, lyrics…) byte for byte. ID3v2.3 and 2.4 tags are edited in their own version; a
/// file without one gets a new ID3v2.3 tag, the version every player reads.
enum ID3TagWriter {
    private static let frameIDs: [TagField: [String]] = [
        .title: ["TIT2"], .artist: ["TPE1"], .albumArtist: ["TPE2"], .album: ["TALB"],
        .track: ["TRCK"], .disc: ["TPOS"], .year: ["TYER", "TDRC"],
    ]

    static func write(_ changes: TagChanges, from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = [UInt8](try input.read(upToCount: 10) ?? Data())

        var version: UInt8 = 3
        var frames: [(id: String, bytes: [UInt8])] = []
        var audioStart: UInt64 = 0
        if header.count == 10, header[0...2] == [0x49, 0x44, 0x33] {  // "ID3"
            version = header[3]
            let flags = header[5]
            guard version == 3 || version == 4 else { throw TagWriteError.unsupported("ID3v2.\(version)-tagged MP3") }
            guard flags & 0x80 == 0 else { throw TagWriteError.unsupported("this MP3's (unsynchronised tag)") }
            let size = syncsafe(header, 6)
            let body = [UInt8](try input.read(upToCount: size) ?? Data())
            guard body.count == size else { throw TagWriteError.unreadable }
            var offset = 0
            if flags & 0x40 != 0, body.count >= 4 {  // extended header: dropped
                offset = version == 3 ? 4 + TagWriter.readBE32(body, 0) : syncsafe(body, 0)
            }
            while offset + 10 <= body.count {
                let idBytes = body[offset..<(offset + 4)]
                guard idBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }) else { break }
                let frameSize = version == 4 ? syncsafe(body, offset + 4) : TagWriter.readBE32(body, offset + 4)
                guard frameSize >= 0, offset + 10 + frameSize <= body.count else { break }
                frames.append((String(decoding: idBytes, as: UTF8.self), Array(body[offset..<(offset + 10 + frameSize)])))
                offset += 10 + frameSize
            }
            audioStart = 10 + UInt64(size) + (version == 4 && flags & 0x10 != 0 ? 10 : 0)
        }

        for field in TagField.allCases {
            guard let raw = changes[field] else { continue }
            var new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = Set(frameIDs[field]!)
            if field == .track || field == .disc {
                let old = frames.first { ids.contains($0.id) }.flatMap { text(of: $0.bytes) }
                new = TagWriter.keepingTotal(new, old: old)
            }
            frames.removeAll { ids.contains($0.id) }
            guard !new.isEmpty else { continue }
            let id = field == .year ? (version == 4 ? "TDRC" : "TYER") : frameIDs[field]![0]
            frames.append((id, textFrame(id, new, version: version)))
        }

        var body: [UInt8] = []
        for frame in frames { body += frame.bytes }
        body += [UInt8](repeating: 0, count: 1024)  // padding, so the next edit has room
        let tag = [0x49, 0x44, 0x33, version, 0, 0] + toSyncsafe(body.count) + body

        let output = try TagWriter.makeOutput(destination)
        defer { try? output.close() }
        try output.write(contentsOf: Data(tag))
        try TagWriter.copy(input, from: audioStart, to: output)
    }

    /// A text frame: UTF-8 in ID3v2.4, UTF-16 with a byte-order mark in 2.3.
    private static func textFrame(_ id: String, _ value: String, version: UInt8) -> [UInt8] {
        let content: [UInt8] = version == 4
            ? [3] + Array(value.utf8)
            : [1, 0xFF, 0xFE] + value.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let size = version == 4 ? toSyncsafe(content.count) : TagWriter.be32(content.count)
        return Array(id.utf8) + size + [0, 0] + content
    }

    /// A text frame's value (for keeping "/12" in TRCK), whatever its encoding.
    private static func text(of frame: [UInt8]) -> String? {
        guard frame.count > 11 else { return nil }
        let content = Array(frame[11...])
        let string: String?
        switch frame[10] {
        case 0: string = String(bytes: content, encoding: .isoLatin1)
        case 1: string = String(bytes: content, encoding: .utf16)
        case 2: string = String(bytes: content, encoding: .utf16BigEndian)
        default: string = String(bytes: content, encoding: .utf8)
        }
        return string?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }

    private static func syncsafe(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at + 4 <= bytes.count else { return 0 }
        return Int(bytes[at] & 0x7F) << 21 | Int(bytes[at + 1] & 0x7F) << 14 | Int(bytes[at + 2] & 0x7F) << 7 | Int(bytes[at + 3] & 0x7F)
    }

    private static func toSyncsafe(_ value: Int) -> [UInt8] {
        [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
    }
}

// MARK: - M4A (MP4 / iTunes tags)

/// Rewrites the iTunes tag list (moov › udta › meta › ilst). When the movie box sits in front of
/// the audio, the audio's chunk offsets are moved by however much the box grew or shrank.
enum MP4TagWriter {
    private static func atom(_ name: String) -> [UInt8] { Array(name.utf8) }
    private static func itunes(_ name: String) -> [UInt8] { [0xA9] + Array(name.utf8) }  // "©nam"…

    private static let itemTypes: [TagField: [UInt8]] = [
        .title: itunes("nam"), .artist: itunes("ART"), .albumArtist: atom("aART"), .album: itunes("alb"),
        .track: atom("trkn"), .disc: atom("disk"), .year: itunes("day"),
    ]

    static func write(_ changes: TagChanges, from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()

        // Find the movie box among the top-level boxes.
        var offset: UInt64 = 0
        var moovRange: (start: UInt64, size: UInt64)?
        while offset + 8 <= fileSize {
            try input.seek(toOffset: offset)
            let header = [UInt8](try input.read(upToCount: 16) ?? Data())
            guard header.count >= 8 else { break }
            let size32 = UInt64(TagWriter.readBE32(header, 0))
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var size = size32
            if size32 == 1 {
                guard header.count == 16 else { throw TagWriteError.unreadable }
                size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= 8, offset + size <= fileSize else { throw TagWriteError.unreadable }
            if type == "moof" { throw TagWriteError.unsupported("fragmented MP4") }
            if type == "moov" { moovRange = (offset, size) }
            offset += size
        }
        guard let moovRange, moovRange.size < 64 << 20 else { throw TagWriteError.unreadable }

        try input.seek(toOffset: moovRange.start)
        let moovBytes = [UInt8](try input.read(upToCount: Int(moovRange.size)) ?? Data())
        guard moovBytes.count == Int(moovRange.size) else { throw TagWriteError.unreadable }
        let headerLength = TagWriter.readBE32(moovBytes, 0) == 1 ? 16 : 8
        var moov = Box.make(type: atom("moov"), content: moovBytes[headerLength...])

        // moov › udta › meta › ilst, made where missing.
        let udta = moov.childIndex(atom("udta")) { Box(type: atom("udta"), children: []) }
        var meta = moov.children![udta].children!.firstIndex { $0.type == atom("meta") }
        if let meta, moov.children![udta].children![meta].childIndex(of: atom("keys")) != nil {
            throw TagWriteError.unsupported("this M4A's (QuickTime metadata)")
        }
        if meta == nil {
            let handler = Box(type: atom("hdlr"), payload: [0, 0, 0, 0, 0, 0, 0, 0] + atom("mdir") + atom("appl") + [UInt8](repeating: 0, count: 9))
            moov.children![udta].children!.append(Box(type: atom("meta"), prefix: [0, 0, 0, 0], children: [handler]))
            meta = moov.children![udta].children!.count - 1
        }
        let ilst = moov.children![udta].children![meta!].childIndex(atom("ilst")) { Box(type: atom("ilst"), children: []) }
        var items = moov.children![udta].children![meta!].children![ilst].children ?? []

        for field in TagField.allCases {
            guard let raw = changes[field] else { continue }
            let new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = itemTypes[field]!
            let old = items.first { $0.type == type }
            items.removeAll { $0.type == type }
            guard !new.isEmpty else { continue }
            if field == .track || field == .disc {
                guard let number = Int(new), number >= 0, number <= 0xFFFF else { continue }
                // Keep the total (bytes 4–5 of the old value).
                let oldValue = old.map { Array($0.payload.dropFirst(16)) } ?? []
                let total = oldValue.count >= 6 ? Array(oldValue[4..<6]) : [0, 0]
                var value: [UInt8] = [0, 0, UInt8(number >> 8), UInt8(number & 0xFF)] + total
                if field == .track { value += [0, 0] }
                items.append(item(type, dataType: 0, value: value))
            } else {
                items.append(item(type, dataType: 1, value: Array(new.utf8)))
            }
        }
        moov.children![udta].children![meta!].children![ilst].children = items

        // The audio after the movie box moves by however much the box changed size.
        var newMoov = moov.serialized()
        let delta = Int64(newMoov.count) - Int64(moovRange.size)
        if delta != 0, moovRange.start + moovRange.size < fileSize {
            try moov.shiftChunkOffsets(after: moovRange.start, by: delta)
            newMoov = moov.serialized()
        }

        let output = try TagWriter.makeOutput(destination)
        defer { try? output.close() }
        try TagWriter.copy(input, from: 0, length: moovRange.start, to: output)
        try output.write(contentsOf: Data(newMoov))
        try TagWriter.copy(input, from: moovRange.start + moovRange.size, to: output)
    }

    private static func item(_ type: [UInt8], dataType: Int, value: [UInt8]) -> Box {
        let data = Box(type: atom("data"), payload: TagWriter.be32(dataType) + [0, 0, 0, 0] + value)
        return Box(type: type, payload: data.serialized())
    }

    /// One box, parsed only as deep as needed: containers on the way to the tags and the chunk
    /// offsets have children, everything else is kept as raw bytes.
    struct Box {
        var type: [UInt8]
        /// Bytes before the children (meta's version and flags).
        var prefix: [UInt8] = []
        var children: [Box]?
        /// A leaf's contents, or whatever follows a container's children.
        var payload: [UInt8] = []

        private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "meta", "ilst", "edts", "dinf"]

        static func make(type: [UInt8], content: ArraySlice<UInt8>) -> Box {
            let name = String(decoding: type, as: UTF8.self)
            guard containers.contains(name) else { return Box(type: type, payload: Array(content)) }
            var prefix: [UInt8] = []
            var body = content
            if name == "meta", content.count >= 4 {
                // The iTunes meta box starts with version and flags; QuickTime's goes straight
                // to its handler box.
                let start = content.startIndex
                let quickTime = content.count >= 8 && Array(content[(start + 4)..<(start + 8)]) == Array("hdlr".utf8)
                if !quickTime {
                    prefix = Array(content[start..<(start + 4)])
                    body = content[(start + 4)...]
                }
            }
            var children: [Box] = []
            var index = body.startIndex
            while body.endIndex - index >= 8 {
                var size = Int(body[index]) << 24 | Int(body[index + 1]) << 16 | Int(body[index + 2]) << 8 | Int(body[index + 3])
                var headerLength = 8
                if size == 1, body.endIndex - index >= 16 {
                    size = body[(index + 8)..<(index + 16)].reduce(0) { $0 << 8 | Int($1) }
                    headerLength = 16
                }
                guard size >= headerLength, index + size <= body.endIndex else { break }
                children.append(make(type: Array(body[(index + 4)..<(index + 8)]),
                                     content: body[(index + headerLength)..<(index + size)]))
                index += size
            }
            return Box(type: type, prefix: prefix, children: children, payload: Array(body[index...]))
        }

        func serialized() -> [UInt8] {
            var body = prefix
            for child in children ?? [] { body += child.serialized() }
            body += payload
            return TagWriter.be32(body.count + 8) + type + body
        }

        func childIndex(of type: [UInt8]) -> Int? { children?.firstIndex { $0.type == type } }

        /// The index of the first child of `type`, adding `make()` first when there's none.
        mutating func childIndex(_ type: [UInt8], orAdd make: () -> Box) -> Int {
            if let index = childIndex(of: type) { return index }
            if children == nil { children = [] }
            children!.append(make())
            return children!.count - 1
        }

        mutating func shiftChunkOffsets(after start: UInt64, by delta: Int64) throws {
            let name = String(decoding: type, as: UTF8.self)
            if name == "stco" || name == "co64" {
                let width = name == "stco" ? 4 : 8
                guard payload.count >= 8 else { return }
                let count = TagWriter.readBE32(payload, 4)
                guard 8 + count * width <= payload.count else { throw TagWriteError.unreadable }
                for entry in 0..<count {
                    let at = 8 + entry * width
                    let old = payload[at..<(at + width)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    guard old > start else { continue }
                    let new = Int64(old) + delta
                    guard new >= 0, width == 8 || new <= Int64(UInt32.max) else { throw TagWriteError.unreadable }
                    for byte in 0..<width {
                        payload[at + byte] = UInt8(truncatingIfNeeded: UInt64(new) >> UInt64(8 * (width - 1 - byte)))
                    }
                }
            }
            guard var kids = children else { return }
            for index in kids.indices { try kids[index].shiftChunkOffsets(after: start, by: delta) }
            children = kids
        }
    }
}
