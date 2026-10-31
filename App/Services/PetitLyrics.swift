import Foundation

/// PetitLyrics (petitlyrics.com), a Japanese lyrics service with many word-synced lyrics. It has
/// no public API: this talks to the endpoint its own app uses, so it can stop working at any time.
/// Songs are matched by title and artist only (PetitLyrics doesn't report lengths).
enum PetitLyrics {
    struct Result {
        let lyrics: Lyrics
        /// The same lyrics as .lrc text, word timings included (enhanced LRC) when there are any.
        let lrc: String
    }

    private static let endpoint = URL(string: "https://p1.petitlyrics.com/api/GetPetitLyricsData.php")!

    /// PetitLyrics' lyrics types.
    private enum Kind: Int {
        case plain = 1, lineSynced = 2, wordSynced = 3
    }

    /// nil when PetitLyrics has nothing for the song; throws when it couldn't be asked.
    static func fetch(title: String, artist: String) async throws -> Result? {
        let found = try await request(["key_title": title, "key_artist": artist, "max_count": "1"])
        guard let song = found.first,
              let id = song.child("lyricsId")?.value, !id.isEmpty,
              let available = song.child("availableLyricsType").flatMap({ Int($0.value) }), available > 0
        else { return nil }

        // Search answers can be loose: make sure it's the same song before using it.
        if let found = song.child("title")?.value, !titlesMatch(found, title) {
            Diagnostics.shared.log("PetitLyrics: best match for \(artist) – \(title) was \(found); skipped", category: "lyrics")
            return nil
        }

        // Line-synced lyrics come in a form only PetitLyrics' app reads, so ask for the plain
        // text then; word-synced lyrics are plain XML.
        let wanted: Kind = available == Kind.wordSynced.rawValue ? .wordSynced : .plain
        guard let detail = try await request(["key_lyricsId": id, "lyricsType": String(wanted.rawValue)]).first,
              let encoded = detail.child("lyricsData")?.value,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty
        else { return nil }
        let kind = detail.child("lyricsType").flatMap { Int($0.value) }.flatMap(Kind.init(rawValue:)) ?? wanted

        if kind == .wordSynced, let result = wordSynced(data) { return result }
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Result(lyrics: .plain(text.components(separatedBy: "\n")), lrc: text)
    }

    /// `<wsy><line><linestring>…</linestring><word><wordstring>…</wordstring><starttime>ms</starttime>…`
    private static func wordSynced(_ data: Data) -> Result? {
        guard let root = XMLTree.parse(data) else { return nil }
        var lines: [LyricLine] = []
        var lrc: [String] = []
        for line in root.all("line") {
            let text = line.child("linestring")?.value ?? ""
            let words = line.children.filter { $0.name == "word" }
            let starts = words.compactMap { $0.child("starttime").flatMap { Int($0.value) } }
            guard let first = starts.first, first >= 0 else { continue }
            lines.append(LyricLine(id: lines.count, time: Double(first) / 1000, text: text.isEmpty ? "♪" : text))

            // Word timings only when every word has its text and they add up to the line.
            let pieces = words.map { ($0.child("wordstring")?.rawText ?? "", $0.child("starttime").flatMap { Int($0.value) }) }
            if pieces.count > 1, pieces.allSatisfy({ $0.1 != nil }), pieces.map(\.0).joined() == text {
                lrc.append("[\(stamp(first))]" + pieces.map { "<\(stamp($0.1!))>\($0.0)" }.joined())
            } else {
                lrc.append("[\(stamp(first))]\(text)")
            }
        }
        guard !lines.isEmpty else { return nil }
        return Result(lyrics: .synced(lines), lrc: lrc.joined(separator: "\n"))
    }

    private static func request(_ fields: [String: String]) async throws -> [XMLTree.Node] {
        var fields = fields
        fields["clientAppId"] = "p1110417"
        fields["terminalType"] = "10"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse) }
        guard let root = XMLTree.parse(data) else { throw URLError(.cannotParseResponse) }
        return root.all("song")
    }

    private static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = TrackMatcher.normalizeTitle(a), y = TrackMatcher.normalizeTitle(b)
        guard !x.isEmpty, !y.isEmpty else { return true }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Milliseconds as mm:ss.xx.
    static func stamp(_ ms: Int) -> String {
        let centis = max(ms, 0) / 10
        return String(format: "%02d:%02d.%02d", centis / 6000, (centis / 100) % 60, centis % 100)
    }
}

/// A small XML reader: elements with their text and children.
final class XMLTree: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        var rawText = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }

        var value: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        /// Every element with this name, depth first.
        func all(_ name: String) -> [Node] {
            var found = self.name == name ? [self] : []
            for child in children { found += child.all(name) }
            return found
        }
    }

    private var stack = [Node("#document")]

    static func parse(_ data: Data) -> Node? {
        let reader = XMLTree()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        return parser.parse() ? reader.stack.first : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = Node(elementName)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.rawText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.rawText += String(decoding: CDATABlock, as: UTF8.self)
    }
}
