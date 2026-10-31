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
    /// Where each line sits in the lyrics column (before scrolling), to bring the current one into place.
    @State private var lineFrames: [Int: CGRect] = [:]
    /// How far you've scrolled the lyrics yourself; eases back to 0 after you stop.
    @State private var dragOffset: CGFloat = 0
    @State private var dragStart: CGFloat?
    /// While you scroll the lyrics yourself, every line is sharp (no blur), like Apple Music.
    @State private var browsing = false
    @State private var browseEnd: Task<Void, Never>?
    /// Romaji for Japanese lines, by line id (synced) or line number (plain).
    @State private var romaji: [Int: [Romaji.Piece]] = [:]
    @AppStorage(LyricsView.romajiKey) private var showRomaji = true

    static let romajiKey = "lyrics.showRomaji"

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
        let loaded = lyrics
        romaji = await Task.detached(priority: .userInitiated) { Self.romanize(loaded) }.value
        checking = []
        isLoading = false
    }

    nonisolated private static func romanize(_ lyrics: Lyrics?) -> [Int: [Romaji.Piece]] {
        var result: [Int: [Romaji.Piece]] = [:]
        switch lyrics {
        case let .synced(lines):
            for line in lines { result[line.id] = Romaji.pieces(line.text) }
        case let .plain(lines):
            for (index, line) in lines.enumerated() { result[index] = Romaji.pieces(line) }
        default:
            break
        }
        return result
    }

    /// PetitLyrics' timings run late: measured against Apple Music on the same song, its words
    /// land about three quarters of a second after the singing. Other sources are used as they are.
    private var timingLead: Double { fetchedFrom == LyricsSource.petit.rawValue ? 0.75 : 0 }

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
    private func synced(_ lines: [LyricLine]) -> some View {
        let active = activeLine(in: lines)
        return GeometryReader { geometry in
            let target = scrollTarget(active: active, height: geometry.size.height)
            VStack(alignment: .leading, spacing: 26) {
                ForEach(lines) { line in
                    let isActive = line.id == active
                    let distance = active < 0 ? 1 : abs(line.id - active)
                    let next = line.id + 1 < lines.count ? lines[line.id + 1].time : nil
                    lineBlock(line, isActive: isActive, next: next)
                        // Full height whatever the column's size, so long lines wrap instead of being cut off.
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white.opacity(isActive ? 1 : 0.32))
                        .blur(radius: isActive || browsing ? 0 : min(Double(distance) * 0.6, 2.4))
                        .scaleEffect(isActive ? 1 : 0.97, anchor: .leading)
                        .animation(.easeInOut(duration: 0.6), value: active)
                        .animation(.easeOut(duration: 0.3), value: browsing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("lyricsColumn")) } action: { frame in
                            lineFrames[line.id] = frame
                        }
                        .offset(y: target + dragOffset)
                        // Only a line change animates the column; layout changes (romaji arriving) just settle.
                        .animation(.spring(response: 0.8, dampingFraction: 0.86).delay(stagger(line.id, active: active)),
                                   value: active)
                        .onTapGesture { onSeek(line.time) }
                }
            }
            .coordinateSpace(.named("lyricsColumn"))
            .padding(.horizontal, 28)
            .frame(width: geometry.size.width, alignment: .topLeading)
            .onChange(of: active) { oldValue, newValue in
                // While you're reading elsewhere, keep your place instead of jumping to the new line.
                guard browsing else { return }
                let height = geometry.size.height
                dragOffset -= scrollTarget(active: newValue, height: height) - scrollTarget(active: oldValue, height: height)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(browseDrag)
        .mask(fade)
    }

    private func scrollTarget(active: Int, height: CGFloat) -> CGFloat {
        height * 0.3 - (lineFrames[max(active, 0)]?.minY ?? 0)
    }

    /// Lines below the current one set off a little after it, up to a quarter second.
    private func stagger(_ id: Int, active: Int) -> Double {
        min(Double(max(id - max(active, 0), 0)) * 0.045, 0.25)
    }

    private var browseDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil { dragStart = dragOffset }
                dragOffset = (dragStart ?? 0) + value.translation.height
                if !browsing { withAnimation(.easeOut(duration: 0.25)) { browsing = true } }
                browseEnd?.cancel()
            }
            .onEnded { value in
                dragStart = nil
                let fling = (value.predictedEndTranslation.height - value.translation.height) * 0.6
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { dragOffset += fling }
                browseEnd?.cancel()
                browseEnd = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.9, dampingFraction: 0.88)) {
                        dragOffset = 0
                        browsing = false
                    }
                }
            }
    }

    /// The current line fills word by word when the lyrics have word timings; every other line
    /// (and lyrics without them) is plain text. Romaji, when on, sits under Japanese lines.
    @ViewBuilder
    private func lineBlock(_ line: LyricLine, isActive: Bool, next: Double?) -> some View {
        let romaji = showRomaji ? romaji[line.id] : nil
        if line.text == "♪", line.words.isEmpty {
            InterludeDots(start: line.time, end: next ?? line.time + 8, position: position + timingLead, isActive: isActive)
        } else if !line.words.isEmpty {
            // The same view whether current or not, so a line that stops being current just dims
            // where it is, instead of a copy fading out behind the scrolling lines.
            WordByWordLine(line: line, romaji: romaji, position: isActive ? position + timingLead : 0, isActive: isActive)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text).font(LyricsFont.line)
                if let romaji { Text(romaji.map(\.text).joined(separator: " ")).font(LyricsFont.romaji) }
            }
        }
    }

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
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { context in
            let now = estimate(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                words.font(LyricsFont.line)
                    .textRenderer(WordSweepRenderer(now: now, isActive: isActive, rise: riseSpan))
                if let romaji {
                    romajiText(romaji)
                        .font(LyricsFont.romaji)
                        .textRenderer(WordSweepRenderer(now: now, isActive: isActive, rise: riseSpan))
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

    /// The time the gentle rise travels across the line: from the first word to the last, at an
    /// even pace whatever the singing does, so the lyrics and the romaji lift together.
    private var riseSpan: ClosedRange<Double> {
        guard !line.words.isEmpty else { return line.time...line.time + 1 }
        let start = timing(0).start
        return start...max(timing(line.words.count - 1).end, start + 0.5)
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
            let holds = time.known && time.end - time.start >= 1 && Self.canEmphasize(word.text)
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
    /// When the rise starts at the line's first character and reaches its last.
    var rise: ClosedRange<Double> = 0...1

    /// Unsung words on the current line: dimmed, but less than other lines (as in Apple Music),
    /// so the line reads as current straight away.
    static let dimmed = 0.65
    /// How far sung text has risen, in points.
    static let lift: CGFloat = 2.5
    /// How long a character takes to rise once the sweep reaches it, in seconds.
    static let riseDuration = 1.1

    /// Room for the glow and swell to draw past the text's edges.
    var displayPadding: EdgeInsets { EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The rise moves through the text in reading order at an even pace, measured by width,
        // so every character lifts the same way and neighbours overlap smoothly.
        var totalWidth: CGFloat = 0
        for line in layout { for run in line { for slice in run { totalWidth += slice.typographicBounds.width } } }
        var passed: CGFloat = 0
        for line in layout {
            for run in line {
                guard isActive, let sweep = run[WordSweep.self] else {
                    for slice in run { passed += slice.typographicBounds.width }
                    context.draw(run)
                    continue
                }
                let bounds = run.typographicBounds.rect
                let progress = min(max((now - sweep.start) / max(sweep.span, 0.05), 0), 1)
                let emphasis = sweep.holds ? sin(.pi * progress) : 0

                var word = context
                if emphasis > 0 {
                    let scale = 1 + 0.03 * emphasis
                    word.translateBy(x: bounds.midX, y: bounds.midY)
                    word.scaleBy(x: scale, y: scale)
                    word.translateBy(x: -bounds.midX, y: -bounds.midY)
                }

                // The sweep's soft leading edge, in this run's coordinates.
                let edge = max(bounds.height * 0.45, 6)
                let front = bounds.minX + (bounds.width + edge) * progress

                for slice in run {
                    let glyph = slice.typographicBounds.rect
                    // When the sweep reaches this character, and how far it has risen since.
                    let share = totalWidth > 0 ? Double((passed + glyph.width / 2) / totalWidth) : 0
                    passed += glyph.width
                    let reached = rise.lowerBound + share * (rise.upperBound - rise.lowerBound)
                    let t = min(max((now - reached) / Self.riseDuration + 0.5, 0), 1)
                    let risen = 0.5 - 0.5 * cos(.pi * t)

                    var character = word
                    character.translateBy(x: 0, y: -Self.lift * CGFloat(risen))

                    if progress < 1 {
                        var dim = character
                        dim.opacity = Self.dimmed
                        dim.draw(slice)
                    }
                    // Lit only once the sweep has reached this character.
                    guard progress > 0, front > glyph.minX else { continue }

                    var lit = character
                    if progress < 1 {
                        let left = bounds.minX - edge
                        lit.clipToLayer { mask in
                            let area = CGRect(x: left, y: bounds.minY - bounds.height, width: max(front - left, 0), height: bounds.height * 3)
                            mask.fill(Path(area), with: .linearGradient(Gradient(colors: [.white, .white.opacity(0)]),
                                                                        startPoint: CGPoint(x: max(front - edge, left), y: 0),
                                                                        endPoint: CGPoint(x: front, y: 0)))
                        }
                    }
                    if emphasis > 0 {
                        lit.addFilter(.shadow(color: .white.opacity(0.55 * emphasis), radius: 12 * emphasis))
                    }
                    lit.draw(slice)
                }
            }
        }
    }
}
