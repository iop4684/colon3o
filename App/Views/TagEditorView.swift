import SwiftUI

/// What Edit Info is changing: one song, or every song on an album.
enum TagEditTarget: Identifiable {
    case track(Track)
    case album(Album)

    var id: String {
        switch self {
        case let .track(track): return "t:" + track.id
        case let .album(album): return "a:" + album.id
        }
    }

    var tracks: [Track] {
        switch self {
        case let .track(track): return [track]
        case let .album(album): return album.tracks
        }
    }

    /// A song has every field; an album only the ones its songs share.
    var fields: [TagField] {
        switch self {
        case .track: return [.title, .artist, .albumArtist, .album, .track, .disc, .year]
        case .album: return [.album, .albumArtist, .artist, .year]
        }
    }
}

/// Edit Info: changes a song's (or a whole album's) tags in the files themselves.
struct TagEditorView: View {
    let target: TagEditTarget

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var completeness: AlbumCompletenessStore
    @Environment(\.dismiss) private var dismiss

    @State private var values: [TagField: String] = [:]
    /// What each field holds now; nil when an album's songs disagree ("Mixed").
    @State private var original: [TagField: String?] = [:]
    @State private var saving = false
    @State private var failure: String?

    private var tracks: [Track] {
        target.tracks.map { library.track(id: $0.id) ?? $0 }
    }

    private var editable: [Track] { tracks.filter { TagWriter.canEdit($0.url) } }

    /// The fields that changed. A "Mixed" field only counts once something is typed into it.
    private var changes: TagChanges {
        var changes: TagChanges = [:]
        for field in target.fields {
            let value = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch original[field] {
            case let .some(.some(old)): if value != old { changes[field] = value }
            case .some(.none): if !value.isEmpty { changes[field] = value }
            case .none: break
            }
        }
        return changes
    }

    private var invalidField: TagField? {
        changes.first { field, value in field.isNumber && !value.isEmpty && Int(value) == nil }?.key
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(target.fields, id: \.self) { field in
                        row(field)
                    }
                } footer: {
                    footer
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(saving || editable.isEmpty)
            .navigationTitle(isAlbum ? "Edit Album Info" : "Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(changes.isEmpty || invalidField != nil || editable.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(saving || !changes.isEmpty)
        }
        .onAppear { load() }
    }

    private var isAlbum: Bool {
        if case .album = target { return true }
        return false
    }

    private func row(_ field: TagField) -> some View {
        HStack(spacing: 16) {
            Text(field.label)
            TextField(original[field] == .some(nil) ? "Mixed" : "None", text: binding(field))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .keyboardType(field.isNumber ? .numberPad : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(field.isNumber ? .never : .words)
        }
    }

    private func binding(_ field: TagField) -> Binding<String> {
        Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })
    }

    @ViewBuilder
    private var footer: some View {
        let skipped = tracks.count - editable.count
        if editable.isEmpty {
            Text("\(tracks.first?.fileExtension.uppercased() ?? "These") files can't be edited. Edit Info works with FLAC, MP3 and M4A.")
        } else if isAlbum {
            Text("Saved into all \(editable.count) songs' files. \"Mixed\" fields keep each song's own value."
                 + (skipped > 0 ? " \(skipped) song\(skipped == 1 ? "" : "s") in other formats can't be edited." : ""))
        } else {
            Text("Saved into the file itself, so other apps see the change too. Leave a field empty to remove it.")
        }
    }

    private func load() {
        guard original.isEmpty else { return }
        for field in target.fields {
            let all = Set(tracks.map { field.value(of: $0) })
            let shared = all.count == 1 ? all.first : nil
            original[field] = .some(shared)
            values[field] = shared ?? ""
        }
    }

    private func save() {
        let changes = self.changes
        let files = editable
        saving = true
        failure = nil
        // A new album name or album artist gives the album a new id; carry its tracklist over.
        if changes[.album] != nil || changes[.albumArtist] != nil {
            for album in Set(files.compactMap { library.album(containing: $0) }) {
                completeness.albumWillChange(album, editing: files)
            }
        }
        Task {
            var failed: [(Track, Error)] = []
            for track in files {
                do {
                    try await TagWriter.write(changes, to: track.url)
                } catch {
                    failed.append((track, error))
                    Diagnostics.shared.log("Edit Info failed for \(track.id): \(error.localizedDescription)", category: "library")
                }
            }
            await library.reread(files)
            player.refreshTracks(from: library)
            saving = false
            if failed.isEmpty {
                dismiss()
            } else if failed.count == 1 {
                let (track, error) = failed[0]
                failure = files.count == 1
                    ? error.localizedDescription
                    : "\"\(track.title)\" wasn't changed: \(error.localizedDescription)"
            } else {
                failure = "\(failed.count) of \(files.count) songs weren't changed: \(failed[0].1.localizedDescription)"
            }
            if !failed.isEmpty { load(force: true) }
        }
    }

    /// After a partial failure, the form shows what the files hold now.
    private func load(force: Bool) {
        original = [:]
        load()
    }
}
