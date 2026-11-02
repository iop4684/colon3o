import SwiftUI

/// Square cover art that loads asynchronously. Pass `size` for a fixed square, or leave it nil
/// to fill the available width.
struct ArtworkView: View {
    let source: ArtworkSource?
    var size: CGFloat?
    var cornerRadius: CGFloat = 8

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedKey: String?

    private var taskID: String { "\(source?.key ?? "none")#\(library.artworkRevision)" }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ArtworkPlaceholder()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .task(id: taskID) {
                guard let source else {
                    image = nil
                    return
                }
                if loadedKey != source.key { image = nil }
                let pixels = Int((size ?? 220) * displayScale)
                let loaded = await ArtworkStore.shared.image(for: source, maxPixel: pixels)
                guard !Task.isCancelled else { return }
                if loaded != nil || loadedKey != source.key {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                }
                loadedKey = source.key
            }
    }
}

struct ArtworkPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.35)
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.3)
                .padding(8)
        }
    }
}

/// Contacts-style A–Z scrubber. Drag or tap to jump between sections.
struct SectionIndexBar: View {
    let available: [String]
    let onSelect: (String) -> Void

    @State private var current: String?
    private let rowHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SortKey.alphabet, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(available.contains(letter) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .frame(width: 18, height: rowHeight)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in select(at: value.location.y) }
                .onEnded { _ in current = nil }
        )
        .sensoryFeedback(.selection, trigger: current)
        .accessibilityHidden(true)
    }

    private func select(at y: CGFloat) {
        let letters = SortKey.alphabet
        let index = min(max(Int((y - 6) / rowHeight), 0), letters.count - 1)
        // Jump to the nearest letter that actually has entries.
        let target = letters[index...].first(where: { available.contains($0) })
            ?? letters[..<index].last(where: { available.contains($0) })
        guard let target, target != current else { return }
        current = target
        onSelect(target)
    }
}

/// One song in a list: optional cover, title, subtitle, duration.
struct TrackRow: View {
    let track: Track
    var number: Int?
    var showArtwork = true
    var subtitle: String?
    var isSelected: Bool?

    @EnvironmentObject private var nowPlaying: NowPlayingState
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
            }
            if showArtwork {
                ArtworkView(source: library.artwork(for: track), size: 48, cornerRadius: 6)
            } else if let number {
                Text("\(number)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if nowPlaying.currentID == track.id {
                        Image(systemName: nowPlaying.isPlaying ? "waveform" : "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: nowPlaying.isPlaying)
                    }
                    Text(track.title)
                        .lineLimit(1)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if favorites.isFavorite(track) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if track.isSpatial {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Formatting.duration(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Play next / queue / favourite / delete, shared by every list of songs.
/// The player, for views that only run actions on it (play next, add to queue). Reaching it
/// through here doesn't redraw the view whenever the player changes, which matters for long-press
/// menus: an open menu that redraws flickers (the song's artwork loading mid-song was enough).
final class PlayerActions {
    private(set) weak var player: Player?
    init(_ player: Player?) { self.player = player }
}

private struct PlayerActionsKey: EnvironmentKey {
    static let defaultValue = PlayerActions(nil)
}

extension EnvironmentValues {
    var playerActions: PlayerActions {
        get { self[PlayerActionsKey.self] }
        set { self[PlayerActionsKey.self] = newValue }
    }
}

struct TrackMenuItems: View {
    let tracks: [Track]
    var album: Album?
    let onDelete: ([Track]) -> Void

    @Environment(\.playerActions) private var actions
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button {
            actions.player?.playNext(tracks)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            actions.player?.addToQueue(tracks)
        } label: {
            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button {
            router.addToPlaylist(tracks)
        } label: {
            Label("Add to Playlist…", systemImage: "text.badge.plus")
        }
        if let album {
            ArtworkMenu(target: .album(album))
        } else if tracks.count == 1, let track = tracks.first {
            ArtworkMenu(target: .track(track))
            Button {
                router.importLyrics(for: track)
            } label: {
                Label("Import Lyrics (.lrc)…", systemImage: "quote.bubble")
            }
        }
        if let album {
            Button {
                favorites.toggle(album)
            } label: {
                favorites.isFavorite(album)
                    ? Label("Unfavorite Album", systemImage: "star.slash")
                    : Label("Favorite Album", systemImage: "star")
            }
        } else if tracks.count == 1, let track = tracks.first {
            Button {
                favorites.toggle(track)
            } label: {
                favorites.isFavorite(track)
                    ? Label("Unfavorite", systemImage: "star.slash")
                    : Label("Favorite", systemImage: "star")
            }
        }
        if let album {
            Button {
                router.tagEditing = .album(album)
            } label: {
                Label("Edit Album Info…", systemImage: "pencil")
            }
            Button {
                router.mergeAlbum(album)
            } label: {
                Label("Merge with Album…", systemImage: "arrow.triangle.merge")
            }
            Button {
                router.searchSoulseek(for: album)
            } label: {
                Label("Search on Soulseek", systemImage: "magnifyingglass")
            }
        } else {
            Button {
                router.addToAlbum(tracks)
            } label: {
                Label("Add to Album…", systemImage: "rectangle.stack.badge.plus")
            }
        }
        if tracks.count == 1, let track = tracks.first {
            Button {
                router.songInfo = track
            } label: {
                Label("Song Info", systemImage: "info.circle")
            }
            Button {
                router.tagEditing = .track(track)
            } label: {
                Label("Edit Info…", systemImage: "pencil")
            }
            ShareLink(item: track.url) {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button(role: .destructive) {
            onDelete(tracks)
        } label: {
            Label(tracks.count == 1 ? "Delete from Library" : "Delete \(tracks.count) Songs", systemImage: "trash")
        }
    }
}

/// "Change Artwork" submenu: from Photos, from Files, or back to the original.
struct ArtworkMenu: View {
    let target: ArtworkTarget

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Menu {
            Button {
                router.pickArtworkPhoto(for: target)
            } label: {
                Label("Choose from Photos…", systemImage: "photo.on.rectangle")
            }
            Button {
                router.importArtworkFile(for: target)
            } label: {
                Label("Choose from Files…", systemImage: "folder")
            }
            if library.hasCustomArtwork(target) {
                Button(role: .destructive) {
                    Task { await library.removeCustomArtwork(for: target) }
                } label: {
                    Label("Use Original Artwork", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label("Change Artwork", systemImage: "photo")
        }
    }
}

/// Asks before deleting files from the phone, then cleans up the queue and favourites.
struct DeleteConfirmation: ViewModifier {
    @Binding var pending: [Track]?
    var onDeleted: (([Track]) -> Void)?

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var playlists: PlaylistStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let tracks = pending else { return }
                player.remove(tracks)
                favorites.forget(tracks)
                playlists.forget(tracks)
                library.delete(tracks)
                pending = nil
                onDeleted?(tracks)
            }
        } message: {
            Text("The files are removed from this iPhone.")
        }
    }

    private var title: String {
        let count = pending?.count ?? 0
        return count == 1 ? "Delete this song?" : "Delete \(count) songs?"
    }
}

extension View {
    func confirmDelete(_ pending: Binding<[Track]?>, onDeleted: (([Track]) -> Void)? = nil) -> some View {
        modifier(DeleteConfirmation(pending: pending, onDeleted: onDeleted))
    }
}

/// Small rounded label used for "Lossless", "Spatial" and similar.
struct BadgeLabel: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
        .foregroundStyle(.secondary)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

/// One choice in an ActionPopover.
struct PopoverAction: Identifiable {
    let title: String
    let systemImage: String
    let action: () -> Void
    var id: String { title }
}

/// Tapping the label opens a small list of choices in a bubble just below it (or above, when
/// there's no room), leaving the label itself in view, unlike a menu, which opens over it.
struct ActionPopover<Label: View>: View {
    let actions: [PopoverAction]
    @ViewBuilder let label: () -> Label
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: { label() }
            .buttonStyle(.plain)
            .disabled(actions.isEmpty)
            .popover(isPresented: $shown, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        Button {
                            shown = false
                            // Let the bubble close first; the choice may close the player or switch tabs.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { item.action() }
                        } label: {
                            SwiftUI.Label(item.title, systemImage: item.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 230)
                .fixedSize()
                .presentationCompactAdaptation(.popover)
            }
    }
}
