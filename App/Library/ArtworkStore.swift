import CoreImage
import Foundation
import ImageIO
import SoulseekKit
import UIKit

/// Finds and caches cover art. Order for library items:
/// 0. a cover the user picked in the app (kept in Application Support, files untouched)
/// 1. an image file next to the music (cover.jpg, folder.jpg, …)
/// 2. art embedded in the audio file (extracted once into the cache folder)
/// 3. an iTunes Search lookup, if enabled in Settings
actor ArtworkStore {
    static let shared = ArtworkStore()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var folderImages: [String: URL?] = [:]
    private var missingEmbedded = Set<String>()
    /// Covers being looked up at Apple in the background to replace a small one.
    private var upgrading = Set<String>()

    /// Posted (object: the source's key) when a sharper cover from Apple replaced a small one.
    nonisolated static let upgradedNotification = Notification.Name("colon3o.artworkUpgraded")

    nonisolated let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        memory.countLimit = 400
    }

    /// `maxPixel` is the longest edge in pixels; images are decoded at (roughly) that size.
    func image(for source: ArtworkSource, maxPixel: Int) async -> UIImage? {
        let bucket = [160, 320, 640, 1200, 1600].first { $0 >= maxPixel } ?? 1600
        let cacheKey = "\(source.key)@\(bucket)" as NSString
        if let cached = memory.object(forKey: cacheKey) { return cached }

        guard let file = await file(for: source) else {
            hadMisses = true
            return nil
        }
        let image = await Task.detached(priority: .userInitiated) { Self.downsample(file, maxPixel: bucket) }.value
        if let image { memory.setObject(image, forKey: cacheKey) } else { hadMisses = true }
        return image
    }

    /// Raw image data at full size (Now Playing info, sharing).
    func file(for source: ArtworkSource) async -> URL? {
        let key = source.key
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.resolve(source) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Forget everything about this source (e.g. after a new cover was downloaded).
    func invalidate(_ source: ArtworkSource) {
        // NSCache can't enumerate keys; clear it wholesale, it refills quickly.
        memory.removeAllObjects()
        folderImages.removeAll()
        missingEmbedded.removeAll()
        let hash = MD5.hex(source.key)
        for prefix in ["emb-", "web-"] {
            for ext in ["img", "none"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(prefix)\(hash).\(ext)"))
            }
        }
    }

    /// Deletes extracted and downloaded covers (folder images next to the music are untouched).
    func clearDisk() {
        memory.removeAllObjects()
        folderImages.removeAll()
        missingEmbedded.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Re-check folders for cover files next time, without dropping decoded images.
    func forgetFolderListings() {
        folderImages.removeAll()
    }

    func invalidateFolders() {
        folderImages.removeAll()
        memory.removeAllObjects()
    }

    /// Covers looked for while the files couldn't be read (phone locked) were remembered as
    /// missing; look for them again.
    func forgetMisses() {
        folderImages.removeAll()
        missingEmbedded.removeAll()
        hadMisses = false
    }

    /// Some cover couldn't be shown since the last check (it may only have been unreadable for
    /// a moment, while the phone was locked).
    private var hadMisses = false
    func takeMisses() -> Bool {
        defer { hadMisses = false }
        return hadMisses
    }

    // MARK: Custom covers

    nonisolated static let overridesDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkOverrides", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static func overrideURL(for source: ArtworkSource) -> URL {
        overridesDirectory.appendingPathComponent(MD5.hex(source.key) + ".img")
    }

    /// Checked while drawing lists (every playlist row), so the answer is kept in memory instead of
    /// asking the file system each time.
    nonisolated static func hasOverride(for source: ArtworkSource) -> Bool {
        let key = source.key
        overrideLock.lock()
        defer { overrideLock.unlock() }
        if let known = knownOverrides[key] { return known }
        let exists = FileManager.default.fileExists(atPath: overrideURL(for: source).path)
        knownOverrides[key] = exists
        return exists
    }

    private nonisolated static let overrideLock = NSLock()
    nonisolated(unsafe) private static var knownOverrides: [String: Bool] = [:]

    nonisolated static func forgetOverrideState(_ source: ArtworkSource) {
        overrideLock.lock()
        knownOverrides[source.key] = nil
        overrideLock.unlock()
    }

    /// Saves picked image data as this album's or song's cover. Rejects anything ImageIO can't read.
    func setOverride(_ data: Data, for source: ArtworkSource) -> Bool {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) > 0 else { return false }
        guard (try? data.write(to: Self.overrideURL(for: source), options: .atomic)) != nil else { return false }
        Self.forgetOverrideState(source)
        invalidate(source)
        return true
    }

    func removeOverride(for source: ArtworkSource) {
        try? FileManager.default.removeItem(at: Self.overrideURL(for: source))
        Self.forgetOverrideState(source)
        invalidate(source)
    }

    // MARK: Resolution

    private func resolve(_ source: ArtworkSource) async -> URL? {
        if case .remote = source {} else {
            let custom = Self.overrideURL(for: source)
            if FileManager.default.fileExists(atPath: custom.path) { return custom }
        }
        switch source {
        case let .album(album):
            let local = folderImage(in: album.folder)
            if !AppSettings.preferAppleArtwork, let local, Self.pixelSize(local) >= Self.goodEnough { return local }
            var inFile: URL?
            for track in album.tracks where track.hasEmbeddedArt {
                if let found = await embedded(track, cacheKey: source.key) { inFile = found; break }
            }
            // Small or no art of its own: Apple's copy of the same cover, when the album is found
            // there under the same name and artist, is usually far sharper.
            return await withApple(Self.sharper(local, inFile), source: source, query: "\(album.artist) \(album.title)",
                                   entity: "album", expect: .init(album: album.title, artist: album.artist))

        case let .track(track):
            let local = isLibraryRoot(track.folder) ? nil : folderImage(in: track.folder)
            if !AppSettings.preferAppleArtwork, let local, Self.pixelSize(local) >= Self.goodEnough { return local }
            let inFile = track.hasEmbeddedArt ? await embedded(track, cacheKey: source.key) : nil
            return await withApple(Self.sharper(local, inFile), source: source, query: "\(track.artist) \(track.title)",
                                   entity: "song", expect: .init(album: track.album, artist: track.artist, title: track.title))

        case let .remote(query):
            return await online(query: query, entity: "album", cacheKey: source.key)

        case .playlist:
            return nil  // the chosen picture was returned above; otherwise the mosaic is drawn
        }
    }

    /// The cover to show now: the song's own when it's sharp; otherwise Apple's if it was fetched
    /// before and is sharper. A small cover of its own is shown straight away while Apple's is
    /// looked up in the background (lookups are spaced out, and a library of small covers would
    /// otherwise wait minutes); with no cover at all, the lookup is waited for.
    private func withApple(_ own: URL?, source: ArtworkSource, query: String, entity: String,
                           expect: CoverLookup.Expected) async -> URL? {
        // Apple's covers are the publisher's originals; the ones that come with downloads are often
        // scans, re-saved many times or padded with borders, even when they're big. So by default
        // Apple's is used whenever the album is found there, and the song's own only otherwise.
        let preferApple = AppSettings.preferAppleArtwork
        if !preferApple, let own, Self.pixelSize(own) >= Self.goodEnough { return own }
        let fetched = directory.appendingPathComponent("web-\(MD5.hex(source.key)).img")
        if FileManager.default.fileExists(atPath: fetched.path) {
            return preferApple ? fetched : Self.sharper(own, fetched)
        }
        guard let own else {
            return await online(query: query, entity: entity, cacheKey: source.key, expect: expect)
        }
        let key = source.key
        if !upgrading.contains(key) {
            upgrading.insert(key)
            Task {
                let apple = await self.online(query: query, entity: entity, cacheKey: key, expect: expect)
                await self.finishUpgrade(key, own: own, apple: apple)
            }
        }
        return own
    }

    enum AppleCover { case using, alreadyUsing, notFound, unreachable, off }

    /// Looks up Apple's copy of this cover now, ahead of the background queue, and says how it went.
    /// For the album you're looking at and for Refresh Artwork.
    func appleCoverNow(for source: ArtworkSource, retryMisses: Bool = false) async -> AppleCover {
        guard AppSettings.preferAppleArtwork else { return .off }
        let query: String, entity: String, expect: CoverLookup.Expected
        switch source {
        case let .album(album):
            (query, entity, expect) = ("\(album.artist) \(album.title)", "album", .init(album: album.title, artist: album.artist))
        case let .track(track):
            (query, entity, expect) = ("\(track.artist) \(track.title)", "song",
                                       .init(album: track.album, artist: track.artist, title: track.title))
        default:
            return .off
        }
        let key = source.key
        let hash = MD5.hex(key)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("web-\(hash).img").path) { return .alreadyUsing }
        // Refresh Artwork tries an earlier miss again; just opening the album doesn't.
        if retryMisses { try? FileManager.default.removeItem(at: directory.appendingPathComponent("web-\(hash).none")) }
        let found = await online(query: query, entity: entity, cacheKey: key, expect: expect, urgent: true)
        if found != nil {
            for bucket in [160, 320, 640, 1200, 1600] { memory.removeObject(forKey: "\(key)@\(bucket)" as NSString) }
            return .using
        }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("web-\(hash).none").path) ? .notFound : .unreachable
    }

    private func finishUpgrade(_ key: String, own: URL, apple: URL?) {
        upgrading.remove(key)
        guard let apple, AppSettings.preferAppleArtwork || Self.pixelSize(apple) > Self.pixelSize(own) else { return }
        for bucket in [160, 320, 640, 1200, 1600] { memory.removeObject(forKey: "\(key)@\(bucket)" as NSString) }
        NotificationCenter.default.post(name: Self.upgradedNotification, object: key)
    }

    private func isLibraryRoot(_ folder: URL) -> Bool {
        folder.lastPathComponent == "Music" && folder.deletingLastPathComponent().lastPathComponent == "Documents"
    }

    private func folderImage(in folder: URL) -> URL? {
        let key = folder.standardizedFileURL.path
        if let known = folderImages[key] { return known }
        let found = Self.findFolderImage(in: folder)
        folderImages[key] = found
        return found
    }

    /// A cover this big (longest side, in pixels) is sharp everywhere it's shown, even the full
    /// width of the player on a large iPhone.
    nonisolated static let goodEnough = 1000

    /// The image's longest side in pixels, read from its header only (0 if unreadable).
    nonisolated static func pixelSize(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height)
    }

    /// The bigger of a folder's cover file and the art inside the song file. (A small folder.jpg,
    /// often 200 pixels, used to win over full-size art in the file, so covers looked blurry
    /// in some places and sharp in others.)
    nonisolated static func sharper(_ a: URL?, _ b: URL?) -> URL? {
        guard let a else { return b }
        guard let b else { return a }
        return pixelSize(b) > pixelSize(a) ? b : a
    }

    /// Backs, discs, inlays and booklet pages: never the cover when anything else is there.
    nonisolated static func isNotFront(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["back", "cd", "disc", "disk", "inlay", "inside", "tray", "booklet", "matrix", "obi", "spine"]
            .contains { name.contains($0) } && !name.contains("front") && !name.contains("cover")
    }

    nonisolated static func findFolderImage(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return nil }
        let all = contents.filter { LibraryStore.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !all.isEmpty else { return nil }
        let fronts = all.filter { !isNotFront($0.deletingPathExtension().lastPathComponent) }
        let images = fronts.isEmpty ? all : fronts
        // Several likely covers (cover.jpg and a small folder.jpg): the sharpest one.
        let named = images.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return ["cover", "folder", "front", "album", "artwork", "art"].contains { name.contains($0) }
        }
        if named.count > 1 { return named.max { pixelSize($0) < pixelSize($1) } }
        let preferred = ["cover", "folder", "front", "album", "artwork", "art"]
        for name in preferred {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        for name in preferred {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().contains(name) }) {
                return match
            }
        }
        // Otherwise the biggest image, which is usually the front cover rather than a scan of the disc.
        func size(_ url: URL) -> Int {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.fileSize ?? 0
        }
        return images.max { size($0) < size($1) }
    }

    private func embedded(_ track: Track, cacheKey: String) async -> URL? {
        let file = directory.appendingPathComponent("emb-\(MD5.hex(cacheKey)).img")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !missingEmbedded.contains(track.id) else { return nil }
        guard let data = await MetadataReader.embeddedArtwork(url: track.url),
              (try? data.write(to: file, options: .atomic)) != nil else {
            missingEmbedded.insert(track.id)
            return nil
        }
        return file
    }

    private func online(query: String, entity: String, cacheKey: String, expect: CoverLookup.Expected? = nil,
                        urgent: Bool = false) async -> URL? {
        let hash = MD5.hex(cacheKey)
        let file = directory.appendingPathComponent("web-\(hash).img")
        let miss = directory.appendingPathComponent("web-\(hash).none")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard AppSettings.artworkLookupEnabled else { return nil }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: miss.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86_400 {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.lowercased() != "unknown artist unknown album" else { return nil }

        switch await CoverLookup.shared.artwork(query: trimmed, entity: entity, expect: expect, urgent: urgent) {
        case let .found(data):
            return (try? data.write(to: file, options: .atomic)) != nil ? file : nil
        case .notFound:
            FileManager.default.createFile(atPath: miss.path, contents: nil)
            return nil
        case .failed:
            return nil  // Network trouble: try again next time
        }
    }

    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: squared(image))
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Covers that aren't square (photos of a CD and its case, 4:3 scans, …) become square: the
    /// whole image centred, with a blurred, slightly darkened copy of itself filling the sides,
    /// so every view, the mini player and the Lock Screen show all of it without cropping.
    nonisolated static func squared(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0, abs(width / height - 1) > 0.02 else { return image }
        let side = max(width, height)
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)

        // Background: the cover scaled to fill the square, blurred.
        let fill = side / min(width, height)
        var background = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        background = background.transformed(by: CGAffineTransform(
            translationX: (side - width * fill) / 2, y: (side - height * fill) / 2))
        background = background
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(side) * 0.04)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.1])
            .cropped(to: canvas)
        guard let backgroundImage = ciContext.createCGImage(background, from: canvas) else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawn through UIImage so UIKit's flipped coordinates are handled for us.
        let rendered = UIGraphicsImageRenderer(size: canvas.size, format: format).image { _ in
            UIImage(cgImage: backgroundImage).draw(in: canvas)
            UIImage(cgImage: image).draw(in: CGRect(x: (side - width) / 2, y: (side - height) / 2,
                                                    width: width, height: height))
        }
        return rendered.cgImage ?? image
    }
}

/// iTunes Search API lookups, spaced out to stay under its rate limit (~20 requests/minute).
actor CoverLookup {
    static let shared = CoverLookup()

    enum Outcome {
        case found(Data)
        case notFound
        case failed
    }

    private var lastRequest = Date.distantPast
    private let spacing: TimeInterval = 3

    /// What the result must match: Apple's catalog often has a different album first (a single, a
    /// compilation), and its cover would replace the right one, so with names given, only a
    /// result with the same album (or song) name and artist is taken.
    struct Expected: Sendable {
        var album: String?
        var artist: String?
        var title: String?
    }

    /// `urgent` skips the queue: for the cover on screen right now (an album you opened, Refresh
    /// Artwork). Background lookups for a whole library are spaced out and can take minutes.
    func artwork(query: String, entity: String, expect: Expected? = nil, urgent: Bool = false) async -> Outcome {
        // Apple's search ranks a short album name ("amo") below the artist's other albums and
        // features, so with names to match, more ways in are tried until one finds it:
        // 1. "artist album", 2. the album name alone as an album name, 3. every album the
        //    artist has. (Songs: "artist title", then the title alone as a song name.)
        var attempts: [[URLQueryItem]] = [[.init(name: "term", value: query), .init(name: "entity", value: entity),
                                           .init(name: "limit", value: expect == nil ? "3" : "50")]]
        if let expect {
            if entity == "album", let album = expect.album, !album.isEmpty {
                attempts.append([.init(name: "term", value: album), .init(name: "entity", value: "album"),
                                 .init(name: "attribute", value: "albumTerm"), .init(name: "limit", value: "200")])
            } else if let title = expect.title, !title.isEmpty {
                attempts.append([.init(name: "term", value: title), .init(name: "entity", value: "song"),
                                 .init(name: "attribute", value: "songTerm"), .init(name: "limit", value: "200")])
            }
        }
        var failed = false
        var seen: [SearchResponse.Result] = []
        for items in attempts {
            switch await search(items, urgent: urgent) {
            case let .some(results):
                seen += results
                if let pick = choose(results, expect) { return await download(pick, query: query) }
            case .none:
                failed = true
            }
        }
        if entity == "album", let expect, let artist = expect.artist, let album = expect.album, !album.isEmpty,
           !["various artists", "unknown artist"].contains(artist.lowercased()),
           let results = await artistAlbums(artist, urgent: urgent) {
            seen += results
            if let pick = choose(results, expect) { return await download(pick, query: query) }
        }
        if failed && seen.isEmpty { return .failed }
        let shown = seen.prefix(3).map { "\($0.collectionName ?? "?") by \($0.artistName ?? "?")" }.joined(separator: "; ")
        Diagnostics.shared.log("Apple cover lookup \"\(query)\": no match among \(seen.count) (\(shown))", category: "artwork")
        return .notFound
    }

    private func choose(_ results: [SearchResponse.Result], _ expect: Expected?) -> SearchResponse.Result? {
        let candidates = results.filter { $0.artworkUrl100 != nil }
        guard let expect else { return candidates.first }
        let matching = candidates.filter { Self.matches($0, expect) }
        // The release with exactly the same name first (the album rather than its deluxe edition).
        let name = expect.album ?? expect.title ?? ""
        return matching.first { Self.similar(expect.album != nil ? $0.collectionName : $0.trackName, name, exactly: true) }
            ?? matching.first
    }

    /// One iTunes Search request (spaced out unless urgent); nil when it failed.
    private func search(_ items: [URLQueryItem], urgent: Bool, path: String = "search") async -> [SearchResponse.Result]? {
        if !urgent {
            let wait = spacing - Date().timeIntervalSince(lastRequest)
            lastRequest = Date().addingTimeInterval(max(wait, 0))
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = items + (path == "search" ? [.init(name: "media", value: "music")] : [])
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Diagnostics.shared.log("Apple cover lookup (\(url.query ?? "")): HTTP \(status)", category: "artwork")
                return nil
            }
            return try JSONDecoder().decode(SearchResponse.self, from: data).results
        } catch {
            Diagnostics.shared.log("Apple cover lookup (\(url.query ?? "")) failed: \(error.localizedDescription)", category: "artwork")
            return nil
        }
    }

    /// All albums of the artist with this name.
    private func artistAlbums(_ artist: String, urgent: Bool) async -> [SearchResponse.Result]? {
        guard let artists = await search([.init(name: "term", value: artist), .init(name: "entity", value: "musicArtist"),
                                          .init(name: "limit", value: "5")], urgent: urgent),
              let id = artists.first(where: { Self.similar($0.artistName, artist) })?.artistId else { return nil }
        return await search([.init(name: "id", value: String(id)), .init(name: "entity", value: "album"),
                             .init(name: "limit", value: "200")], urgent: urgent, path: "lookup")
    }

    private func download(_ pick: SearchResponse.Result, query: String) async -> Outcome {
        guard let small = pick.artworkUrl100 else { return .notFound }
        Diagnostics.shared.log("Apple cover lookup \"\(query)\": using \(pick.collectionName ?? "?") by \(pick.artistName ?? "?")",
                               category: "artwork")
        // Apple serves any size up to the original; 1500 px is sharp at the player's full width.
        let large = small.replacingOccurrences(of: "100x100bb", with: "1500x1500bb")
        guard let imageURL = URL(string: large) else { return .notFound }
        do {
            let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200, !imageData.isEmpty else { return .failed }
            return .found(imageData)
        } catch {
            return .failed
        }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let artworkUrl100: String?
            let collectionName: String?
            let artistName: String?
            let trackName: String?
            let artistId: Int?
        }
        let results: [Result]
    }

    private static func matches(_ result: SearchResponse.Result, _ expected: Expected) -> Bool {
        if let artist = expected.artist, !["various artists", "unknown artist"].contains(artist.lowercased()),
           !similar(result.artistName, artist) { return false }
        if let album = expected.album, !album.isEmpty { return similar(result.collectionName, album) }
        if let title = expected.title { return similar(result.trackName, title) }
        return true
    }

    /// Same name give or take case, punctuation and an edition note ("(Deluxe Edition)", "- EP").
    private static func similar(_ found: String?, _ wanted: String, exactly: Bool = false) -> Bool {
        guard let found else { return false }
        func plain(_ text: String) -> String {
            var text = text.lowercased()
            text = text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s+-\s+(ep|single)$"#, with: "", options: .regularExpression)
            return String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
        let a = plain(found), b = plain(wanted)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // "Album" vs "Album Remastered"; not "amo" vs "among the …".
        return !exactly && min(a.count, b.count) >= 4 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    /// Turns a Soulseek folder path into an "artist album" search: drops format tags, years and
    /// bracketed junk, and uses the parent folder as the artist when the album folder lacks one.
    static func query(forFolderPath path: String) -> String {
        var parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard !parts.isEmpty else { return "" }
        // "…\Album\CD1" → use the album folder.
        if let last = parts.last, last.range(of: #"^(cd|disc|disk)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           parts.count > 1 {
            parts.removeLast()
        }
        let album = clean(parts[parts.count - 1])
        if album.contains(" - ") || parts.count < 2 { return album.replacingOccurrences(of: " - ", with: " ") }
        let generic: Set<String> = ["music", "musique", "downloads", "complete", "shared", "soulseek", "albums", "mp3", "flac", "audio"]
        let parent = clean(parts[parts.count - 2])
        if generic.contains(parent.lowercased()) || parent.isEmpty { return album }
        return "\(parent) \(album)"
    }

    static func clean(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "_", with: " ")
        let patterns = [
            #"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\{[^}]*\}"#,
            #"(?i)\b(flac|mp3|aac|alac|ogg|opus|wav|320|256|192|v0|v2|vbr|cbr|web|cd|vinyl|lossless|hi-?res|24bit|16bit|24-\d+|16-44|kbps|remaster(ed)?|deluxe edition)\b"#,
            #"\b(19|20)\d{2}\b"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -.–"))
    }
}
