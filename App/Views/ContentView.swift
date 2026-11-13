import SwiftUI

/// The tabs. Watches only small, rarely changing state (the download count, whether something is
/// playing): redrawing this view re-evaluates the whole app.
struct ContentView: View {
    @EnvironmentObject private var downloadBadge: DownloadBadge
    @EnvironmentObject private var nowPlaying: NowPlayingState
    @Environment(\.playerActions) private var playerActions
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var updates: UpdateChecker
    @AppStorage(AccentPalette.storageKey) private var accentHex = AccentPalette.defaultHex
    /// Links the mini player pill and the full player, so the player zooms out of the pill and
    /// shrinks back into it when pulled down (Apple Music's transition).
    @Namespace private var playerZoom

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsView().modifier(FallbackMiniPlayer(open: openPlayer, zoom: playerZoom))
            }
            .badge(downloadBadge.count)
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView().modifier(FallbackMiniPlayer(open: openPlayer, zoom: playerZoom))
            }
            Tab("Library", systemImage: "music.note.house", value: AppTab.library) {
                LibraryView().modifier(FallbackMiniPlayer(open: openPlayer, zoom: playerZoom))
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
            .badge(updates.isUpdateAvailable ? 1 : 0)
        }
        .modifier(TabAccessoryMiniPlayer(isVisible: nowPlaying.currentID != nil, open: openPlayer, zoom: playerZoom))
        .modifier(RouterPresenters(active: !router.showPlayer))
        .fullScreenCover(isPresented: $router.showPlayer) {
            NowPlayingView()
                .modifier(RouterPresenters(active: true))
                .navigationTransition(.zoom(sourceID: MiniPlayerZoom.id, in: playerZoom))
                .tint(Color(hex: accentHex))
        }
        .onChange(of: library.artworkRevision) { _, _ in playerActions.player?.reloadArtwork() }
        .tint(Color(hex: accentHex))
    }

    private func openPlayer() {
        router.showPlayer = true
    }
}

/// Banner shown on screens that need the Soulseek connection.
struct ConnectionBanner: View {
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        switch soulseek.connection {
        case .loggedIn:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .disconnected:
            Label(soulseek.hasCredentials ? "Disconnected" : "Log in under Settings to search Soulseek",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}
