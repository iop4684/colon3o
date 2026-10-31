import Foundation
import SoulseekKit

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
    /// Word timings (enhanced LRC), when the lyrics have them; empty for line-synced lyrics.
    var words: [LyricWord] = []
    /// When the last word ends, if the lyrics say so.
    var wordsEnd: Double? = nil
}

/// One timed piece of a line: a word or syllable, with any spaces that follow it.
struct LyricWord: Hashable {
    let time: Double
    var text: String
    /// When it stops being sung, if the lyrics say (an empty <mm:ss.xx> tag after it).
    var end: Double? = nil
}

enum Lyrics: Equatable {
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case notFound
}

/// Where the lyrics on screen came from.
enum LyricsOrigin {
    case file, lrclib
}

/// Online lyrics sources.
enum LyricsSource: String, CaseIterable {
    case lrclib = "LRCLIB"
    case petit = "PetitLyrics"
}

/// Lyrics from a .lrc file next to the song if there is one, otherwise the best of the online
/// sources: LRCLIB (lrclib.net: free, no API key, mostly line-synced) and PetitLyrics (often
/// word-synced). Whatever is used is saved next to the song as a .lrc (marked as fetched), so it
/// works offline after.
/// Songs no source has are remembered for a few days.
actor LyricsService {
    static let shared = LyricsService()

    private struct Entry: Codable {
        var syncedLyrics: String?
        var plainLyrics: String?
        var instrumental: Bool?
        var duration: Double?
    }

    private struct Stored: Codable {
        var entry: Entry?
        var fetched: Date
    }

    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A sidecar .lrc (or plain text saved as .lrc) next to the song.
    nonisolated static func localLyrics(at url: URL) -> Lyrics? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let synced = parseLRC(text)
        if !synced.isEmpty { return .synced(synced) }
        // No timestamps: show it as plain text, minus LRC tags like [ar:…].
        let lines = text.components(separatedBy: .newlines)
            .filter { !($0.hasPrefix("[") && $0.hasSuffix("]")) }
        let trimmed = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return trimmed.isEmpty ? nil : .plain(Array(trimmed))
    }

    /// First line of a .lrc this app saved after fetching it, so it can tell those from files you added.
    nonisolated static let fetchedMarker = "[re:colon3o"

    /// What one source came back with.
    private enum Outcome {
        case found(Lyrics, lrc: String?, entry: Entry?)
        case none
        case failed
    }

    /// nil means a lookup failed (offline, server error) and nothing was found elsewhere, so the
    /// caller can offer a retry. `saveTo` is where found lyrics are kept as a .lrc; `onPending`
    /// hears which sources are still being asked.
    ///
    /// All sources are asked at once and the best answer wins: word-synced (PetitLyrics), then
    /// line-synced (LRCLIB, which also checks the song's length), then plain text from LRCLIB,
    /// then from PetitLyrics. It's saved, so this only happens once per song.
    func lyrics(title: String, artist: String, album: String?, duration: Double, cacheKey: String,
                saveTo lrcFile: URL? = nil, onPending: @escaping @MainActor ([LyricsSource]) -> Void = { _ in }) async -> Lyrics? {
        let file = directory.appendingPathComponent(MD5.hex(cacheKey) + ".json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            // Misses are retried after a few days in case someone has added the song since.
            if stored.entry != nil || Date().timeIntervalSince(stored.fetched) < 3 * 86_400 {
                return Self.lyrics(from: stored.entry)
            }
        }
        guard AppSettings.lyricsLookupEnabled else { return .notFound }

        var pending = LyricsSource.allCases
        await onPending(pending)
        var outcomes: [LyricsSource: Outcome] = [:]
        await withTaskGroup(of: (LyricsSource, Outcome).self) { group in
            for source in LyricsSource.allCases {
                group.addTask { (source, await self.ask(source, title: title, artist: artist, album: album, duration: duration)) }
            }
            for await (source, outcome) in group {
                outcomes[source] = outcome
                pending.removeAll { $0 == source }
                await onPending(pending)
            }
        }

        // Best first.
        let ranked: [(LyricsSource, (Lyrics) -> Bool)] = [
            (.petit, { lyrics in
                if case let .synced(lines) = lyrics { return lines.contains { line in !line.words.isEmpty } }
                return false
            }),
            (.lrclib, { if case .synced = $0 { return true }; return false }),
            (.petit, { if case .synced = $0 { return true }; return false }),
            (.lrclib, { if case .plain = $0 { return true }; return false }),
            (.petit, { if case .plain = $0 { return true }; return false }),
            (.lrclib, { $0 == .instrumental }),
        ]
        for (source, accepts) in ranked {
            guard case let .found(lyrics, lrc, entry)? = outcomes[source], accepts(lyrics) else { continue }
            if let lrc {
                save(lrc, from: source, to: lrcFile)
            } else if let entry {
                remember(entry, in: file)  // Instrumental: nothing to save as a file.
            }
            return lyrics
        }
        if outcomes.values.contains(where: { if case .failed = $0 { return true }; return false }) { return nil }
        remember(nil, in: file)
        return .notFound
    }

    private func ask(_ source: LyricsSource, title: String, artist: String, album: String?, duration: Double) async -> Outcome {
        do {
            switch source {
            case .lrclib:
                guard let entry = try await fetch(title: title, artist: artist, album: album, duration: duration) else { return .none }
                let found = Self.lyrics(from: entry)
                if found == .notFound { return .none }
                return .found(found, lrc: entry.syncedLyrics?.nonEmpty ?? entry.plainLyrics?.nonEmpty, entry: entry)
            case .petit:
                guard let result = try await PetitLyrics.fetch(title: title, artist: artist) else { return .none }
                return .found(result.lyrics, lrc: result.lrc, entry: nil)
            }
        } catch {
            Diagnostics.shared.log("Lyrics: \(source.rawValue) failed for \(artist) – \(title): \(error.localizedDescription)",
                                   category: "lyrics")
            return .failed
        }
    }

    private func remember(_ entry: Entry?, in file: URL) {
        if let data = try? JSONEncoder().encode(Stored(entry: entry, fetched: Date())) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func save(_ lrc: String, from source: LyricsSource, to file: URL?) {
        guard let file else { return }
        let text = "\(Self.fetchedMarker) \(source.rawValue)]\n" + lrc + "\n"
        try? Data(text.utf8).write(to: file, options: .atomic)
    }

    /// Which source a .lrc this app saved came from; nil for files you added yourself.
    nonisolated static func fetchedSource(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 128)) ?? Data(), as: UTF8.self)
        guard head.hasPrefix(fetchedMarker), let end = head.firstIndex(of: "]") else { return nil }
        return head[head.index(head.startIndex, offsetBy: fetchedMarker.count)..<end].trimmingCharacters(in: .whitespaces)
    }

    /// Search Again: drops the remembered miss and any .lrc fetched earlier (files you added stay).
    func forget(cacheKey: String, fetchedFile: URL? = nil) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(MD5.hex(cacheKey) + ".json"))
        if let fetchedFile, Self.fetchedSource(of: fetchedFile) != nil {
            try? FileManager.default.removeItem(at: fetchedFile)
        }
    }

    private func fetch(title: String, artist: String, album: String?, duration: Double) async throws -> Entry? {
        if let album, duration > 0 {
            var components = URLComponents(string: "https://lrclib.net/api/get")!
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "album_name", value: album),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
            ]
            let (data, status) = try await get(components.url!)
            if status == 200, let entry = try? JSONDecoder().decode(Entry.self, from: data) { return entry }
            if status != 404 && status != 400 { throw URLError(.badServerResponse) }
        }

        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        let (data, status) = try await get(components.url!)
        guard status == 200 else { throw URLError(.badServerResponse) }
        let results = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        let close = results.filter { entry in
            guard duration > 0, let other = entry.duration else { return true }
            return abs(other - duration) <= 5
        }
        return close.first(where: { $0.syncedLyrics?.isEmpty == false })
            ?? close.first(where: { $0.plainLyrics?.isEmpty == false || $0.instrumental == true })
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func lyrics(from entry: Entry?) -> Lyrics {
        guard let entry else { return .notFound }
        if let synced = entry.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = entry.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        return entry.instrumental == true ? .instrumental : .notFound
    }

    private static let wordTag = try! NSRegularExpression(pattern: #"<(\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?)>"#)

    /// "[01:23.45] text" lines; a line may carry several timestamps. Enhanced LRC word timings
    /// ("[01:23.45] <01:23.45>some <01:23.90>words") become the line's `words`.
    static func parseLRC(_ text: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        var lines: [(time: Double, text: String, words: [LyricWord], end: Double?)] = []
        for raw in text.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = regex.matches(in: raw, range: range)
            guard let last = matches.last, let textRange = Range(NSRange(location: last.range.upperBound,
                                                                         length: range.upperBound - last.range.upperBound), in: raw)
            else { continue }
            let rest = String(raw[textRange])
            let shown = wordTag.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                      let secondsText = Range(match.range(at: 2), in: raw).map({ raw[$0].replacingOccurrences(of: ":", with: ".") }),
                      let seconds = Double(secondsText) else { continue }
                let time = minutes * 60 + seconds
                // Word times are absolute, so they only fit a line that appears once.
                let (words, end): ([LyricWord], Double?) = matches.count == 1 ? wordTimings(in: rest, lineTime: time) : ([], nil)
                lines.append((time, shown.isEmpty ? "♪" : shown, words, end))
            }
        }
        return lines.sorted { $0.time < $1.time }.enumerated().map {
            LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text,
                      words: $0.element.words, wordsEnd: $0.element.end)
        }
    }

    /// The words of an enhanced LRC line, each starting at its <mm:ss.xx> tag. A tag with nothing
    /// (or only spaces) after it marks where the word before it ends.
    private static func wordTimings(in rest: String, lineTime: Double) -> ([LyricWord], Double?) {
        let tags = wordTag.matches(in: rest, range: NSRange(rest.startIndex..., in: rest))
        guard !tags.isEmpty, let first = Range(tags[0].range, in: rest) else { return ([], nil) }
        var words: [LyricWord] = []
        var end: Double?
        let lead = String(rest[..<first.lowerBound])
        if !lead.trimmingCharacters(in: .whitespaces).isEmpty { words.append(LyricWord(time: lineTime, text: lead)) }
        for (index, tag) in tags.enumerated() {
            guard let tagRange = Range(tag.range, in: rest), let stampRange = Range(tag.range(at: 1), in: rest),
                  let time = seconds(String(rest[stampRange])) else { continue }
            let next = index + 1 < tags.count ? Range(tags[index + 1].range, in: rest)?.lowerBound ?? rest.endIndex : rest.endIndex
            let piece = String(rest[tagRange.upperBound..<next])
            if piece.trimmingCharacters(in: .whitespaces).isEmpty {
                if let last = words.indices.last {
                    words[last].end = time
                    words[last].text += piece
                }
                if index == tags.count - 1 { end = time }
            } else {
                words.append(LyricWord(time: time, text: piece))
            }
        }
        guard !words.isEmpty else { return ([], nil) }
        // Same spacing as the line text: no leading or trailing spaces on the line as a whole.
        words[0].text = String(words[0].text.drop(while: { $0 == " " }))
        while words[words.count - 1].text.hasSuffix(" ") { words[words.count - 1].text.removeLast() }
        return (words, end)
    }

    /// "mm:ss.xx" (or "mm:ss:xx") in seconds.
    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Double(parts[0]),
              let seconds = Double(parts[1].replacingOccurrences(of: ":", with: ".")) else { return nil }
        return minutes * 60 + seconds
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
