import Charts
import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var range = 14
    @State private var confirmReset = false

    var body: some View {
        // Read revision so the view refreshes when stats are saved.
        let _ = stats.revision
        let days = stats.lastDays(range)
        let totals = stats.totals
        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    tile("Listened", Formatting.hours(stats.totalSeconds), "headphones")
                    tile("Plays", "\(stats.totalPlays)", "play.circle")
                    tile("Full Listens", "\(stats.totalFullListens)", "checkmark.circle")
                    tile("Skips", "\(stats.totalSkips)", "forward.end.alt")
                    tile("Downloaded", Formatting.bytes(totals.downloadedBytes), "arrow.down.circle")
                    tile("Uploaded", Formatting.bytes(totals.uploadedBytes), "arrow.up.circle")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("Range", selection: $range) {
                    Text("7 Days").tag(7)
                    Text("14 Days").tag(14)
                    Text("30 Days").tag(30)
                }
                .pickerStyle(.segmented)
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes))
                        .foregroundStyle(.tint)
                        .cornerRadius(3)
                }
                .chartYAxisLabel("min")
                .frame(height: 170)
                LabeledContent("This period", value: Formatting.hours(days.reduce(0) { $0 + $1.minutes * 60 }))
                LabeledContent("Daily average", value: Formatting.hours(days.reduce(0) { $0 + $1.minutes * 60 } / Double(max(range, 1))))
            } header: {
                Text("Listening")
            }

            Section {
                NavigationLink { SongStatsView() } label: {
                    Label("All Songs", systemImage: "list.number")
                }
            } footer: {
                Text("Every song's plays, full listens, skips, time and playlists, sortable.")
            }

            ranked("Top Songs", stats.topSongs(limit: 10), detail: true)
            skipped(stats.mostSkipped(limit: 10))
            playlistSection
            ranked("Top Artists", stats.topArtists(limit: 10), detail: false)
            ranked("Top Albums", stats.topAlbums(limit: 10), detail: true)

            Section {
                LabeledContent("Songs downloaded", value: "\(totals.downloadedFiles)")
                LabeledContent("Songs uploaded", value: "\(totals.uploadedFiles)")
                LabeledContent("People you've shared with", value: "\(totals.peers.count)")
                LabeledContent("Share ratio", value: ratio(totals))
                LabeledContent("Shared right now", value: "\(library.tracks.count) songs")
                LabeledContent("Uploaded this session", value: Formatting.bytes(stats.sessionUploadedBytes))
                LabeledContent("Counting since", value: totals.since.formatted(date: .abbreviated, time: .omitted))
            } header: {
                Text("Soulseek")
            }

            Section {
                Button("Reset Stats", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Stats stay on this iPhone. A play counts after 30 seconds (or half of a shorter song). A full listen is hearing at least two thirds of a song; a skip is moving on to another song before that. Full listens and skips are counted from this version on.")
            }
        }
        .navigationTitle("Stats")
        .confirmationDialog("Reset all stats?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { stats.reset() }
        }
    }

    @ViewBuilder
    private func skipped(_ items: [StatsStore.Skipped]) -> some View {
        if !items.isEmpty {
            Section("Most Skipped") {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(item.skips) skip\(item.skips == 1 ? "" : "s")").font(.caption.monospacedDigit())
                            Text("\(item.fullListens) full").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Time spent in each playlist (played from it), most first.
    @ViewBuilder
    private var playlistSection: some View {
        let rows = stats.playlistStats
            .compactMap { key, stat -> (name: String, stat: StatsStore.PlaylistStat)? in
                guard stat.seconds >= 1 else { return nil }
                switch key {
                case "favorites": return ("Favorite Songs", stat)
                case "mostPlayed": return ("Most Played", stat)
                case "fewPlaylists": return ("Songs in Few Playlists", stat)
                default:
                    guard let id = UUID(uuidString: key), let playlist = playlists.playlist(id: id) else { return nil }
                    return (playlist.name, stat)
                }
            }
            .sorted { $0.stat.seconds > $1.stat.seconds }
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.name) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).lineLimit(1)
                            Text("Played \(row.stat.starts) time\(row.stat.starts == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatting.hours(row.stat.seconds)).font(.subheadline.monospacedDigit())
                    }
                }
            } header: {
                Text("Playlists")
            } footer: {
                Text("Time listened while playing from each playlist.")
            }
        }
    }

    private func ratio(_ totals: StatsStore.Totals) -> String {
        guard totals.downloadedBytes > 0 else { return totals.uploadedBytes > 0 ? "∞" : "–" }
        return String(format: "%.2f", Double(totals.uploadedBytes) / Double(totals.downloadedBytes))
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func ranked(_ title: String, _ items: [StatsStore.Ranked], detail: Bool) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            if detail, !item.detail.isEmpty {
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(item.plays) plays").font(.caption.monospacedDigit())
                            Text(Formatting.hours(item.seconds)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Compact numbers for the Settings row.
struct StatsPreview: View {
    @EnvironmentObject private var stats: StatsStore

    var body: some View {
        let _ = stats.revision
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stats")
                Text("\(Formatting.hours(stats.seconds(inLast: 7))) this week · ↑ \(Formatting.bytes(stats.totals.uploadedBytes)) shared")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Every song you've listened to, with its numbers, sorted the way you pick.
struct SongStatsView: View {
    enum Order: String, CaseIterable, Identifiable {
        case plays = "Plays", full = "Full Listens", skips = "Skips", skipRate = "Skip Rate"
        case time = "Time Listened", recent = "Last Played", playlists = "In Playlists"
        var id: String { rawValue }
    }

    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore
    @AppStorage("songStats.order") private var order: Order = .plays
    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let stat: StatsStore.TrackStat
        let playlists: Int
        var full: Int { stat.fullListens ?? 0 }
        var skips: Int { stat.skips ?? 0 }
        /// Share of finished-or-skipped listens that were skips.
        var skipRate: Double { full + skips == 0 ? 0 : Double(skips) / Double(full + skips) }
    }

    var body: some View {
        let _ = stats.revision
        let counts = playlists.membershipCounts()
        let rows = stats.allTrackStats
            .map { Row(id: $0.id, stat: $0.stat, playlists: counts[$0.id] ?? 0) }
            .filter { query.isEmpty || $0.stat.title.localizedCaseInsensitiveContains(query)
                || $0.stat.artist.localizedCaseInsensitiveContains(query) }
            .sorted(by: ordering)
        List(rows) { row in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.stat.title).lineLimit(1)
                    Text(row.stat.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(details(row)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(headline(row))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .opacity(library.track(id: row.id) == nil ? 0.5 : 1)
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Songs, artists")
        .navigationTitle("Song Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label(order.rawValue, systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No Listening Yet", systemImage: "chart.bar",
                                       description: Text("Songs show up here once you've played them."))
            }
        }
    }

    private func ordering(_ a: Row, _ b: Row) -> Bool {
        func by<T: Comparable>(_ key: (Row) -> T) -> Bool? { key(a) == key(b) ? nil : key(a) > key(b) }
        let primary: Bool?
        switch order {
        case .plays: primary = by { $0.stat.plays }
        case .full: primary = by { $0.full }
        case .skips: primary = by { $0.skips }
        case .skipRate: primary = by { $0.skipRate } ?? by { $0.skips }
        case .time: primary = by { $0.stat.seconds }
        case .recent: primary = by { $0.stat.lastPlayed ?? .distantPast }
        case .playlists: primary = by { $0.playlists }
        }
        return primary ?? (by { $0.stat.seconds } ?? (a.stat.title < b.stat.title))
    }

    private func headline(_ row: Row) -> String {
        switch order {
        case .plays: return "\(row.stat.plays)"
        case .full: return "\(row.full)"
        case .skips: return "\(row.skips)"
        case .skipRate: return row.full + row.skips == 0 ? "–" : "\(Int((row.skipRate * 100).rounded()))%"
        case .time: return Formatting.hours(row.stat.seconds)
        case .recent: return row.stat.lastPlayed?.formatted(.relative(presentation: .named)) ?? "–"
        case .playlists: return "\(row.playlists)"
        }
    }

    private func details(_ row: Row) -> String {
        "\(row.stat.plays) plays · \(row.full) full · \(row.skips) skips · \(Formatting.hours(row.stat.seconds)) · in \(row.playlists) playlist\(row.playlists == 1 ? "" : "s")"
    }
}
