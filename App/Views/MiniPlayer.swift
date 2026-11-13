import SwiftUI

/// Compact now-playing controls. On iOS 26+ this sits in the tab bar's bottom accessory (the
/// Liquid Glass pill Apple Music uses); earlier systems get a floating capsule instead.
struct MiniPlayerContent: View {
    let compact: Bool
    let open: () -> Void

    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let image = player.artwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ArtworkPlaceholder()
                }
            }
            .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !compact, let artist = player.current?.artist, !artist.isEmpty {
                    // An explicit dimmed primary: .secondary vanished in the glass pill, leaving an
                    // empty line that pushed the title above centre.
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)  // Title (and artist) centred in the pill's height.
            Spacer(minLength: 4)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(player.current == nil)

            if !compact {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .disabled(player.current == nil)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, compact ? 8 : 10)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

/// The pill is the source of the full player's zoom transition: the player grows out of it and,
/// pulled down, shrinks back into it.
enum MiniPlayerZoom {
    static let id = "miniPlayer"
}

extension View {
    func miniPlayerZoomSource(_ zoom: Namespace.ID) -> some View {
        matchedTransitionSource(id: MiniPlayerZoom.id, in: zoom) { $0.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)) }  // The pill's round ends; Capsule isn't accepted here.
    }
}

#if compiler(>=6.2)
@available(iOS 26, *)
struct AccessoryMiniPlayer: View {
    let open: () -> Void
    let zoom: Namespace.ID
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayerContent(compact: placement == .inline, open: open)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .miniPlayerZoomSource(zoom)
    }
}
#endif

/// Pre-iOS 26 stand-in: a floating material capsule above the tab bar.
struct FloatingMiniPlayer: View {
    let open: () -> Void
    let zoom: Namespace.ID

    var body: some View {
        MiniPlayerContent(compact: false, open: open)
            .frame(height: 56)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .miniPlayerZoomSource(zoom)
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }
}

enum MiniPlayerStyle {
    static var usesTabAccessory: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }
}

/// Adds the floating pill to a tab's content when the native accessory isn't available.
struct FallbackMiniPlayer: ViewModifier {
    let open: () -> Void
    let zoom: Namespace.ID
    @EnvironmentObject private var player: Player

    @ViewBuilder
    func body(content: Content) -> some View {
        if MiniPlayerStyle.usesTabAccessory {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil { FloatingMiniPlayer(open: open, zoom: zoom) }
            }
        }
    }
}

/// Native bottom accessory on iOS 26+.
struct TabAccessoryMiniPlayer: ViewModifier {
    /// Show the pill only while a track is loaded (playing or paused).
    let isVisible: Bool
    let open: () -> Void
    let zoom: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.1, *) {
            // isEnabled hides the accessory cleanly; toggling the modifier itself rebuilds the TabView.
            content
                .tabViewBottomAccessory(isEnabled: isVisible) { AccessoryMiniPlayer(open: open, zoom: zoom) }
                .tabBarMinimizeBehavior(.never)  // This fork keeps the tab bar full size.
        } else if #available(iOS 26, *) {
            content
                .tabViewBottomAccessory { AccessoryMiniPlayer(open: open, zoom: zoom) }
                .tabBarMinimizeBehavior(.never)  // This fork keeps the tab bar full size.
        } else {
            content
        }
        #else
        content
        #endif
    }
}
