import SwiftUI

/// Apple Music-style lyrics: the current line bright, the rest dimmed and softly blurred,
/// auto-scrolling with playback. Tap a line to jump there.
struct LyricsView: View {
    let track: Track
    let albumTitle: String?
    let position: Double
    let onSeek: (Double) -> Void

    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var preferences = LyricsPreferences.shared
    @State private var lyrics: Lyrics?
    @State private var isLoading = true
    /// The online sources still being asked, for the loading status.
    @State private var checking: [LyricsSource] = []
    /// Where the lyrics on screen were fetched from (nil for files you added).
    @State private var fetchedFrom: String?
    /// Where each line sits in the lyrics column (before scrolling), to bring the current one into place.
    /// The lyrics' scroll position, moved to the current line and by your finger.
    @State private var scroll = ScrollPosition(idType: Int.self)
    /// Set while you're scrolling the lyrics yourself (until they return to the current line).
    @State private var userScrolling = false
    /// Where a hand scroll started, to tell a real scroll from a light touch.
    @State private var scrollStart: CGFloat = 0
    /// The current line, kept for the return to it after you've scrolled away.
    @State private var currentLine = -1
    @State private var browsing = false
    @State private var browseEnd: Task<Void, Never>?
    /// Romaji for Japanese lines, by line id (synced) or line number (plain).
    @State private var romaji: [Int: [Romaji.Piece]] = [:]
    /// Bumped when the romaji changes, so the column can compare one number instead of all of it.
    @State private var romajiVersion = 0
    @AppStorage(LyricsView.romajiKey) private var showRomaji = true
    @AppStorage(PerformanceTest.noFadeKey) private var noFade = false
    @AppStorage(PerformanceTest.noSweepKey) private var noSweep = false

    static let romajiKey = "lyrics.showRomaji"

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    if !checking.isEmpty {
                        Text("Checking " + checking.spoken + "\u{2026}")
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
                                Text("Checked " + (preferences.source(for: track.id).map { [$0] } ?? LyricsSource.allCases).spoken)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.45))
                                    .offset(y: 24)
                            }
                            .frame(maxHeight: 120)
                        Button("Find Lyrics\u{2026}") { router.findLyrics(for: track) }
                            .buttonStyle(.borderedProminent)
                        Button("Import .lrc File\u{2026}") { router.importLyrics(for: track) }
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
                let shift = preferences.offset(for: track.id)
                Text("Lyrics from \(fetchedFrom)" + (shift == 0 ? "" : String(format: " · %+.1f s", shift)))
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
                                                       only: preferences.source(for: track.id),
                                                       onPending: { checking = $0 })
        }
        fetchedFrom = await Task.detached { LyricsService.fetchedSource(of: file) }.value
        let loaded = lyrics
        romaji = await Task.detached(priority: .userInitiated) { Self.romanize(loaded, human: [:]) }.value
        romajiVersion += 1
        // Romaji written by people (Musixmatch's), when the song has it, replaces the automatic
        // romaji line by line; it's fetched after the lyrics are on screen.
        if Self.isJapanese(loaded) {
            let human = await LyricsService.shared.romanized(cacheKey: track.id, title: track.title, artist: track.artist,
                                                             album: albumTitle, duration: track.duration)
            if !human.isEmpty {
                romaji = await Task.detached(priority: .userInitiated) { Self.romanize(loaded, human: human) }.value
                romajiVersion += 1
            }
        }
        checking = []
        isLoading = false
        router.lyricsLoaded()
    }

    nonisolated private static func isJapanese(_ lyrics: Lyrics?) -> Bool {
        switch lyrics {
        case let .synced(lines): return lines.contains { Romaji.containsJapanese($0.text) }
        case let .plain(lines): return lines.contains { Romaji.containsJapanese($0) }
        default: return false
        }
    }

    /// Each line's romaji: Musixmatch's (written by people) when it has that line, otherwise made here.
    nonisolated private static func romanize(_ lyrics: Lyrics?, human: [String: String]) -> [Int: [Romaji.Piece]] {
        var result: [Int: [Romaji.Piece]] = [:]
        func pieces(_ text: String) -> [Romaji.Piece]? {
            guard Romaji.containsJapanese(text) else { return nil }
            if let written = human[Musixmatch.key(text)], let aligned = Romaji.pieces(written: written, for: text) { return aligned }
            return Romaji.pieces(text)
        }
        switch lyrics {
        case let .synced(lines):
            for line in lines { result[line.id] = pieces(line.text) }
        case let .plain(lines):
            for (index, line) in lines.enumerated() { result[index] = pieces(line) }
        default:
            break
        }
        return result
    }

    /// PetitLyrics' timings run late: measured against Apple Music on the same song, its words
    /// land about three quarters of a second after the singing. Other sources are used as they are.
    /// Plus the song's own shift from Adjust Timing.
    private var timingLead: Double {
        (fetchedFrom == LyricsSource.petit.rawValue ? 0.75 : 0) + preferences.offset(for: track.id)
    }

    private func activeLine(in lines: [LyricLine]) -> Int {
        // Lead slightly so the highlight lands as the line starts.
        let now = position + 0.25 + timingLead
        var active = -1
        for line in lines {
            if line.time <= now { active = line.id } else { break }
        }
        return active
    }

    /// The lyrics column moves to keep the current line about a third of the way down. Like Apple
    /// Music, each line glides there on its own soft spring, the ones further down setting off a
    /// little later, so the column flows rather than jumping as one block.
    /// The lyrics scroll in an ordinary iOS scroll view: your finger, momentum and the scroll
    /// indicator are handled by iOS itself (as in Apple Music), and moving to the current line is
    /// a smooth glide of that same scroll view. The current line sits a third of the way down;
    /// the margins let the first and last lines get there too, and scrolling stops at them.
    private func synced(_ lines: [LyricLine]) -> some View {
        let active = activeLine(in: lines)
        return GeometryReader { geometry in
            ScrollView(.vertical) {
                LyricColumn(lines: lines,
                            romaji: showRomaji ? romaji : [:],
                            romajiVersion: showRomaji ? romajiVersion : -1,
                            active: active,
                            browsing: browsing,
                            position: noSweep ? 0 : position + timingLead,
                            sweeps: !noSweep,
                            onSeek: { [id = track.id] time in
                                // A tapped line plays from where it's shown, timing shift included.
                                onSeek(max(time - LyricsPreferences.shared.offset(for: id), 0))
                            })
                    .equatable()
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scroll)
            .contentMargins(.top, geometry.size.height * Self.anchor, for: .scrollContent)
            .contentMargins(.bottom, geometry.size.height * (1 - Self.anchor), for: .scrollContent)
            .background(ScrollBounceDisabler())
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting:
                    if !userScrolling {
                        userScrolling = true
                        scrollStart = context.geometry.contentOffset.y
                    }
                    browseEnd?.cancel()
                case .idle:
                    guard userScrolling else { return }
                    browseEnd?.cancel()
                    browseEnd = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        userScrolling = false
                        withAnimation(.easeInOut(duration: 0.4)) { browsing = false }
                        withAnimation(Self.glide) { scroll.scrollTo(id: currentLine, anchor: Self.anchorPoint) }
                    }
                default:
                    break
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                // Lines only brighten for reading once you've really scrolled, so a light touch
                // never makes every line redraw.
                if userScrolling, !browsing, abs(offset - scrollStart) > Self.browseDistance {
                    withAnimation(.easeOut(duration: 0.25)) { browsing = true }
                }
            }
            .onChange(of: active, initial: true) { oldValue, newValue in
                currentLine = newValue
                // While you're reading elsewhere, stay where you are.
                guard !userScrolling, newValue >= 0 else { return }
                if oldValue == newValue {
                    scroll.scrollTo(id: newValue, anchor: Self.anchorPoint)
                } else {
                    withAnimation(Self.glide) { scroll.scrollTo(id: newValue, anchor: Self.anchorPoint) }
                }
            }
        }
        .mask(noFade ? AnyView(Color.black) : AnyView(fade))
    }

    /// The current line's place: a third of the way down.
    static let anchor: CGFloat = 0.3
    static let anchorPoint = UnitPoint(x: 0, y: anchor)
    /// How the lyrics move to a line: an even ease, no bounce.
    static let glide = Animation.smooth(duration: 0.6)
    /// How far you scroll before the lines brighten for reading.
    static let browseDistance: CGFloat = 40

    private func plain(_ lines: [String]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 26, weight: .bold))
                        if showRomaji, let pieces = romaji[index] {
                            Text(pieces.map(\.text).joined(separator: " ")).font(.system(size: 15, weight: .semibold)).opacity(0.75)
                        }
                    }
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

/// The synced lyrics column. Equatable on what it shows (not the callbacks), so scrolling by hand
/// or a position tick that doesn't change the current line skips it entirely.
private struct LyricColumn: View, Equatable {
    let lines: [LyricLine]
    let romaji: [Int: [Romaji.Piece]]
    let romajiVersion: Int
    let active: Int
    let browsing: Bool
    /// Playback position (with any timing lead), used by the current line and interludes only.
    let position: Double
    /// Performance test: off draws the current line plainly, without the word sweep.
    var sweeps = true
    let onSeek: (Double) -> Void

    static let spacing: CGFloat = 26

    static func == (a: LyricColumn, b: LyricColumn) -> Bool {
        a.active == b.active && a.browsing == b.browsing && a.position == b.position && a.romajiVersion == b.romajiVersion
            && a.sweeps == b.sweeps
            && a.lines.count == b.lines.count && a.lines.first?.time == b.lines.first?.time
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(lines) { line in
                let isActive = line.id == active
                let usesClock = isActive || line.text == "♪"
                LyricRow(line: line,
                         romaji: romaji[line.id],
                         isActive: isActive,
                         sweeps: sweeps,
                         distance: active < 0 ? 1 : abs(line.id - active),
                         browsing: browsing,
                         position: usesClock ? position : 0,
                         next: line.id + 1 < lines.count ? lines[line.id + 1].time : nil,
                         onTap: { onSeek(line.time) })
                    .equatable()
                    .id(line.id)
            }
        }
        .scrollTargetLayout()
    }
}

/// One line of synced lyrics in the column. Equatable on what it shows, so SwiftUI skips it when
/// nothing about it changed (the callbacks don't count).
private struct LyricRow: View, Equatable {
    let line: LyricLine
    let romaji: [Romaji.Piece]?
    let isActive: Bool
    var sweeps = true
    let distance: Int
    let browsing: Bool
    let position: Double
    let next: Double?
    let onTap: () -> Void

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.line.id == b.line.id && a.isActive == b.isActive && a.sweeps == b.sweeps && a.distance == b.distance && a.browsing == b.browsing
            && a.position == b.position && a.romaji == b.romaji
            && a.next == b.next && a.line == b.line
    }

    var body: some View {
        content
            // Full height whatever the column's size, so long lines wrap instead of being cut off.
            .fixedSize(horizontal: false, vertical: true)
            // No per-line blur: each one is an extra offscreen render, redone on every frame the
            // lines move. Lines further from the current one just fade a little more.
            .foregroundStyle(.white.opacity(isActive ? 1 : (browsing ? 0.45 : max(0.32 - Double(max(distance - 2, 0)) * 0.03, 0.2))))
            .scaleEffect(isActive ? 1 : 0.97, anchor: .leading)
            .animation(.easeInOut(duration: 0.6), value: isActive)
            .animation(.easeOut(duration: 0.3), value: browsing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var content: some View {
        if line.text == "♪", line.words.isEmpty {
            InterludeDots(start: line.time, end: next ?? line.time + 8, position: position, isActive: isActive)
        } else if !line.words.isEmpty {
            // The same view whether current or not, so a line that stops being current just dims
            // where it is, instead of a copy fading out behind the scrolling lines.
            WordByWordLine(line: line, romaji: romaji, position: position, isActive: isActive && sweeps)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text).font(LyricsFont.line)
                if let romaji { Text(romaji.map(\.text).joined(separator: " ")).font(LyricsFont.romaji) }
            }
        }
    }
}

/// An instrumental break, shown as three dots like Apple Music: still, and on the current line
/// they light up one after another across the break, fading in like sung words.
private struct InterludeDots: View {
    let start: Double
    let end: Double
    let position: Double
    let isActive: Bool

    var body: some View {
        let progress = min(max((position - start) / max(end - start, 0.1), 0), 1)
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                let fill = isActive ? min(max(progress * 3 - Double(index), 0), 1) : 0
                Circle()
                    .opacity(isActive ? 0.65 + 0.35 * fill : 1)
                    .frame(width: 12, height: 12)
            }
        }
        .animation(.linear(duration: 0.25), value: progress)
        .frame(height: 38, alignment: .leading)
    }
}

enum LyricsFont {
    static let line = Font.system(size: 32, weight: .bold)
    static let romaji = Font.system(size: 17, weight: .semibold)
}

/// One line lighting up word by word, the way Apple Music does: a soft-edged sweep runs left to
/// right through each word from when it starts to when it ends, at constant speed. As the sweep
/// passes, each character eases up a little, so the line rises in one smooth wave rather than
/// word by word. Notes held a second or more glow and swell. Romaji under the line sweeps across
/// the whole line's time.
///
/// The playback position arrives about five times a second. Between updates the time is carried
/// forward on the clock, and each update is blended in rather than jumped to, so the sweep never
/// stutters backwards; a pause stops it within a fraction of a second.
private struct WordByWordLine: View {
    let line: LyricLine
    let romaji: [Romaji.Piece]?
    let position: Double
    /// Only the current line sweeps; others draw plainly (and don't redraw every frame).
    let isActive: Bool

    private struct Anchor {
        var position: Double
        var at: Date
    }

    @State private var anchor = Anchor(position: 0, at: .distantPast)

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let now = estimate(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                // Lines that aren't current are plain text: no per-word pieces to build when they redraw.
                (isActive ? words : Text(line.text)).font(LyricsFont.line)
                    .textRenderer(WordSweepRenderer(now: now, isActive: isActive))
                if let romaji {
                    (isActive ? romajiText(romaji) : Text(romaji.map(\.text).joined(separator: " ")))
                        .font(LyricsFont.romaji)
                        .textRenderer(WordSweepRenderer(now: now, isActive: isActive))
                }
            }
        }
        .onAppear { anchor = Anchor(position: position, at: Date()) }
        .onChange(of: isActive) { _, active in
            if active { anchor = Anchor(position: position, at: Date()) }
        }
        .onChange(of: position) { _, newValue in
            let date = Date()
            let predicted = estimate(at: date)
            // Small differences are eased in; a seek or a stall jumps straight there.
            let blended = abs(newValue - predicted) < 0.3 ? predicted + (newValue - predicted) * 0.3 : newValue
            anchor = Anchor(position: blended, at: date)
        }
    }

    private func estimate(at date: Date) -> Double {
        anchor.position + min(max(date.timeIntervalSince(anchor.at), 0), 0.4)
    }

    /// When each word is sung. A known end (from the lyrics) is used as is; otherwise a word runs
    /// until the next one starts, but no longer than a second, so a pause after it doesn't stretch it.
    private func timing(_ index: Int) -> (start: Double, end: Double, known: Bool) {
        let words = line.words
        let word = words[index]
        let knownEnd = word.end ?? (index == words.count - 1 ? line.wordsEnd : nil)
        let next = index + 1 < words.count ? words[index + 1].time : word.time + 1
        let end = knownEnd ?? min(next, word.time + 1)
        return (word.time, max(end, word.time + 0.05), knownEnd != nil)
    }

    /// When the character at this point of the line (UTF-16 offset) is sung: its word's time,
    /// shared out evenly across the word's characters.
    private func time(at offset: Int) -> Double {
        var start = 0
        for index in line.words.indices {
            let length = line.words[index].text.utf16.count
            if offset < start + length || index == line.words.count - 1 {
                let time = timing(index)
                let share = length > 0 ? Double(min(max(offset - start, 0), length)) / Double(length) : 0
                return time.start + (time.end - time.start) * share
            }
            start += length
        }
        return line.time
    }

    /// Each romaji word lights up over the same time as the characters it reads.
    private func romajiText(_ pieces: [Romaji.Piece]) -> Text {
        var result = Text("")
        for (index, piece) in pieces.enumerated() {
            if index > 0 { result = result + Text(" ") }
            let start = time(at: piece.location)
            let end = time(at: piece.location + piece.length)
            result = result + Text(piece.text)
                .customAttribute(WordSweep(index: index, start: start, span: max(end - start, 0.05), holds: false))
        }
        return result
    }

    private var words: Text {
        var result = Text("")
        for index in line.words.indices {
            let word = line.words[index]
            let time = timing(index)
            // Only a note the lyrics say is held: its end is given, and it lasts 1.5 s or more.
            let holds = time.known && time.end - time.start >= 1.5 && Self.canEmphasize(word.text)
            result = result + Text(word.text)
                .customAttribute(WordSweep(index: index, start: time.start, span: time.end - time.start, holds: holds))
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

/// When a word is sung. `index` keeps neighbouring words from merging into one run.
private struct WordSweep: TextAttribute {
    var index: Int
    var start: Double
    var span: Double
    /// A held note: glows and swells while it's sung.
    var holds: Bool
}

/// Draws each character dimmed, then the sung part over it at full brightness through a mask
/// whose soft edge moves left to right. Each character rises as the sweep passes it, easing in
/// over half a second, so the whole line lifts in one continuous wave.
private struct WordSweepRenderer: TextRenderer {
    let now: Double
    var isActive = true

    /// Unsung words on the current line: dimmed, but less than other lines (as in Apple Music),
    /// so the line reads as current straight away.
    static let dimmed = 0.65
    /// How far sung text has risen, in points.
    static let lift: CGFloat = 2.5
    /// How long a character takes to rise once the sweep reaches it, in seconds.
    static let riseDuration = 0.9
    /// Characters either side whose timings are averaged for the rise, to even out bursts.
    static let riseSmoothing = 3

    /// How strongly a held note glows and swells: eases in over its first part, stays while it's
    /// held, and fades out gently after it ends (it used to rise and fall with a sine over the
    /// note, so it was gone by the time the note finished and pulsed on long ones).
    static func emphasis(now: Double, start: Double, span: Double) -> Double {
        func ease(_ x: Double) -> Double {
            let t = min(max(x, 0), 1)
            return t * t * (3 - 2 * t)
        }
        // Builds up over the note, so it's strongest at the end of a long one; a note held 1.5 s
        // gets a third of the effect, 3 s or more all of it.
        let strength = min(max((span - 1) / 2, 1.0 / 3), 1)
        let rise = ease((now - start) / max(span * 0.8, 0.3))
        let fall = 1 - ease((now - (start + span)) / 0.6)
        return strength * rise * fall
    }

    /// Room for the glow and swell to draw past the text's edges.
    var displayPadding: EdgeInsets { EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard isActive else {
            for line in layout { context.draw(line) }
            return
        }
        // The rise follows the highlight: each character lifts as the sweep reaches it, but with
        // its timing averaged with its neighbours', so a burst of quick words rolls up as one
        // even wave instead of popping, and a held note doesn't stall it.
        var reached: [Double] = []
        for line in layout {
            for run in line {
                let sweep = run[WordSweep.self]
                let bounds = run.typographicBounds.rect
                for slice in run {
                    guard let sweep else {
                        reached.append(reached.last ?? now)
                        continue
                    }
                    let glyph = slice.typographicBounds.rect
                    let share = bounds.width > 0 ? Double((glyph.midX - bounds.minX) / bounds.width) : 0
                    reached.append(sweep.start + share * sweep.span)
                }
            }
        }
        let smoothed = reached.indices.map { index -> Double in
            let window = reached[max(index - Self.riseSmoothing, 0)...min(index + Self.riseSmoothing, reached.count - 1)]
            return window.reduce(0, +) / Double(window.count)
        }
        var glyphIndex = 0

        for line in layout {
            for run in line {
                guard let sweep = run[WordSweep.self] else {
                    glyphIndex += run.count
                    context.draw(run)
                    continue
                }
                let bounds = run.typographicBounds.rect
                let progress = min(max((now - sweep.start) / max(sweep.span, 0.05), 0), 1)
                let emphasis = sweep.holds ? Self.emphasis(now: now, start: sweep.start, span: sweep.span) : 0

                var word = context
                if emphasis > 0 {
                    let scale = 1 + 0.02 * emphasis
                    word.translateBy(x: bounds.midX, y: bounds.midY)
                    word.scaleBy(x: scale, y: scale)
                    word.translateBy(x: -bounds.midX, y: -bounds.midY)
                }

                // The sweep's soft leading edge, in this run's coordinates.
                let edge = max(bounds.height * 0.45, 6)
                let front = bounds.minX + (bounds.width + edge) * progress
                let litMask: (inout GraphicsContext) -> Void = { layer in
                    let left = bounds.minX - edge
                    layer.clipToLayer { mask in
                        let area = CGRect(x: left - 20, y: bounds.minY - bounds.height, width: max(front - left + 20, 0),
                                          height: bounds.height * 3)
                        mask.fill(Path(area), with: .linearGradient(Gradient(colors: [.white, .white.opacity(0)]),
                                                                    startPoint: CGPoint(x: max(front - edge, left), y: 0),
                                                                    endPoint: CGPoint(x: front, y: 0)))
                    }
                }

                // A held note's glow: one soft blur of the word's sung part, drawn once behind it
                // (it used to be a shadow on every character, which stacked unevenly and was cut
                // off at the sweep's edge).
                if emphasis > 0.01 {
                    // A faint brightening close around the sung part, no visible halo: held notes
                    // can only be told from the lyrics' timings, so a wrong guess mustn't stand out.
                    var glow = word
                    if progress < 1 { litMask(&glow) }
                    glow.addFilter(.shadow(color: .white.opacity(0.4 * emphasis), radius: 4, options: .shadowOnly))
                    glow.draw(run)
                }

                for slice in run {
                    let glyph = slice.typographicBounds.rect
                    // How far this character has risen: an even ease centred on when the
                    // (smoothed) sweep reaches it.
                    let reach = glyphIndex < smoothed.count ? smoothed[glyphIndex] : now
                    glyphIndex += 1
                    let t = min(max((now - reach) / Self.riseDuration + 0.5, 0), 1)
                    let risen = 0.5 - 0.5 * cos(.pi * t)

                    var character = word
                    character.translateBy(x: 0, y: -Self.lift * CGFloat(risen))

                    // Characters the sweep has fully passed are simply lit, and ones it hasn't
                    // reached simply dim; only the one or two under its soft edge need the
                    // (costly) mask, which keeps each frame cheap.
                    let fullyLit = progress >= 1 || front - edge >= glyph.maxX
                    let unlit = progress <= 0 || front <= glyph.minX
                    if !fullyLit {
                        var dim = character
                        dim.opacity = Self.dimmed
                        dim.draw(slice)
                    }
                    guard !unlit else { continue }

                    var lit = character
                    if !fullyLit { litMask(&lit) }
                    lit.draw(slice)
                }
            }
        }
    }
}

/// Turns off the rubber-band stretch at the ends of the scroll view it sits behind, so the lyrics
/// stop dead at their first and last lines. (SwiftUI has no setting for this; it finds the
/// underlying UIScrollView.)
private struct ScrollBounceDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ view: Finder, context: Context) { view.apply() }

    final class Finder: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view {
                    if let scrollView = current as? UIScrollView {
                        scrollView.bounces = false
                        return
                    }
                    // The scroll view may be a sibling higher up rather than a direct ancestor.
                    if let scrollView = current.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                        scrollView.bounces = false
                        return
                    }
                    view = current.superview
                }
            }
        }
    }
}
