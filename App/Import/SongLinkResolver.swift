import Foundation

/// Turns a song or album link from a streaming service into words to search Soulseek with.
/// No accounts or keys: each service's public lookup (oEmbed, the iTunes and Deezer APIs, or the
/// page's own tags) gives the title and artist.
enum SongLinkResolver {
    struct Resolved: Equatable {
        enum Kind { case song, album }

        let service: String
        let kind: Kind
        let title: String
        let artist: String

        /// What to search for: the first-named artist and the title without extras like
        /// "(feat. …)", since files are rarely named with those.
        var searchText: String {
            let firstArtist = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
                .replacingOccurrences(of: #"\s+(feat|ft|featuring|x)\.?\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                ?? artist
            let words = (firstArtist + " " + SongLinkResolver.plainTitle(title))
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”«»|/\\,;")))
                // A word with no letters or digits (like "&" or "-") would match no file.
                .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
            return words.joined(separator: " ")
        }
    }

    enum ResolveError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            }
        }
    }

    /// Whether the text is a web link rather than words to search for. Without "https://" only
    /// known music hosts count, so a search like "Mr.Children" is never taken for a link.
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), let url = link(from: trimmed), host(of: url).contains(".") else { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") { return true }
        return knownHosts.contains(host(of: url)) && url.path.count > 1
    }

    private static let knownHosts: Set<String> = ["youtube.com", "music.youtube.com", "m.youtube.com", "youtu.be",
                                                  "open.spotify.com", "spotify.link", "music.apple.com", "deezer.com",
                                                  "deezer.page.link", "link.deezer.com", "soundcloud.com",
                                                  "on.soundcloud.com", "tidal.com", "listen.tidal.com"]

    static func resolve(_ text: String) async throws -> Resolved {
        guard var url = link(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ResolveError.message("That isn't a link.")
        }
        // Short share links (spotify.link, youtu.be is handled below, deezer.page.link,
        // on.soundcloud.com…) redirect to the real page.
        if shortLinkHosts.contains(host(of: url)) { url = try await finalURL(of: url) }

        switch host(of: url) {
        case "youtube.com", "music.youtube.com", "m.youtube.com", "youtu.be":
            return try await youTube(url)
        case "open.spotify.com", "play.spotify.com":
            return try await spotify(url)
        case "music.apple.com", "itunes.apple.com", "geo.music.apple.com":
            return try await appleMusic(url)
        case "deezer.com":
            return try await deezer(url)
        case "soundcloud.com", "m.soundcloud.com":
            return try await soundCloud(url)
        default:
            return try await anyPage(url)
        }
    }

    // MARK: Services

    private static func youTube(_ url: URL) async throws -> Resolved {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.pathComponents.filter { $0 != "/" }
        var videoID = components?.queryItems?.first(where: { $0.name == "v" })?.value
        if videoID == nil, host(of: url) == "youtu.be" { videoID = path.first }
        if videoID == nil, let index = path.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), index + 1 < path.count {
            videoID = path[index + 1]
        }
        guard let videoID, !videoID.isEmpty else {
            if components?.queryItems?.contains(where: { $0.name == "list" }) == true || path.contains("browse") {
                throw ResolveError.message("That's a playlist link. Import playlists from the + menu in Library instead.")
            }
            throw ResolveError.message("Couldn't find a song in that YouTube link.")
        }
        let service = host(of: url) == "music.youtube.com" ? "YouTube Music" : "YouTube"
        var oEmbed = URLComponents(string: "https://www.youtube.com/oembed")!
        oEmbed.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=" + videoID),
                             URLQueryItem(name: "format", value: "json")]
        struct Response: Decodable {
            let title: String
            let author_name: String
        }
        let response: Response = try await getJSON(oEmbed.url!, service: service)
        let (title, artist) = splitVideoTitle(response.title, channel: response.author_name)
        return Resolved(service: service, kind: .song, title: title, artist: artist)
    }

    private static func spotify(_ url: URL) async throws -> Resolved {
        // open.spotify.com/track/ID, /album/ID, also with /intl-xx/ in front.
        let path = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        guard path.count >= 2, ["track", "album"].contains(path[0]) else {
            if path.first == "playlist" {
                throw ResolveError.message("That's a playlist link. Import playlists from the + menu in Library instead.")
            }
            throw ResolveError.message("Paste a Spotify song or album link.")
        }
        let tags = try await pageTags(URL(string: "https://open.spotify.com/\(path[0])/\(path[1])")!, service: "Spotify")
        guard let title = tags["og:title"], !title.isEmpty else {
            throw ResolveError.message("Couldn't read that Spotify page.")
        }
        // og:description is "Artist · Album · Song · Year" (or "Artist · album · Year · 10 songs").
        let artist = tags["music:musician_description"]
            ?? tags["og:description"]?.components(separatedBy: " · ").first
            ?? ""
        return Resolved(service: "Spotify", kind: path[0] == "album" ? .album : .song, title: title, artist: artist)
    }

    private static func appleMusic(_ url: URL) async throws -> Resolved {
        // music.apple.com/us/album/name/ALBUMID?i=SONGID, /us/song/name/SONGID, /us/album/name/ALBUMID
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.pathComponents.filter { $0 != "/" }
        let country = path.first.flatMap { $0.count == 2 ? $0 : nil } ?? "us"
        let songID = components?.queryItems?.first(where: { $0.name == "i" })?.value
        let id = songID ?? path.last.map { $0.replacingOccurrences(of: "id", with: "") }
        guard let id, id.allSatisfy(\.isNumber), path.contains(where: { $0 == "album" || $0 == "song" }) else {
            if path.contains("playlist") {
                throw ResolveError.message("That's a playlist link. Import playlists from the + menu in Library instead.")
            }
            throw ResolveError.message("Paste an Apple Music song or album link.")
        }
        var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
        lookup.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: country)]
        struct Response: Decodable {
            struct Item: Decodable {
                let wrapperType: String?
                let trackName: String?
                let collectionName: String?
                let artistName: String?
            }
            let results: [Item]
        }
        let response: Response = try await getJSON(lookup.url!, service: "Apple Music")
        guard let item = response.results.first, let artist = item.artistName else {
            throw ResolveError.message("Apple Music didn't find that song in this country's store.")
        }
        if item.wrapperType == "track", let title = item.trackName {
            return Resolved(service: "Apple Music", kind: .song, title: title, artist: artist)
        }
        guard let album = item.collectionName else { throw ResolveError.message("Couldn't read that Apple Music link.") }
        return Resolved(service: "Apple Music", kind: .album, title: album, artist: artist)
    }

    private static func deezer(_ url: URL) async throws -> Resolved {
        // deezer.com/en/track/ID or /album/ID
        let path = url.pathComponents.filter { $0 != "/" }
        guard let index = path.firstIndex(where: { $0 == "track" || $0 == "album" }), index + 1 < path.count,
              path[index + 1].allSatisfy(\.isNumber) else {
            throw ResolveError.message("Paste a Deezer song or album link.")
        }
        struct Response: Decodable {
            struct Artist: Decodable { let name: String }
            let title: String?
            let artist: Artist?
        }
        let response: Response = try await getJSON(URL(string: "https://api.deezer.com/\(path[index])/\(path[index + 1])")!,
                                                   service: "Deezer")
        guard let title = response.title, let artist = response.artist?.name else {
            throw ResolveError.message("Deezer didn't find that link.")
        }
        return Resolved(service: "Deezer", kind: path[index] == "album" ? .album : .song, title: title, artist: artist)
    }

    private static func soundCloud(_ url: URL) async throws -> Resolved {
        var oEmbed = URLComponents(string: "https://soundcloud.com/oembed")!
        oEmbed.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
        struct Response: Decodable {
            let title: String
            let author_name: String
        }
        let response: Response = try await getJSON(oEmbed.url!, service: "SoundCloud")
        // The title reads "Song by Uploader".
        var title = response.title
        if title.hasSuffix(" by " + response.author_name) { title = String(title.dropLast(response.author_name.count + 4)) }
        let (song, artist) = splitVideoTitle(title, channel: response.author_name)
        return Resolved(service: "SoundCloud", kind: .song, title: song, artist: artist)
    }

    /// Any other music page (Tidal, Amazon Music, Bandcamp…): its preview tags usually name the song.
    private static func anyPage(_ url: URL) async throws -> Resolved {
        let service = host(of: url)
        let tags = try await pageTags(url, service: service)
        guard var title = tags["og:title"] ?? tags["twitter:title"], !title.isEmpty else {
            throw ResolveError.message("Couldn't find a song on that page. Links from Spotify, Apple Music, YouTube Music, YouTube, Deezer and SoundCloud work best.")
        }
        var artist = tags["music:musician_description"] ?? ""
        if artist.isEmpty, let range = title.range(of: " by ", options: .backwards) {
            artist = String(title[range.upperBound...])
            title = String(title[..<range.lowerBound])
        }
        if artist.isEmpty {
            let split = splitVideoTitle(title, channel: "")
            title = split.title
            artist = split.artist
        }
        let name = service.split(separator: ".").dropLast().last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? service
        return Resolved(service: name, kind: .song, title: title, artist: artist)
    }

    // MARK: Titles

    /// "Artist - Song (Official Video)" on a channel → (song, artist). Topic channels
    /// ("Artist - Topic", YouTube Music's auto-made ones) already have the plain song name.
    static func splitVideoTitle(_ rawTitle: String, channel: String) -> (title: String, artist: String) {
        var channelArtist = channel
        for suffix in [" - Topic", "VEVO", " Official", " official"] where channelArtist.hasSuffix(suffix) {
            channelArtist = String(channelArtist.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        if channel.hasSuffix(" - Topic") { return (plainTitle(rawTitle), channelArtist) }

        var title = rawTitle
        // Japanese style: 【MV】Artist「Song」
        if let open = title.firstIndex(where: { $0 == "「" || $0 == "『" }),
           let close = title[open...].firstIndex(where: { $0 == "」" || $0 == "』" }) {
            let song = String(title[title.index(after: open)..<close])
            let before = stripBrackets(String(title[..<open])).trimmingCharacters(in: .whitespaces)
            return (song, before.isEmpty ? channelArtist : before)
        }
        title = stripBrackets(title)
        for dash in [" - ", " – ", " — ", " ー "] {
            if let range = title.range(of: dash) {
                let artist = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let song = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !song.isEmpty { return (plainTitle(song), artist) }
            }
        }
        return (plainTitle(title), channelArtist)
    }

    /// Drops video extras: "(Official Video)", "[Lyrics]", "【MV】", "| Live at…".
    private static func stripBrackets(_ text: String) -> String {
        var result = text
        let extras = #"official|video|audio|lyric|lyrics|visuali[sz]er|\bmv\b|m/v|\bhd\b|\b4k\b|\bhq\b|remaster|explicit"#
        for pattern in [#"\(([^)]*)\)"#, #"\[([^\]]*)\]"#, #"【([^】]*)】"#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
                if result[inner].range(of: extras, options: [.regularExpression, .caseInsensitive]) != nil {
                    result.removeSubrange(whole)
                }
            }
        }
        if let bar = result.range(of: " | ") { result = String(result[..<bar.lowerBound]) }
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The song title without "(feat. …)" or " - 2011 Remaster".
    static func plainTitle(_ title: String) -> String {
        stripBrackets(title)
            .replacingOccurrences(of: #"\s*[\(\[](feat|ft|with)\.?\s[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(feat|ft)\.?\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+-\s+.*(remaster|version|edit|mix|live).*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Network

    private static let shortLinkHosts: Set<String> = ["spotify.link", "spotify.app.link", "deezer.page.link", "link.deezer.com",
                                                      "on.soundcloud.com", "apple.co", "music.app.goo.gl"]

    private static func link(from text: String) -> URL? {
        var text = text
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    /// The host without "www.".
    private static func host(of url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private static func finalURL(of url: URL) async throws -> URL {
        let (_, response) = try await URLSession.shared.data(for: request(url))
        guard let final = response.url else { return url }
        // spotify.link lands on a page that redirects with JavaScript; its preview tags still
        // carry the real address.
        if host(of: final) != "open.spotify.com", host(of: url).contains("spotify"),
           let address = try? await pageTags(final, service: "Spotify")["og:url"], let real = URL(string: address) {
            return real
        }
        return final
    }

    private static func getJSON<T: Decodable>(_ url: URL, service: String) async throws -> T {
        let data = try await get(url, service: service)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ResolveError.message("Couldn't read \(service)'s answer for that link.")
        }
    }

    private static func get(_ url: URL, service: String) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request(url))
        } catch {
            throw ResolveError.message("Couldn't reach \(service): \(error.localizedDescription)")
        }
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 400 || status == 401 || status == 403 {
            throw ResolveError.message("\(service) couldn't find that link. If it's private or region-locked, search by name instead.")
        }
        guard status == 200 else { throw ResolveError.message("\(service) answered \(status).") }
        return data
    }

    /// A page's <meta property/name … content> tags.
    private static func pageTags(_ url: URL, service: String) async throws -> [String: String] {
        let html = String(decoding: try await get(url, service: service), as: UTF8.self)
        let regex = try! NSRegularExpression(pattern: #"<meta\s+[^>]*>"#, options: [.caseInsensitive])
        let attribute = try! NSRegularExpression(pattern: #"(property|name|content)\s*=\s*"([^"]*)""#, options: [.caseInsensitive])
        var tags: [String: String] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            var key: String?, value: String?
            for pair in attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let nameRange = Range(pair.range(at: 1), in: tag), let valueRange = Range(pair.range(at: 2), in: tag) else { continue }
                if tag[nameRange].lowercased() == "content" { value = String(tag[valueRange]) } else { key = String(tag[valueRange]) }
            }
            if let key, let value, tags[key] == nil { tags[key] = decodeEntities(value) }
        }
        return tags
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}
