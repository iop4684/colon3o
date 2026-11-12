import SwiftUI
import UIKit

enum PlaylistRoute: Hashable {
    case user(UUID)
    case favorites
    case mostPlayed
    /// Songs in no playlist (or at most a few): a way to hear what you haven't sorted yet.
    case fewPlaylists

    /// The most playlists a song may be in to show up in `fewPlaylists`.
    static let fewPlaylistsKey = "smart.maxPlaylists"

    var playlistID: UUID? {
        if case let .user(id) = self { return id }
        return nil
    }

    var symbol: String? {
        switch self {
        case .favorites: return "star.fill"
        case .mostPlayed: return "chart.bar.fill"
        case .fewPlaylists: return "tray.fill"
        case .user: return nil
        }
    }

    static func fewPlaylistsName(_ max: Int) -> String {
        max == 0 ? "Not in a Playlist" : "In \(max) Playlist\(max == 1 ? "" : "s") or Fewer"
    }

    /// Songs in at most `max` of your playlists, newest first.
    @MainActor
    static func fewPlaylistsTracks(library: LibraryStore, playlists: PlaylistStore, max: Int) -> [Track] {
        let counts = playlists.membershipCounts()
        return library.tracks.filter { (counts[$0.id] ?? 0) <= max }.sorted { $0.addedAt > $1.addedAt }
    }

    /// The key its listening is counted under in Stats.
    var statsKey: String {
        switch self {
        case let .user(id): return id.uuidString
        case .favorites: return "favorites"
        case .mostPlayed: return "mostPlayed"
        case .fewPlaylists: return "fewPlaylists"
        }
    }
}

/// The Playlists scope of the library: smart lists first, then the user's own.
struct PlaylistsListContent: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var importer: PlaylistImporter
    let query: String

    @State private var naming = false
    @State private var newName = ""
    @State private var reordering = false
    @AppStorage(PlaylistRoute.fewPlaylistsKey) private var maxPlaylists = 0

    private var favoriteTracks: [Track] { library.tracks.filter { favorites.isFavorite($0) } }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Button {
                newName = ""
                naming = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("New Playlist…").foregroundStyle(.tint)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                if playlists.playlists.count > 1 && query.isEmpty {
                    Button("Reorder") { reordering = true }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.trailing, 20)
                }
            }
            Divider().padding(.leading, 98)

            if let job = importer.job {
                importRow(job)
            }

            if query.isEmpty {
                row(route: .favorites, name: "Favorite Songs", tracks: favoriteTracks, symbol: "star.fill")
                row(route: .mostPlayed, name: "Most Played", tracks: stats.mostPlayed(limit: 4, in: library),
                    symbol: "chart.bar.fill", subtitle: "Top 50 by plays")
                let few = PlaylistRoute.fewPlaylistsTracks(library: library, playlists: playlists, max: maxPlaylists)
                row(route: .fewPlaylists, name: PlaylistRoute.fewPlaylistsName(maxPlaylists), tracks: few,
                    symbol: "tray.fill", subtitle: "\(few.count) song\(few.count == 1 ? "" : "s")")
            }

            ForEach(playlists.playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { playlist in
                let tracks = playlists.tracks(of: playlist, in: library)
                row(route: .user(playlist.id), name: playlist.name, tracks: tracks, symbol: nil)
                    .contextMenu {
                        ArtworkMenu(target: .playlist(playlist))
                        Button { player.play(tracks, fromPlaylist: playlist.id.uuidString) } label: {
                            Label("Play", systemImage: "play")
                        }
                        .disabled(tracks.isEmpty)
                        Button { player.play(tracks, shuffled: true, fromPlaylist: playlist.id.uuidString) } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .disabled(tracks.isEmpty)
                        if playlists.playlists.count > 1 {
                            Button { reordering = true } label: {
                                Label("Reorder Playlists…", systemImage: "arrow.up.arrow.down")
                            }
                        }
                        Button(role: .destructive) {
                            Confirm.ask("Delete “\(playlist.name)”?", message: "The songs stay in your library.",
                                        button: "Delete Playlist") { playlists.delete(playlist) }
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    }
            }
        }
        .padding(.bottom, 24)
        .sheet(isPresented: $reordering) { ReorderPlaylistsSheet() }
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { playlists.create(named: newName) }
        }
    }

    /// The running (or last finished) Spotify / Apple Music import; opens its progress.
    private func importRow(_ job: ImportJob) -> some View {
        Button {
            router.showImportProgress()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.15))
                    if job.isRunning {
                        ProgressView()
                    } else {
                        Image(systemName: job.notFoundCount > 0 ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.isRunning ? "Importing “\(job.name)”" : "Imported “\(job.name)”").lineLimit(1)
                    Text(job.isRunning ? "\(job.doneCount) of \(job.songs.count) songs" : ImportProgressView.summary(job))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 98) }
    }

    private func row(route: PlaylistRoute, name: String, tracks: [Track], symbol: String?, subtitle: String? = nil) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                PlaylistArtwork(tracks: tracks, symbol: symbol, playlistID: route.playlistID, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1)
                    Text(subtitle ?? "\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 98) }
    }
}

/// A 2×2 mosaic of the first four different covers, like Apple Music, or the picture chosen with
/// Change Artwork.
struct PlaylistArtwork: View {
    let tracks: [Track]
    var symbol: String?
    /// A user playlist, whose own picture (if one was chosen) replaces the mosaic.
    var playlistID: UUID?
    let size: CGFloat

    @EnvironmentObject private var library: LibraryStore

    private var sources: [ArtworkSource] {
        var seen = Set<String>()
        var result: [ArtworkSource] = []
        for track in tracks {
            let source = library.artwork(for: track)
            if seen.insert(source.key).inserted { result.append(source) }
            if result.count == 4 { break }
        }
        return result
    }

    var body: some View {
        let covers = sources
        let _ = library.artworkRevision  // redraw when a picture is chosen or removed
        Group {
            if let playlistID, ArtworkStore.hasOverride(for: .playlist(playlistID)) {
                ArtworkView(source: .playlist(playlistID), size: size, cornerRadius: 0)
            } else if let symbol {
                ZStack {
                    Rectangle().fill(.tint)
                    LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else if covers.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(source: covers[0], size: half, cornerRadius: 0)
                        ArtworkView(source: covers[1], size: half, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(source: covers[2], size: half, cornerRadius: 0)
                        ArtworkView(source: covers[3], size: half, cornerRadius: 0)
                    }
                }
            } else if let first = covers.first {
                ArtworkView(source: first, size: size, cornerRadius: 0)
            } else {
                ZStack {
                    ArtworkPlaceholder()
                    Image(systemName: "music.note.list").font(.system(size: size * 0.3)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 12 : 8, style: .continuous))
    }
}

struct PlaylistDetailView: View {
    let route: PlaylistRoute

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    @State private var renaming = false
    @State private var newName = ""
    @State private var addingSongs = false
    @State private var confirmDelete = false
    @State private var exportURL: ExportFile?
    @State private var pendingDelete: [Track]?
    @AppStorage(PlaylistRoute.fewPlaylistsKey) private var maxPlaylists = 0

    private var playlist: Playlist? {
        if case let .user(id) = route { return playlists.playlist(id: id) }
        return nil
    }

    private var name: String {
        switch route {
        case .user: return playlist?.name ?? "Playlist"
        case .favorites: return "Favorite Songs"
        case .mostPlayed: return "Most Played"
        case .fewPlaylists: return PlaylistRoute.fewPlaylistsName(maxPlaylists)
        }
    }

    private var tracks: [Track] {
        switch route {
        case .user: return playlist.map { playlists.tracks(of: $0, in: library) } ?? []
        case .favorites:
            return library.tracks.filter { favorites.isFavorite($0) }.sorted { SortKey.less($0.title, $1.title) }
        case .mostPlayed: return stats.mostPlayed(limit: 50, in: library)
        case .fewPlaylists: return PlaylistRoute.fewPlaylistsTracks(library: library, playlists: playlists, max: maxPlaylists)
        }
    }

    var body: some View {
        let tracks = self.tracks
        List {
            header(tracks)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))

            if playlist != nil {
                Button { addingSongs = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 48, height: 48)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text("Add Songs").foregroundStyle(.tint)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .moveDisabled(true)
            }

            ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                Button {
                    player.play(tracks, startAt: offset, fromPlaylist: route.statsKey)
                } label: {
                    HStack(spacing: 10) {
                        if case .mostPlayed = route {
                            Text("\(offset + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 22, alignment: .trailing)
                        }
                        TrackRow(track: track, subtitle: subtitle(for: track))
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    TrackMenuItems(tracks: [track]) { pendingDelete = $0 }
                }
            }
            .onMove(perform: moveAction)
            .onDelete(perform: deleteAction)

            if !tracks.isEmpty {
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(Formatting.longDuration(tracks.reduce(0) { $0 + $1.duration }))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tracks.isEmpty && playlist == nil {
                EmptyStateView(title: "No Songs",
                               message: emptyMessage,
                               systemImage: "music.note.list")
                    .padding(.top, 200)
            }
        }
        .toolbar {
            if let playlist {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Menu {
                        Button { addingSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                        Button {
                            newName = playlist.name
                            renaming = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        ArtworkMenu(target: .playlist(playlist))
                        Button {
                            exportURL = playlists.exportM3U(playlist, library: library).map(ExportFile.init)
                        } label: { Label("Export .m3u8", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let playlist { playlists.rename(playlist, to: newName) } }
        }
        .confirmationDialog("Delete “\(name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let playlist { playlists.delete(playlist) }
                dismiss()
            }
        } message: {
            Text("The songs stay in your library.")
        }
        .sheet(isPresented: $addingSongs) {
            if let playlist { SongPickerSheet(playlist: playlist) }
        }
        .sheet(item: $exportURL) { file in
            ActivityView(items: [file.url]).presentationDetents([.medium, .large])
        }
        .confirmDelete($pendingDelete)
    }

    /// Only user playlists can be reordered or edited.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard let playlist else { return nil }
        return { offsets, destination in
            playlists.move(from: offsets, to: destination, in: playlist, library: library)
        }
    }

    private var deleteAction: ((IndexSet) -> Void)? {
        guard let playlist else { return nil }
        return { offsets in playlists.remove(at: offsets, from: playlist, library: library) }
    }

    private var emptyMessage: String {
        switch route {
        case .user: return "Tap ⋯ › Add Songs, or long-press any song and choose Add to Playlist."
        case .favorites: return "Star songs to collect them here."
        case .mostPlayed: return "Songs you play show up here."
        case .fewPlaylists: return "Every song is in more playlists than that."
        }
    }

    private func subtitle(for track: Track) -> String {
        if case .mostPlayed = route {
            let plays = stats.plays(of: track)
            return "\(track.artist) · \(plays) play\(plays == 1 ? "" : "s")"
        }
        if case .fewPlaylists = route, maxPlaylists > 0 {
            let count = playlists.playlists.filter { $0.trackIDs.contains(track.id) }.count
            return "\(track.artist) · in \(count == 0 ? "no" : String(count)) playlist\(count == 1 ? "" : "s")"
        }
        return track.artist
    }

    private func header(_ tracks: [Track]) -> some View {
        VStack(spacing: 10) {
            PlaylistArtwork(tracks: tracks, symbol: route.symbol, playlistID: route.playlistID, size: 220)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            Text(name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if case .fewPlaylists = route {
                Picker("In at most", selection: $maxPlaylists) {
                    Text("No playlist").tag(0)
                    Text("≤ 1").tag(1)
                    Text("≤ 2").tag(2)
                    Text("≤ 3").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 8)
            }
            HStack(spacing: 12) {
                Button { player.play(tracks, fromPlaylist: route.statsKey) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { player.play(tracks, shuffled: true, fromPlaylist: route.statsKey) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Add to Playlist" from any song menu or selection.
struct AddToPlaylistSheet: View {
    let request: PlaylistRequest

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                ForEach(playlists.playlists) { playlist in
                    let present = Set(playlist.trackIDs)
                    let alreadyIn = request.tracks.filter { present.contains($0.id) }.count
                    let allIn = !request.tracks.isEmpty && alreadyIn == request.tracks.count
                    Button {
                        playlists.add(request.tracks, to: playlist)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistArtwork(tracks: playlists.tracks(of: playlist, in: library), playlistID: playlist.id, size: 48)
                                .opacity(allIn ? 0.55 : 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(subtitle(songs: playlist.trackIDs.count, alreadyIn: alreadyIn, allIn: allIn))
                                    .font(.caption)
                                    .foregroundStyle(alreadyIn > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if allIn {
                                AddedBadge()
                            } else if alreadyIn > 0 {
                                AddedBadge(text: "\(alreadyIn)/\(request.tracks.count)", partial: true)
                            }
                        }
                    }
                    .accessibilityValue(allIn ? "Already added" : (alreadyIn > 0 ? "\(alreadyIn) of \(request.tracks.count) already added" : ""))
                }
            }
            .navigationTitle(request.tracks.count == 1 ? "Add to Playlist" : "Add \(request.tracks.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("New Playlist", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    playlists.create(named: newName, with: request.tracks)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func subtitle(songs: Int, alreadyIn: Int, allIn: Bool) -> String {
        let count = "\(songs) song\(songs == 1 ? "" : "s")"
        if allIn { return request.tracks.count == 1 ? "Already added · \(count)" : "All already added · \(count)" }
        if alreadyIn > 0 { return "\(alreadyIn) of \(request.tracks.count) already added · \(count)" }
        return count
    }
}

/// The pill on Add to Playlist rows showing the song (or some of the songs) is already in that playlist.
private struct AddedBadge: View {
    var text = "Added"
    var partial = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: partial ? "circle.lefthalf.filled" : "checkmark.circle.fill")
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.18), in: Capsule())
        .fixedSize()
    }
}

/// Pick songs from the library to add to a playlist.
/// Add Songs: pick from all songs, or by album or artist (a whole one at once with its + button),
/// with songs already in the playlist hidden. Picks are kept while you search and switch views,
/// and added together.
struct SongPickerSheet: View {
    let playlist: Playlist

    enum Scope: String, CaseIterable, Identifiable {
        case songs = "Songs", albums = "Albums", artists = "Artists"
        var id: String { rawValue }
    }

    enum Order: String, CaseIterable, Identifiable {
        case recent = "Recently Added", title = "Title", artist = "Artist"
        var id: String { rawValue }
    }

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: [String] = []
    @AppStorage("songPicker.scope") private var scope: Scope = .songs
    @AppStorage("songPicker.order") private var order: Order = .recent
    @AppStorage("songPicker.hideAdded") private var hideAdded = true

    /// Songs in the playlist now (it may change while the sheet is open).
    private var included: Set<String> { Set((playlists.playlist(id: playlist.id) ?? playlist).trackIDs) }

    var body: some View {
        let included = self.included
        let picked = Set(chosen)
        NavigationStack {
            Group {
                switch scope {
                case .songs:
                    List {
                        scopePicker
                        songRows(sortedSongs(matching(library.tracks)), included: included, picked: picked)
                        hiddenNote(included: included)
                    }
                case .albums:
                    List {
                        scopePicker
                        ForEach(albums(included: included)) { album in
                            groupRow(title: album.title, subtitle: album.artist, artwork: .album(album),
                                     tracks: album.tracks, included: included, picked: picked) {
                                PickerTrackList(title: album.title, tracks: album.tracks, numbered: true,
                                                included: included, chosen: $chosen, hideAdded: hideAdded)
                            }
                        }
                    }
                case .artists:
                    List {
                        scopePicker
                        ForEach(artists(included: included), id: \.name) { artist in
                            let tracks = artistTracks(artist)
                            groupRow(title: artist.name, subtitle: "\(tracks.count) song\(tracks.count == 1 ? "" : "s")",
                                     artwork: artist.artwork, tracks: tracks, included: included, picked: picked) {
                                PickerTrackList(title: artist.name, tracks: tracks, numbered: false,
                                                included: included, chosen: $chosen, hideAdded: hideAdded)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: scope == .songs ? "Songs, artists, albums" : (scope == .albums ? "Albums, artists" : "Artists"))
            .navigationTitle("Add to \(playlist.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Hide Songs Already Added", isOn: $hideAdded)
                        if scope == .songs {
                            Picker("Sort By", selection: $order) {
                                ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        // Outside the navigation, so the Add button stays while you look inside an album or artist.
        .safeAreaInset(edge: .bottom) {
                if !chosen.isEmpty {
                    HStack(spacing: 12) {
                        Button("Clear") { chosen.removeAll() }
                            .buttonStyle(.bordered)
                        Button {
                            playlists.add(chosen.compactMap { library.track(id: $0) }, to: playlist)
                            dismiss()
                        } label: {
                            Text("Add \(chosen.count) Song\(chosen.count == 1 ? "" : "s")")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
        }
    }

    private var scopePicker: some View {
        Picker("View", selection: $scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func songRows(_ tracks: [Track], included: Set<String>, picked: Set<String>) -> some View {
        ForEach(tracks.filter { !hideAdded || !included.contains($0.id) }) { track in
            PickerSongRow(track: track, subtitle: [track.artist, track.album].compactMap { $0 }.joined(separator: " · "),
                          isIncluded: included.contains(track.id), isPicked: picked.contains(track.id)) {
                toggle(track.id)
            }
        }
    }

    @ViewBuilder
    private func hiddenNote(included: Set<String>) -> some View {
        let hidden = hideAdded ? library.tracks.filter { included.contains($0.id) }.count : 0
        if hidden > 0 {
            Text("\(hidden) song\(hidden == 1 ? " is" : "s are") already in this playlist and hidden.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
    }

    /// An album or artist: tap it to pick songs from it, or its button to pick all of it at once.
    private func groupRow<Destination: View>(title: String, subtitle: String, artwork: ArtworkSource?, tracks: [Track],
                                             included: Set<String>, picked: Set<String>,
                                             @ViewBuilder destination: @escaping () -> Destination) -> some View {
        let available = tracks.filter { !included.contains($0.id) }
        let pickedCount = available.filter { picked.contains($0.id) }.count
        let all = !available.isEmpty && pickedCount == available.count
        return HStack(spacing: 12) {
            NavigationLink {
                destination()
            } label: {
                HStack(spacing: 12) {
                    if let artwork {
                        ArtworkView(source: artwork, size: 48, cornerRadius: 6)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).lineLimit(1)
                        Text(pickedCount > 0 ? "\(subtitle) · \(pickedCount) picked" : subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Button {
                if all {
                    let ids = Set(available.map(\.id))
                    chosen.removeAll { ids.contains($0) }
                } else {
                    for track in available where !picked.contains(track.id) { chosen.append(track.id) }
                }
            } label: {
                Image(systemName: available.isEmpty ? "checkmark.circle" : (all ? "checkmark.circle.fill" : (pickedCount > 0 ? "plus.circle.fill" : "plus.circle")))
                    .font(.title2)
                    .foregroundStyle(available.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderless)
            .disabled(available.isEmpty)
        }
    }

    private func toggle(_ id: String) {
        if let index = chosen.firstIndex(of: id) { chosen.remove(at: index) } else { chosen.append(id) }
    }

    private func matching(_ tracks: [Track]) -> [Track] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.artist.localizedCaseInsensitiveContains(text)
                || ($0.album ?? "").localizedCaseInsensitiveContains(text)
        }
    }

    private func sortedSongs(_ tracks: [Track]) -> [Track] {
        switch order {
        case .recent: return tracks.sorted { $0.addedAt > $1.addedAt }
        case .title: return tracks.sorted { SortKey.less($0.title, $1.title) }
        case .artist:
            return tracks.sorted {
                $0.artist == $1.artist ? SortKey.less($0.title, $1.title) : SortKey.less($0.artist, $1.artist)
            }
        }
    }

    private func albums(included: Set<String>) -> [Album] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return library.albums.filter { album in
            (text.isEmpty || album.title.localizedCaseInsensitiveContains(text) || album.artist.localizedCaseInsensitiveContains(text))
                && (!hideAdded || album.tracks.contains { !included.contains($0.id) })
        }
    }

    private func artists(included: Set<String>) -> [ArtistEntry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return library.artists.filter { artist in
            (text.isEmpty || artist.name.localizedCaseInsensitiveContains(text))
                && (!hideAdded || artistTracks(artist).contains { !included.contains($0.id) })
        }
    }

    private func artistTracks(_ artist: ArtistEntry) -> [Track] {
        artist.albums.flatMap(\.tracks) + artist.singles
    }
}

/// One album's or artist's songs inside Add Songs, picked one by one.
private struct PickerTrackList: View {
    let title: String
    let tracks: [Track]
    let numbered: Bool
    let included: Set<String>
    @Binding var chosen: [String]
    let hideAdded: Bool

    var body: some View {
        let picked = Set(chosen)
        let available = tracks.filter { !included.contains($0.id) }
        List {
            ForEach(tracks.filter { !hideAdded || !included.contains($0.id) }) { track in
                PickerSongRow(track: track,
                              subtitle: numbered ? track.artist : (track.album ?? ""),
                              number: numbered ? track.trackNumber : nil,
                              isIncluded: included.contains(track.id), isPicked: picked.contains(track.id)) {
                    if let index = chosen.firstIndex(of: track.id) { chosen.remove(at: index) } else { chosen.append(track.id) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let all = !available.isEmpty && available.allSatisfy { picked.contains($0.id) }
                Button(all ? "Deselect All" : "Select All") {
                    if all {
                        let ids = Set(available.map(\.id))
                        chosen.removeAll { ids.contains($0) }
                    } else {
                        for track in available where !picked.contains(track.id) { chosen.append(track.id) }
                    }
                }
                .disabled(available.isEmpty)
            }
        }
    }
}

/// A song in Add Songs: tap to pick it; songs already in the playlist are marked and can't be picked.
private struct PickerSongRow: View {
    let track: Track
    let subtitle: String
    var number: Int?
    let isIncluded: Bool
    let isPicked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isIncluded ? "checkmark.circle" : (isPicked ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                TrackRow(track: track, number: number, showArtwork: number == nil, subtitle: isIncluded ? "In this playlist" : subtitle)
                    .opacity(isIncluded ? 0.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isIncluded)
    }
}

/// Drag the playlists into your own order; the Playlists list (and Add to Playlist) follow it.
struct ReorderPlaylistsSheet: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists.playlists) { playlist in
                    HStack(spacing: 12) {
                        PlaylistArtwork(tracks: playlists.tracks(of: playlist, in: library), playlistID: playlist.id, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name).lineLimit(1)
                            Text("\(playlist.trackIDs.count) song\(playlist.trackIDs.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { playlists.movePlaylists(from: $0, to: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
