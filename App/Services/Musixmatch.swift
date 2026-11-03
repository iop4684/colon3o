import Foundation

/// Musixmatch, the biggest lyrics catalogue: line-synced lyrics, often word-synced ("richsync"),
/// and for Japanese, Korean and Chinese songs often a romanization written by people.
///
/// It has no public API for this: like EeveeSpotify, colon3o talks to the endpoints Musixmatch's
/// own iOS app uses, with the anonymous token that app is handed. So it can stop working, or start
/// asking for a captcha, at any time; the other sources carry on regardless.
actor Musixmatch {
    static let shared = Musixmatch()

    struct Result {
        let lyrics: Lyrics
        /// The lyrics as .lrc text (word timings included when there are any), or nil for none.
        let lrc: String?
        /// Romanized lines by their original text (see `key(_:)`), when Musixmatch has them.
        let romanized: [String: String]
    }

    enum Failure: LocalizedError {
        case noToken, captcha, server(Int)
        var errorDescription: String? {
            switch self {
            case .noToken: return "Musixmatch didn't hand out a token"
            case .captcha: return "Musixmatch is asking for a captcha"
            case let .server(code): return "Musixmatch answered \(code)"
            }
        }
    }

    private static let base = "https://apic-appmobile.musixmatch.com/ws/1.1/"
    /// Musixmatch's iOS app, then its desktop app, as it introduces itself.
    private static let appIDs = ["mac-ios-v2.0", "web-desktop-app-v1.0"]
    private var token: (value: String, appID: String)?

    // MARK: Lyrics

    /// nil when Musixmatch doesn't have the song; throws when it couldn't be asked.
    func fetch(title: String, artist: String, album: String?, duration: Double) async throws -> Result? {
        var query = ["q_track": title, "q_artist": artist, "subtitle_format": "mxm"]
        if let album, !album.isEmpty { query["q_album"] = album }
        if duration > 0 { query["q_duration"] = String(Int(duration.rounded())) }
        let message = try await call("macro.subtitles.get", query)
        guard let calls = (message["body"] as? [String: Any])?["macro_calls"] as? [String: Any],
              let match = Self.body(of: calls["matcher.track.get"])?["track"] as? [String: Any]
        else { return nil }

        // The matcher can be loose: make sure it's the same song.
        if let found = match["track_name"] as? String,
           !Self.titlesMatch(found, title) {
            Diagnostics.shared.log("Musixmatch: best match for \(artist) – \(title) was \(found); skipped", category: "lyrics")
            return nil
        }
        if (match["instrumental"] as? Int) == 1 { return Result(lyrics: .instrumental, lrc: nil, romanized: [:]) }
        let commonTrack = (match["commontrack_id"] as? Int).map(String.init)

        var lrc: String?
        var language: String?
        // Word-synced, when Musixmatch has it.
        if (match["has_richsync"] as? Int) == 1, let commonTrack,
           let richsync = try? await richsync(commonTrack: commonTrack, duration: duration) {
            lrc = richsync
        }
        // Line-synced.
        if let subtitle = ((Self.body(of: calls["track.subtitles.get"])?["subtitle_list"] as? [[String: Any]])?
            .first?["subtitle"] as? [String: Any]), (subtitle["restricted"] as? Int ?? 0) == 0 {
            language = subtitle["subtitle_language"] as? String
            if lrc == nil, let body = subtitle["subtitle_body"] as? String { lrc = Self.lrc(fromSubtitles: body) }
        }
        var lyrics: Lyrics?
        if let lrc {
            let lines = LyricsService.parseLRC(lrc)
            if !lines.isEmpty { lyrics = .synced(lines) }
        }
        // Plain text.
        if let entry = Self.body(of: calls["track.lyrics.get"])?["lyrics"] as? [String: Any],
           (entry["restricted"] as? Int ?? 0) == 0 {
            language = language ?? entry["lyrics_language"] as? String
            if lyrics == nil, let text = (entry["lyrics_body"] as? String).map(Self.withoutFooter), !text.isEmpty {
                lyrics = .plain(text.components(separatedBy: "\n"))
                lrc = text
            }
        }
        guard let lyrics else { return nil }

        var romanized: [String: String] = [:]
        if let language, ["ja", "ko", "zh"].contains(language), let commonTrack {
            romanized = (try? await romanization(commonTrack: commonTrack, language: language)) ?? [:]
        }
        return Result(lyrics: lyrics, lrc: lrc, romanized: romanized)
    }

    /// `[{"ts": 12.3, "te": 15.1, "l": [{"c": "word", "o": 0.0}, {"c": " ", "o": 0.4}, …], "x": "line"}, …]`
    /// as enhanced LRC: `[00:12.30]<00:12.30>word <00:12.70>next<00:15.10>`.
    private func richsync(commonTrack: String, duration: Double) async throws -> String? {
        var query = ["commontrack_id": commonTrack]
        if duration > 0 { query["f_richsync_length"] = String(Int(duration.rounded())) }
        let message = try await call("track.richsync.get", query)
        guard let body = ((message["body"] as? [String: Any])?["richsync"] as? [String: Any])?["richsync_body"] as? String,
              let lines = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]
        else { return nil }
        var out: [String] = []
        for line in lines {
            guard let start = line["ts"] as? Double else { continue }
            let end = line["te"] as? Double
            let pieces = line["l"] as? [[String: Any]] ?? []
            var text = "[\(PetitLyrics.stamp(Int(start * 1000)))]"
            for piece in pieces {
                let characters = piece["c"] as? String ?? ""
                guard !characters.trimmingCharacters(in: .whitespaces).isEmpty else {
                    text += characters  // spaces belong to the word before
                    continue
                }
                let offset = piece["o"] as? Double ?? 0
                text += "<\(PetitLyrics.stamp(Int((start + offset) * 1000)))>\(characters)"
            }
            if pieces.isEmpty { text += line["x"] as? String ?? "" }
            if let end, !pieces.isEmpty { text += "<\(PetitLyrics.stamp(Int(end * 1000)))>" }
            out.append(text)
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// `[{"text": "line", "time": {"total": 12.34}}, …]` as LRC.
    private static func lrc(fromSubtitles body: String) -> String? {
        guard let lines = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]] else { return nil }
        let out = lines.compactMap { line -> String? in
            guard let total = (line["time"] as? [String: Any])?["total"] as? Double else { return nil }
            return "[\(PetitLyrics.stamp(Int(total * 1000)))]\(line["text"] as? String ?? "")"
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// Musixmatch's romanization ("rj" for Japanese, "rk" Korean, "rz" Chinese), by original line.
    private func romanization(commonTrack: String, language: String) async throws -> [String: String] {
        let message = try await call("crowd.track.translations.get",
                                     ["commontrack_id": commonTrack, "selected_language": "r" + language.prefix(1)])
        let list = (message["body"] as? [String: Any])?["translations_list"] as? [[String: Any]] ?? []
        var result: [String: String] = [:]
        for item in list {
            guard let translation = item["translation"] as? [String: Any],
                  let original = (translation["subtitle_matched_line"] as? String) ?? (translation["matched_line"] as? String),
                  let romanized = translation["description"] as? String,
                  !romanized.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            result[Self.key(original)] = romanized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// How a line is looked up in a romanization: letters and digits only (kana and kanji
    /// included), so spacing and punctuation differences between sources don't matter.
    nonisolated static func key(_ line: String) -> String {
        String(line.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    // MARK: Requests

    private func call(_ method: String, _ parameters: [String: String], retried: Bool = false) async throws -> [String: Any] {
        let token = try await currentToken()
        var components = URLComponents(string: Self.base + method)!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "app_id", value: token.appID), URLQueryItem(name: "usertoken", value: token.value),
               URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw Failure.server(0) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? [String: Any]
        else { throw Failure.server(status) }
        let header = message["header"] as? [String: Any]
        let code = header?["status_code"] as? Int ?? 200
        if code == 401 {
            forgetToken()
            if (header?["hint"] as? String) == "captcha" { throw Failure.captcha }
            if !retried { return try await call(method, parameters, retried: true) }
            throw Failure.noToken
        }
        if code == 404 { return [:] }
        guard code == 200 else { throw Failure.server(code) }
        return message
    }

    private func currentToken() async throws -> (value: String, appID: String) {
        if let token { return token }
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "musixmatch.token"), let appID = defaults.string(forKey: "musixmatch.appID") {
            token = (value, appID)
            return (value, appID)
        }
        for appID in Self.appIDs {
            guard let url = URL(string: Self.base + "token.get?app_id=\(appID)&format=json"),
                  let answer = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15)),
                  let body = (((try? JSONSerialization.jsonObject(with: answer.0)) as? [String: Any])?["message"] as? [String: Any])?["body"] as? [String: Any],
                  let value = body["user_token"] as? String, !value.isEmpty, value != "UpgradeRequired"
            else { continue }
            defaults.set(value, forKey: "musixmatch.token")
            defaults.set(appID, forKey: "musixmatch.appID")
            token = (value, appID)
            return (value, appID)
        }
        throw Failure.noToken
    }

    private func forgetToken() {
        token = nil
        UserDefaults.standard.removeObject(forKey: "musixmatch.token")
        UserDefaults.standard.removeObject(forKey: "musixmatch.appID")
    }

    // MARK: Helpers

    /// A macro call's body, when that call succeeded.
    private static func body(of call: Any?) -> [String: Any]? {
        guard let message = (call as? [String: Any])?["message"] as? [String: Any],
              (message["header"] as? [String: Any])?["status_code"] as? Int == 200 else { return nil }
        return message["body"] as? [String: Any]
    }

    /// Plain lyrics end with "******* This Lyrics is NOT for Commercial use *******" and an id.
    private static func withoutFooter(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let footer = lines.firstIndex(where: { $0.hasPrefix("*******") }) { lines = Array(lines[..<footer]) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = TrackMatcher.normalizeTitle(a), y = TrackMatcher.normalizeTitle(b)
        guard !x.isEmpty, !y.isEmpty else { return true }
        return x == y || x.contains(y) || y.contains(x)
    }
}
