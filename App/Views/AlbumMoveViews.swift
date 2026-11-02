import SwiftUI

/// Merge with Album / Add to Album: songs join an album by taking on its album, album artist and
/// year tags, written into the files like Edit Info does.
enum AlbumMove {
    /// The album as the library shows it. The album artist is written even when the album's songs
    /// have none: without one, songs group by folder, and songs from other folders wouldn't join.
    static func tags(for album: Album) -> TagChanges {
        var tags: TagChanges = [.album: album.title, .albumArtist: album.artist]
        let years = Set(album.tracks.compactMap(\.year))
        if years.count == 1, let year = years.first { tags[.year] = String(year) }
        return tags
    }
}

/// The sheet for an AlbumRequest: pick the album, then the files are retagged.
struct AlbumRequestSheet: View {
    let request: AlbumRequest

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var completeness: AlbumCompletenessStore
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        switch request.action {
        case let .merge(album):
            AlbumPickerSheet(
                title: "Merge Into “\(album.title)”",
                note: "The album you pick joins this one, which keeps its name.",
                albums: library.albums.filter { $0.id != album.id },
                mergeQuestion: { "Merge “\($0.title)” into “\(album.title)”?" }
            ) { picked in
                await move(picked.tracks, into: album, merging: [picked])
            }

        case let .mergeSelected(albums, songs):
            AlbumPickerSheet(
                title: "Keep Which Album?",
                note: "Everything else selected joins the album you pick, which keeps its name.",
                albums: albums,
                mergeQuestion: { picked in
                    let count = albums.count + songs.count - 1
                    return "Merge \(count) other item\(count == 1 ? "" : "s") into “\(picked.title)”?"
                }
            ) { picked in
                let others = albums.filter { $0.id != picked.id }
                return await move(others.flatMap(\.tracks) + songs, into: picked, merging: others)
            }

        case let .addSongs(tracks):
            AlbumPickerSheet(
                title: tracks.count == 1 ? "Add to Album" : "Add \(tracks.count) Songs to Album",
                albums: library.albums
            ) { picked in
                await move(tracks, into: picked, merging: [])
            }
        }
    }

    /// Writes the target's album tags into the songs, and into the target's own songs that lack
    /// them (so it stays one album), then waits for the library to regroup. Returns what went
    /// wrong, if anything.
    private func move(_ songs: [Track], into target: Album, merging others: [Album]) async -> String? {
        let target = library.album(id: target.id) ?? target
        let songs = songs.map { library.track(id: $0.id) ?? $0 }
        // If some of the album's own songs can't be retagged, leave them all as they are and
        // match the movers to the tags they already share instead.
        let targetEditable = target.tracks.allSatisfy { TagWriter.canEdit($0.url) }
        let tags = targetEditable ? AlbumMove.tags(for: target) : SoulseekModel.albumTags(of: target)
        var seen = Set<String>()
        let candidates = ((targetEditable ? target.tracks : []) + songs).filter { seen.insert($0.id).inserted }
        let writes = candidates.filter { TagWriter.canEdit($0.url) }.compactMap { track -> (Track, TagChanges)? in
            let changes = tags.filter { field, value in field.value(of: track) != value }
            return changes.isEmpty ? nil : (track, changes)
        }

        let wasFavorite = favorites.isFavorite(target) || others.contains { favorites.isFavorite($0) }
        // Writing an album artist into the album's own songs gives it a new id; keep its tracklist.
        completeness.albumWillChange(target, editing: writes.map(\.0))

        var failed: [(Track, Error)] = []
        for (track, changes) in writes {
            do {
                try await TagWriter.write(changes, to: track.url)
            } catch {
                failed.append((track, error))
                Diagnostics.shared.log("Album move failed for \(track.id): \(error.localizedDescription)", category: "library")
            }
        }
        if !writes.isEmpty {
            await library.reread(writes.map(\.0))
            player.refreshTracks(from: library)
        }

        guard let anchor = target.tracks.first, let merged = library.album(containing: anchor) else { return nil }
        if wasFavorite { favorites.set(merged, favorite: true) }
        let joined = Set(merged.tracks.map(\.id))
        let leftOut = songs.filter { !joined.contains($0.id) }
        if leftOut.isEmpty { return nil }
        if let first = failed.first {
            return "\(leftOut.count) song\(leftOut.count == 1 ? "" : "s") didn't move. “\(first.0.title)”: \(first.1.localizedDescription)"
        }
        return "\(leftOut.count) song\(leftOut.count == 1 ? "" : "s") didn't move. Only FLAC, MP3 and M4A files can be retagged."
    }
}

/// Searchable list of albums; tapping one picks it (after a confirmation when merging) and the
/// sheet stays up until the files are written.
struct AlbumPickerSheet: View {
    let title: String
    var note: String?
    let albums: [Album]
    var mergeQuestion: ((Album) -> String)?
    let onPick: (Album) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pendingMerge: Album?
    @State private var working = false
    @State private var failure: String?

    private var filtered: [Album] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return albums }
        return albums.filter { $0.title.localizedCaseInsensitiveContains(trimmed) || $0.artist.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach(filtered) { album in
                        Button {
                            if mergeQuestion == nil { pick(album) } else { pendingMerge = album }
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(source: .album(album), size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).foregroundStyle(.primary).lineLimit(1)
                                    Text("\(album.artist) · \(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    if let note { Text(note).textCase(nil) }
                } footer: {
                    Text("Album, album artist and year are written into the songs' files, like Edit Info.")
                }
            }
            .disabled(working)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                if working {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .interactiveDismissDisabled(working)
            .confirmationDialog(pendingMerge.flatMap { mergeQuestion?($0) } ?? "",
                                isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingMerge) { album in
                Button("Merge") { pick(album) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ album: Album) {
        working = true
        failure = nil
        Task {
            let problem = await onPick(album)
            working = false
            if let problem { failure = problem } else { dismiss() }
        }
    }
}
