import SwiftUI

/// Apple Music-style lyrics: the current line bright, the rest dimmed and softly blurred,
/// auto-scrolling with playback. Tap a line to jump there.
struct LyricsView: View {
    let track: Track
    let albumTitle: String?
    let position: Double
    let onSeek: (Double) -> Void

    @EnvironmentObject private var router: AppRouter
    @State private var lyrics: Lyrics?
    @State private var isLoading = true
    /// The online sources still being asked, for the loading status.
    @State private var checking: [LyricsSource] = []
    /// Where the lyrics on screen were fetched from (nil for files you added).
    @State private var fetchedFrom: String?
    @State private var userScrolledAt: Date?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    if !checking.isEmpty {
                        Text("Checking " + checking.map(\.rawValue).joined(separator: " and ") + "\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch lyrics {
                case let .synced(lines):
                    synced(lines)
                case let .plain(lines):
                    plain(lines)
                case .instrumental:
                    message("Instrumental", systemImage: "music.note")
                case .notFound:
                    VStack(spacing: 12) {
                        message("No lyrics found", systemImage: "quote.bubble")
                            .overlay(alignment: .bottom) {
                                Text("Checked " + LyricsSource.allCases.map(\.rawValue).joined(separator: " and "))
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.45))
                                    .offset(y: 24)
                            }
                            .frame(maxHeight: 120)
                        Button("Import .lrc File…") { router.importLyrics(for: track) }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case nil:
                    VStack(spacing: 12) {
                        message("Couldn't load lyrics", systemImage: "wifi.exclamationmark")
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !isLoading, let fetchedFrom {
                Text("Lyrics from \(fetchedFrom)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 6)
            }
        }
        .task(id: "\(track.id)#\(router.lyricsRevision)") { await load() }
    }

    private func load() async {
        isLoading = true
        checking = []
        let file = LibraryStore.lyricsURL(for: track)
        if let local = await Task.detached(priority: .userInitiated, operation: { LyricsService.localLyrics(at: file) }).value {
            lyrics = local
        } else {
            lyrics = await LyricsService.shared.lyrics(title: track.title, artist: track.artist, album: albumTitle,
                                                       duration: track.duration, cacheKey: track.id, saveTo: file,
                                                       onPending: { checking = $0 })
        }
        fetchedFrom = await Task.detached { LyricsService.fetchedSource(of: file) }.value
        checking = []
        isLoading = false
    }

    private func activeLine(in lines: [LyricLine]) -> Int {
        // Lead slightly so the highlight lands as the line starts.
        let now = position + 0.25
        var active = -1
        for line in lines {
            if line.time <= now { active = line.id } else { break }
        }
        return active
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        let active = activeLine(in: lines)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(lines) { line in
                        let distance = active < 0 ? 1 : abs(line.id - active)
                        lineText(line, isActive: line.id == active)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white.opacity(line.id == active ? 1 : 0.32))
                            .blur(radius: line.id == active ? 0 : min(Double(distance) * 0.6, 2.4))
                            .scaleEffect(line.id == active ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .id(line.id)
                            .onTapGesture { onSeek(line.time) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 140)
                .animation(.easeOut(duration: 0.35), value: active)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
            .onChange(of: active) { _, newValue in
                // Don't yank the view while the user is reading ahead.
                if let userScrolledAt, Date().timeIntervalSince(userScrolledAt) < 4 { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo(max(newValue, 0), anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
            .onAppear { proxy.scrollTo(max(active, 0), anchor: UnitPoint(x: 0, y: 0.3)) }
        }
        .mask(fade)
    }

    /// The current line fills word by word when the lyrics have word timings; every other line
    /// (and lyrics without them) is plain text, styled as before.
    @ViewBuilder
    private func lineText(_ line: LyricLine, isActive: Bool) -> some View {
        if isActive, !line.words.isEmpty {
            WordByWordLine(line: line, position: position)
        } else {
            Text(line.text)
        }
    }

    private func plain(_ lines: [String]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
        }
        .mask(fade)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text).font(.headline)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.1),
            .init(color: .black, location: 0.85),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// One line lighting up word by word, the way Apple Music does: a soft-edged sweep runs left to
/// right through each word from when it starts to when it ends, the sung part floats up a
/// little, and notes held a second or more glow and swell. The playback position arrives about
/// five times a second, so between updates it's carried forward on the clock (at most a quarter
/// second, so a pause doesn't run ahead) to keep the sweep smooth.
private struct WordByWordLine: View {
    let line: LyricLine
    let position: Double

    private struct Anchor {
        var position: Double
        var at: Date
    }

    @State private var anchor = Anchor(position: 0, at: .distantPast)

    /// The sweep runs ahead of the singing: it starts this much early…
    static let lead = 0.12
    /// …and takes this share of the word's length, so it never feels behind.
    static let pace = 0.65

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let elapsed = min(max(context.date.timeIntervalSince(anchor.at), 0), 0.25)
            text(at: anchor.position + elapsed)
                .textRenderer(WordSweepRenderer())
        }
        .onAppear { anchor = Anchor(position: position, at: Date()) }
        .onChange(of: position) { _, newValue in anchor = Anchor(position: newValue, at: Date()) }
    }

    private func text(at now: Double) -> Text {
        let words = line.words
        var result = Text("")
        for index in words.indices {
            let word = words[index]
            // A known end (from the lyrics) is used as is. Otherwise the word runs until the next
            // one starts, but no longer than a second, so a pause after it doesn't stretch it.
            let knownEnd = word.end ?? (index == words.count - 1 ? line.wordsEnd : nil)
            let next = index + 1 < words.count ? words[index + 1].time : word.time + 1
            let end = knownEnd ?? min(next, word.time + 1)
            let span = max(end - word.time, 0.05)
            let progress = min(max((now + Self.lead - word.time) / (span * Self.pace), 0), 1)
            let held = knownEnd != nil && span >= 1 && Self.canEmphasize(word.text)
            let emphasis = held ? sin(.pi * progress) : 0
            result = result + Text(word.text).customAttribute(WordSweep(index: index, progress: progress, emphasis: emphasis))
        }
        return result
    }

    /// Like Apple Music: CJK words of any length, other words of 2 to 7 letters.
    private static func canEmphasize(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isCJK = trimmed.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
        return isCJK ? !trimmed.isEmpty : (2...7).contains(trimmed.count)
    }
}

/// Per-word state for the renderer. `index` keeps neighbouring words from merging into one run.
private struct WordSweep: TextAttribute {
    var index: Int
    /// 0 not sung yet … 1 sung.
    var progress: Double
    /// 0 … 1, how much a held note glows and swells right now.
    var emphasis: Double
}

/// Draws each word dimmed, then the sung part over it at full brightness through a mask whose
/// soft edge moves left to right.
private struct WordSweepRenderer: TextRenderer {
    /// Same as the other lines' dimming.
    static let dimmed = 0.32
    /// How far a fully sung word has floated up, in points.
    static let lift: CGFloat = 1.5

    /// Room for the glow and swell to draw past the text's edges.
    var displayPadding: EdgeInsets { EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let sweep = run[WordSweep.self] else {
                    context.draw(run)
                    continue
                }
                let bounds = run.typographicBounds.rect
                var word = context
                if sweep.emphasis > 0 {
                    let scale = 1 + 0.06 * sweep.emphasis
                    word.translateBy(x: bounds.midX, y: bounds.midY)
                    word.scaleBy(x: scale, y: scale)
                    word.translateBy(x: -bounds.midX, y: -bounds.midY)
                }
                let eased = sweep.progress * sweep.progress * (3 - 2 * sweep.progress)
                word.translateBy(x: 0, y: -Self.lift * eased)

                if sweep.progress < 1 {
                    var dim = word
                    dim.opacity = Self.dimmed
                    dim.draw(run)
                }
                guard sweep.progress > 0 else { continue }

                var lit = word
                if sweep.progress < 1 {
                    let edge = max(bounds.height * 0.45, 6)
                    let front = bounds.minX + (bounds.width + edge) * sweep.progress
                    let left = bounds.minX - edge
                    lit.clipToLayer { mask in
                        let area = CGRect(x: left, y: bounds.minY - bounds.height, width: max(front - left, 0), height: bounds.height * 3)
                        mask.fill(Path(area), with: .linearGradient(Gradient(colors: [.white, .white.opacity(0)]),
                                                                    startPoint: CGPoint(x: max(front - edge, left), y: 0),
                                                                    endPoint: CGPoint(x: front, y: 0)))
                    }
                }
                if sweep.emphasis > 0 {
                    lit.addFilter(.shadow(color: .white.opacity(0.6 * sweep.emphasis), radius: 12 * sweep.emphasis))
                }
                lit.draw(run)
            }
        }
    }
}
