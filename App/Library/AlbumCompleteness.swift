import Foundation
import SoulseekKit

/// A song the album should have but the library doesn't.
struct MissingTrack: Identifiable, Hashable {
    enum Source: Hashable {
        /// Seen in the peer's folder when the album was downloaded; downloadable directly.
        case soulseek(username: String, file: SharedFile)
        /// From the MusicBrainz tracklist; has to be searched for.
        case musicBrainz
    }

    let id: String
    let disc: Int
    let number: Int?
    let title: String
    let duration: Double?
    let source: Source
}

struct AlbumCompleteness: Equatable {
    var missing: [MissingTrack]
    var expectedCount: Int
    var sourceDescription: String
    /// How many songs the album had when this was worked out; a change triggers a recheck.
    var localCount: Int
}

/// Works out which songs an album is missing, from the Soulseek folder it came from or from
/// MusicBrainz. Results are cached per album.
@MainActor
final class AlbumCompletenessStore: ObservableObject {
    @Published private(set) var results: [String: AlbumCompleteness] = [:]
    @Published private(set) var hiddenAlbums: Set<String>
    @Published private(set) var loading: Set<String> = []

    private let listings = FolderListingStore()

    /// Song → the id its album had before Edit Info renamed it. An album's id comes from its
    /// name, so a renamed album would otherwise lose its tracklist and search MusicBrainz again
    /// under the new name (often finding nothing).
    private var renamedFrom: [String: String]

    init() {
        hiddenAlbums = Set(UserDefaults.standard.stringArray(forKey: "missing.hiddenAlbums") ?? [])
        renamedFrom = UserDefaults.standard.dictionary(forKey: "missing.renamedFrom") as? [String: String] ?? [:]
    }

    /// Call before Edit Info writes `tracks`. When they're a whole album, its tracklist and
    /// Hide Missing choice follow it to its new name.
    func albumWillChange(_ album: Album, editing tracks: [Track]) {
        guard Set(tracks.map(\.id)).isSuperset(of: album.tracks.map(\.id)) else { return }
        for track in album.tracks { renamedFrom[track.id] = renamedFrom[track.id] ?? album.id }
        UserDefaults.standard.set(renamedFrom, forKey: "missing.renamedFrom")
    }

    /// Earlier ids of this album, from Edit Info renames not yet carried over.
    private func previousIDs(of album: Album) -> [String] {
        var seen = Set<String>()
        return album.tracks.compactMap { renamedFrom[$0.id] }.filter { $0 != album.id && seen.insert($0).inserted }
    }

    private func forgetRename(of album: Album) {
        var changed = false
        for track in album.tracks where renamedFrom.removeValue(forKey: track.id) != nil { changed = true }
        if changed { UserDefaults.standard.set(renamedFrom, forKey: "missing.renamedFrom") }
    }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: AppSettings.showMissingKey) as? Bool ?? true }
    static var musicBrainzEnabled: Bool { UserDefaults.standard.object(forKey: AppSettings.musicBrainzKey) as? Bool ?? true }

    func isHidden(_ album: Album) -> Bool { hiddenAlbums.contains(album.id) }

    func setHidden(_ album: Album, _ hidden: Bool) {
        if hidden { hiddenAlbums.insert(album.id) } else { hiddenAlbums.remove(album.id) }
        UserDefaults.standard.set(Array(hiddenAlbums), forKey: "missing.hiddenAlbums")
    }

    /// Remember a peer's full folder listing when downloading from it.
    func recordListing(username: String, remoteFolder: String, files: [SharedFile]) {
        let audio = files.filter { LibraryStore.audioExtensions.contains($0.fileExtension) && $0.folder == remoteFolder }
        guard !audio.isEmpty else { return }
        let local = SoulseekClient.libraryFolderName(forRemoteFolder: SharedFile(path: remoteFolder + "\\x", size: 0).folderName)
        listings.save(FolderListing(username: username, remoteFolder: remoteFolder, files: audio), forLocalFolder: local)
    }

    func refresh(_ album: Album, force: Bool = false) {
        guard Self.isEnabled, !loading.contains(album.id) else { return }
        if !force, let existing = results[album.id], existing.localCount == album.tracks.count { return }
        loading.insert(album.id)

        // Renamed with Edit Info: keep the old name's Hide Missing choice.
        let previous = previousIDs(of: album)
        if previous.contains(where: hiddenAlbums.contains), !hiddenAlbums.contains(album.id) { setHidden(album, true) }

        // 1. The Soulseek folder it was downloaded from: exact and offline.
        if let listing = listings.listing(forLocalFolder: album.folder.lastPathComponent) {
            results[album.id] = Self.compare(album, expected: listing.expectedTracks(), source: "From \(listing.username)'s folder")
            loading.remove(album.id)
            forgetRename(of: album)
            return
        }

        // 2. MusicBrainz.
        guard Self.musicBrainzEnabled else {
            loading.remove(album.id)
            return
        }
        let mbid = album.tracks.compactMap(\.musicBrainzAlbumID).first
        let title = album.title, artist = album.artist, localTitles = album.tracks.map(\.title)
        Task {
            let tracklist = await MusicBrainz.shared.tracklist(albumID: album.id, previousIDs: force ? [] : previous,
                                                               releaseID: mbid, title: title, artist: artist,
                                                               localTitles: localTitles, force: force)
            if let tracklist {
                self.results[album.id] = Self.compare(album, expected: tracklist.tracks, source: "MusicBrainz: \(tracklist.title)")
                self.forgetRename(of: album)
            }
            self.loading.remove(album.id)
        }
    }

    private static func compare(_ album: Album, expected: [ExpectedTrack], source: String) -> AlbumCompleteness {
        let localFiles = Set(album.tracks.map { normalizeFilename($0.url.lastPathComponent) })
        let localTitles = album.tracks.map { normalizeTitle($0.title) }.filter { !$0.isEmpty }
        let localNumbers = Set(album.tracks.compactMap { track in track.trackNumber.map { "\(track.discNumber ?? 1)-\($0)" } })

        var missing: [MissingTrack] = []
        for entry in expected {
            if let filename = entry.filename, localFiles.contains(normalizeFilename(filename)) { continue }
            let title = normalizeTitle(entry.title)
            if !title.isEmpty, localTitles.contains(where: { local in
                local == title || (min(local.count, title.count) >= 5 && (local.hasPrefix(title) || title.hasPrefix(local)))
            }) { continue }
            // Same disc/track number and no title to go on: assume it's there.
            if title.isEmpty, let number = entry.number, localNumbers.contains("\(entry.disc)-\(number)") { continue }
            missing.append(MissingTrack(id: "\(entry.disc)-\(entry.number ?? 0)-\(entry.title)", disc: entry.disc,
                                        number: entry.number, title: entry.title, duration: entry.duration,
                                        source: entry.source))
        }
        return AlbumCompleteness(missing: missing, expectedCount: max(expected.count, album.tracks.count),
                                 sourceDescription: source, localCount: album.tracks.count)
    }

    static func normalizeTitle(_ title: String) -> String {
        var text = title.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"\b(feat|ft|featuring)\.?\s.*$"#, #"\s-\s.*(remaster|version|edit|mix).*$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func normalizeFilename(_ name: String) -> String {
        // Library copies may have gained " (1)" when a name was taken.
        name.lowercased().replacingOccurrences(of: #" \(\d+\)(?=\.[^.]+$)"#, with: "", options: .regularExpression)
    }
}

struct ExpectedTrack {
    let disc: Int
    let number: Int?
    let title: String
    let duration: Double?
    let filename: String?
    let source: MissingTrack.Source
}

// MARK: - Soulseek folder listings

struct FolderListing: Codable {
    struct File: Codable {
        let path: String
        let size: UInt64
        let duration: UInt32?
    }

    let username: String
    let remoteFolder: String
    let files: [File]

    init(username: String, remoteFolder: String, files: [SharedFile]) {
        self.username = username
        self.remoteFolder = remoteFolder
        self.files = files.map { File(path: $0.path, size: $0.size, duration: $0.attributes.duration) }
    }

    func expectedTracks() -> [ExpectedTrack] {
        let shared = files.map { SharedFile(path: $0.path, size: $0.size, attributes: FileAttributes(duration: $0.duration)) }
        var parsed = shared.map { MetadataReader.parseFilename(($0.filename as NSString).deletingPathExtension) }
        // "Bring Me The Horizon - Fresh Bruises", "Artist - Album - 03 - Song": drop what every file
        // name starts with, so only the song's own name is left (and its number, if that follows).
        if let prefix = Self.sharedPrefix(parsed.map(\.title)) {
            parsed = parsed.map { entry in
                let rest = String(entry.title.dropFirst(prefix.count))
                let again = MetadataReader.parseFilename(rest)
                return (entry.number ?? again.number, again.title)
            }
        }
        return zip(files, zip(shared, parsed)).map { file, pair in
            let (sharedFile, entry) = pair
            return ExpectedTrack(disc: 1, number: entry.number, title: entry.title,
                                 duration: file.duration.map(Double.init), filename: sharedFile.filename,
                                 source: .soulseek(username: username, file: sharedFile))
        }
        .sorted { ($0.number ?? 999, $0.title) < ($1.number ?? 999, $1.title) }
    }

    /// The longest "… - " that every title starts with (at least two titles, and something left
    /// after it in each), or nil.
    static func sharedPrefix(_ titles: [String]) -> String? {
        guard titles.count >= 2, let first = titles.first else { return nil }
        var candidates: [String] = []
        var search = first.startIndex
        while let range = first.range(of: " - ", range: search..<first.endIndex) {
            candidates.append(String(first[..<range.upperBound]))
            search = range.upperBound
        }
        return candidates.reversed().first { prefix in
            titles.allSatisfy { $0.hasPrefix(prefix) && $0.count > prefix.count }
        }
    }
}

/// Folder listings keyed by the local folder name the album landed in.
final class FolderListingStore {
    private var listings: [String: FolderListing]
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("album-sources.json")

    init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: FolderListing].self, from: data) {
            listings = decoded
        } else {
            listings = [:]
        }
    }

    func listing(forLocalFolder name: String) -> FolderListing? { listings[name] }

    func save(_ listing: FolderListing, forLocalFolder name: String) {
        listings[name] = listing
        if let data = try? JSONEncoder().encode(listings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - MusicBrainz

struct Tracklist: Codable {
    let title: String
    let tracks: [Entry]

    struct Entry: Codable {
        let disc: Int
        let number: Int?
        let title: String
        let duration: Double?
    }
}

extension Tracklist {
    fileprivate func expected() -> [ExpectedTrack] {
        tracks.map { ExpectedTrack(disc: $0.disc, number: $0.number, title: $0.title, duration: $0.duration,
                                   filename: nil, source: .musicBrainz) }
    }
}

/// Release tracklists from MusicBrainz (free, no key; max ~1 request/second, needs a User-Agent).
actor MusicBrainz {
    static let shared = MusicBrainz()

    private var lastRequest = Date.distantPast
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tracklists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private struct Cached: Codable {
        let tracklist: Tracklist?
        let fetched: Date
        /// 2: searched with the song-based fallbacks. "Not found" from older searches is retried.
        var version: Int?
    }

    /// The best-matching release's tracks, or nil if none was found.
    func tracklist(albumID: String, previousIDs: [String] = [], releaseID: String?, title: String, artist: String,
                   localTitles: [String], force: Bool) async -> (title: String, tracks: [ExpectedTrack])? {
        let localCount = localTitles.count
        let file = directory.appendingPathComponent(albumID + ".json")
        // Renamed with Edit Info: start from the tracklist found under the old name. (If the old
        // name found nothing, search again under the new one: fixing the name may be why it changed.)
        if !FileManager.default.fileExists(atPath: file.path),
           let old = previousIDs.lazy.map({ self.directory.appendingPathComponent($0 + ".json") }).first(where: {
               guard let data = try? Data(contentsOf: $0) else { return false }
               return (try? JSONDecoder().decode(Cached.self, from: data))?.tracklist != nil
           }) {
            try? FileManager.default.copyItem(at: old, to: file)
        }
        if !force, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Cached.self, from: data),
           cached.tracklist != nil || (cached.version == 2 && Date().timeIntervalSince(cached.fetched) < 7 * 86_400) {
            return cached.tracklist.map { ($0.title, $0.expected()) }
        }

        var found: Tracklist?
        do {
            if let releaseID {
                found = try await fetchRelease(releaseID)
            } else {
                found = try await findRelease(title: title, artist: artist, localCount: localCount, localTitles: localTitles)
            }
        } catch {
            return nil  // Network trouble: don't cache, try again later
        }
        if let data = try? JSONEncoder().encode(Cached(tracklist: found, fetched: Date(), version: 2)) {
            try? data.write(to: file, options: .atomic)
        }
        return found.map { ($0.title, $0.expected()) }
    }

    /// By album title and artist first. If that finds nothing (the album was renamed or given
    /// another artist with Edit Info, or is tagged differently from MusicBrainz), by the title
    /// alone, then by the songs themselves; those only count when most of the songs are on it.
    private func findRelease(title: String, artist: String, localCount: Int, localTitles: [String]) async throws -> Tracklist? {
        if let id = try await searchRelease(title: title, artist: artist, localCount: localCount),
           let tracklist = try await fetchRelease(id) {
            return tracklist
        }
        let wanted = localTitles.map(AlbumCompletenessStoreNormalizer.title).filter { $0.count >= 2 }
        guard wanted.count >= 2 else { return nil }

        var tried = Set<String>()
        var candidates = try await releaseIDs(query: "release:\"\(Self.quoted(title))\"", sameTitleAs: title)
        candidates += try await releasesWithSongs(localTitles)
        for id in candidates where tried.insert(id).inserted {
            guard tried.count <= 5 else { break }
            if let tracklist = try await fetchRelease(id), Self.hasMostSongs(tracklist, wanted) { return tracklist }
        }
        return nil
    }

    /// At least 60% of our songs (and two or more) are on the release.
    private static func hasMostSongs(_ tracklist: Tracklist, _ wanted: [String]) -> Bool {
        let theirs = Set(tracklist.tracks.map { AlbumCompletenessStoreNormalizer.title($0.title) })
        let matched = wanted.filter { mine in
            theirs.contains(mine) || theirs.contains { min($0.count, mine.count) >= 5 && ($0.hasPrefix(mine) || mine.hasPrefix($0)) }
        }.count
        return matched >= 2 && Double(matched) >= Double(wanted.count) * 0.6
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
    }

    /// Releases from a search whose title matches ours.
    private func releaseIDs(query: String, sameTitleAs title: String) async throws -> [String] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "fmt", value: "json"),
                                 URLQueryItem(name: "limit", value: "10")]
        struct Response: Decodable {
            struct Release: Decodable {
                let id: String
                let title: String
            }
            let releases: [Release]
        }
        let response: Response = try await get(components.url!)
        let wanted = AlbumCompletenessStoreNormalizer.title(title)
        return response.releases.filter { AlbumCompletenessStoreNormalizer.title($0.title) == wanted }.map(\.id)
    }

    /// Releases that two of our songs both appear on (looked up by song title alone, since the
    /// artist may be the thing that was edited), most likely first.
    private func releasesWithSongs(_ titles: [String]) async throws -> [String] {
        // The two longest titles are the most telling.
        let picks = titles.filter { AlbumCompletenessStoreNormalizer.title($0).count >= 3 }
            .sorted { $0.count > $1.count }.prefix(2)
        guard picks.count == 2 else { return [] }
        struct Response: Decodable {
            struct Recording: Decodable {
                struct Release: Decodable { let id: String }
                let releases: [Release]?
            }
            let recordings: [Recording]
        }
        var sets: [[String]] = []
        for title in picks {
            var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
            components.queryItems = [URLQueryItem(name: "query", value: "recording:\"\(Self.quoted(title))\""),
                                     URLQueryItem(name: "fmt", value: "json"),
                                     URLQueryItem(name: "limit", value: "50")]
            let response: Response = try await get(components.url!)
            sets.append(response.recordings.flatMap { ($0.releases ?? []).map(\.id) })
        }
        let second = Set(sets[1])
        var seen = Set<String>()
        return sets[0].filter { second.contains($0) && seen.insert($0).inserted }
    }

    private func searchRelease(title: String, artist: String, localCount: Int) async throws -> String? {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "")
        let escapedArtist = artist.replacingOccurrences(of: "\"", with: "")
        var query = "release:\"\(escapedTitle)\""
        if artist != "Various Artists", artist != "Unknown Artist" { query += " AND artist:\"\(escapedArtist)\"" }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "fmt", value: "json"),
                                 URLQueryItem(name: "limit", value: "10")]
        struct Response: Decodable {
            struct Release: Decodable {
                let id: String
                let title: String
                let score: Int?
                let trackCount: Int?
                enum CodingKeys: String, CodingKey {
                    case id, title, score
                    case trackCount = "track-count"
                }
            }
            let releases: [Release]
        }
        let response: Response = try await get(components.url!)
        let wanted = AlbumCompletenessStoreNormalizer.title(title)
        let candidates = response.releases.filter { ($0.score ?? 0) >= 80 }
            .filter { AlbumCompletenessStoreNormalizer.title($0.title) == wanted || ($0.score ?? 0) >= 95 }
        // Prefer the edition with at least as many tracks as we have, and the fewest extras.
        let best = candidates.min { lhs, rhs in
            func cost(_ release: Response.Release) -> Int {
                let count = release.trackCount ?? 0
                return count >= localCount ? count - localCount : 1000 + (localCount - count)
            }
            return cost(lhs) < cost(rhs)
        }
        return best?.id
    }

    private func fetchRelease(_ id: String) async throws -> Tracklist? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)")!
        components.queryItems = [URLQueryItem(name: "inc", value: "recordings"), URLQueryItem(name: "fmt", value: "json")]
        struct Response: Decodable {
            struct Medium: Decodable {
                struct Track: Decodable {
                    let number: String?
                    let position: Int?
                    let title: String
                    let length: Int?
                }
                let position: Int?
                let tracks: [Track]?
            }
            let title: String
            let media: [Medium]?
        }
        let response: Response = try await get(components.url!)
        let entries = (response.media ?? []).flatMap { medium in
            (medium.tracks ?? []).map { track in
                Tracklist.Entry(disc: medium.position ?? 1,
                                number: track.position ?? Int(track.number ?? ""),
                                title: track.title,
                                duration: track.length.map { Double($0) / 1000 })
            }
        }
        return entries.isEmpty ? nil : Tracklist(title: response.title, tracks: entries)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let wait = 1.1 - Date().timeIntervalSince(lastRequest)
        lastRequest = Date().addingTimeInterval(max(wait, 0))
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Title normalisation usable off the main actor.
enum AlbumCompletenessStoreNormalizer {
    static func title(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
