import SwiftUI

/// What colon3o keeps on the phone, worked out by walking its folders.
struct StorageReport: Sendable {
    struct Format: Identifiable, Sendable {
        let name: String
        let bytes: Int64
        let songs: Int
        var id: String { name }
    }

    struct AlbumSize: Identifiable, Sendable {
        let id: String
        let title: String
        let artist: String
        let bytes: Int64
        let songs: Int
    }

    var music: Int64 = 0
    var songs = 0
    var formats: [Format] = []
    /// Covers and .lrc lyrics saved next to the songs.
    var sidecars: Int64 = 0
    /// Partly downloaded files waiting to finish or be retried.
    var incomplete: Int64 = 0
    /// Artwork, lyrics, charts and tracklists fetched online; fetched again when needed.
    var cache: Int64 = 0
    /// Everything else: the library index, stats, playlists, logs and settings.
    var appData: Int64 = 0
    var albums: [AlbumSize] = []
    var freeOnPhone: Int64?

    var total: Int64 { music + sidecars + incomplete + cache + appData }

    /// Caches that can be emptied without losing anything.
    nonisolated static var cacheFolders: [URL] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ["Artwork", "Lyrics", "Charts", "Tracklists"].map { caches.appendingPathComponent($0, isDirectory: true) }
    }

    nonisolated static var incompleteFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Incomplete", isDirectory: true)
    }

    /// Walks the app's folders. `albums` maps each album to its songs' files.
    nonisolated static func measure(musicRoot: URL, albums: [(id: String, title: String, artist: String, files: [URL])]) -> StorageReport {
        var report = StorageReport()
        var fileSizes: [String: Int64] = [:]
        var formats: [String: (bytes: Int64, songs: Int)] = [:]

        for (url, size) in files(in: musicRoot) {
            let ext = url.pathExtension.lowercased()
            if LibraryStore.audioExtensions.contains(ext) {
                report.music += size
                report.songs += 1
                fileSizes[url.standardizedFileURL.path] = size
                let name = ext == "m4b" || ext == "mp4" ? "m4a" : ext == "aif" ? "aiff" : ext
                formats[name, default: (0, 0)].bytes += size
                formats[name, default: (0, 0)].songs += 1
            } else {
                report.sidecars += size
            }
        }
        report.formats = formats.map { Format(name: $0.key.uppercased(), bytes: $0.value.bytes, songs: $0.value.songs) }
            .sorted { $0.bytes > $1.bytes }

        report.incomplete = files(in: incompleteFolder).reduce(0) { $0 + $1.1 }
        report.cache = cacheFolders.reduce(0) { total, folder in total + files(in: folder).reduce(0) { $0 + $1.1 } }

        // Everything in the app's own space, minus what's counted above.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let everything = ["Documents", "Library", "tmp"].reduce(Int64(0)) { total, name in
            total + files(in: home.appendingPathComponent(name, isDirectory: true)).reduce(0) { $0 + $1.1 }
        }
        report.appData = max(everything - report.music - report.sidecars - report.incomplete - report.cache, 0)

        report.albums = albums.map { album in
            let sizes = album.files.compactMap { fileSizes[$0.standardizedFileURL.path] }
            return AlbumSize(id: album.id, title: album.title, artist: album.artist,
                             bytes: sizes.reduce(0, +), songs: album.files.count)
        }
        .filter { $0.bytes > 0 }
        .sorted { $0.bytes > $1.bytes }
        .prefix(10)
        .map { $0 }

        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            report.freeOnPhone = free
        }
        return report
    }

    /// Every regular file under `folder`, with the space it takes on disk.
    nonisolated private static func files(in folder: URL) -> [(URL, Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var found: [(URL, Int64)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append((url, Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)))
        }
        return found
    }
}

/// Settings > Storage: how much space the music and the app's other files take.
struct StorageView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var soulseek: SoulseekModel
    @AppStorage(StorageView.lastTotalKey) private var lastTotal: Double = 0
    @State private var report: StorageReport?
    @State private var working = false
    @State private var confirmIncomplete = false

    static let lastTotalKey = "storage.lastTotal"

    private enum Part: CaseIterable {
        case music, sidecars, incomplete, cache, appData

        var title: String {
            switch self {
            case .music: return "Music"
            case .sidecars: return "Covers & Lyrics Files"
            case .incomplete: return "Unfinished Downloads"
            case .cache: return "Cache"
            case .appData: return "App Data"
            }
        }

        var color: Color {
            switch self {
            case .music: return .pink
            case .sidecars: return .orange
            case .incomplete: return .yellow
            case .cache: return .blue
            case .appData: return .gray
            }
        }

        func bytes(in report: StorageReport) -> Int64 {
            switch self {
            case .music: return report.music
            case .sidecars: return report.sidecars
            case .incomplete: return report.incomplete
            case .cache: return report.cache
            case .appData: return report.appData
            }
        }
    }

    var body: some View {
        Form {
            if let report {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Self.format(report.total)).font(.title2.weight(.bold)).monospacedDigit()
                            Spacer()
                            if let free = report.freeOnPhone {
                                Text("\(Self.format(free)) free on iPhone").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        bar(report)
                    }
                    .padding(.vertical, 4)
                    ForEach(Part.allCases, id: \.self) { part in
                        let bytes = part.bytes(in: report)
                        if bytes > 0 || part == .music {
                            HStack(spacing: 10) {
                                Circle().fill(part.color).frame(width: 10, height: 10)
                                Text(part.title)
                                Spacer()
                                Text(Self.format(bytes)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } footer: {
                    Text("App Data is the library index, stats, playlists, settings and logs.")
                }

                if !report.formats.isEmpty {
                    Section("Music by Format") {
                        ForEach(report.formats) { format in
                            LabeledContent {
                                Text(Self.format(format.bytes)).monospacedDigit()
                            } label: {
                                Text(format.name)
                                Text("\(format.songs) song\(format.songs == 1 ? "" : "s")")
                            }
                        }
                    }
                }

                if !report.albums.isEmpty {
                    Section("Largest Albums") {
                        ForEach(report.albums) { album in
                            LabeledContent {
                                Text(Self.format(album.bytes)).monospacedDigit()
                            } label: {
                                Text(album.title).lineLimit(1)
                                Text("\(album.artist) · \(album.songs) song\(album.songs == 1 ? "" : "s")").lineLimit(1)
                            }
                        }
                    }
                }

                Section {
                    Button("Clear Cache") { clearCache() }
                        .disabled(working || report.cache == 0)
                    if report.incomplete > 0 {
                        Button("Delete Unfinished Downloads", role: .destructive) { confirmIncomplete = true }
                            .disabled(working || soulseek.activeDownloadCount > 0)
                    }
                } footer: {
                    Text(soulseek.activeDownloadCount > 0 && report.incomplete > 0
                         ? "Clearing the cache removes artwork, lyrics and tracklists fetched online; they're fetched again when needed. Unfinished downloads can be deleted once nothing is downloading."
                         : "Clearing the cache removes artwork, lyrics and tracklists fetched online; they're fetched again when needed. Your songs and their .lrc files aren't touched.")
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView("Measuring…")
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Storage")
        .refreshable { await measure() }
        .task(id: library.scanRevision) { await measure() }
        .confirmationDialog("Delete unfinished downloads?", isPresented: $confirmIncomplete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteIncomplete() }
        } message: {
            Text("Failed or cancelled downloads will start again from the beginning if you retry them.")
        }
    }

    private func bar(_ report: StorageReport) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Part.allCases, id: \.self) { part in
                    let share = report.total > 0 ? Double(part.bytes(in: report)) / Double(report.total) : 0
                    if share > 0 {
                        part.color.frame(width: max(geometry.size.width * share - 2, 3))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 12)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
    }

    private func measure() async {
        let root = library.root
        let albums = library.albums.map { (id: $0.id, title: $0.title, artist: $0.artist, files: $0.tracks.map(\.url)) }
        let result = await Task.detached(priority: .userInitiated) {
            StorageReport.measure(musicRoot: root, albums: albums)
        }.value
        report = result
        lastTotal = Double(result.total)
    }

    private func clearCache() {
        working = true
        Task {
            await ArtworkStore.shared.clearDisk()
            await Task.detached {
                for folder in StorageReport.cacheFolders {
                    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                    for file in files { try? FileManager.default.removeItem(at: file) }
                }
            }.value
            library.bumpArtwork()
            await measure()
            working = false
        }
    }

    private func deleteIncomplete() {
        working = true
        Task {
            await Task.detached {
                let folder = StorageReport.incompleteFolder
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files { try? FileManager.default.removeItem(at: file) }
            }.value
            await measure()
            working = false
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
