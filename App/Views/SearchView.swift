import SoulseekKit
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""
    @State private var showFilters = false
    /// A pasted streaming link being looked up, what it turned out to be, or why it failed.
    @State private var linkLookup: LinkLookup?

    private enum LinkLookup: Equatable {
        case resolving
        case found(SongLinkResolver.Resolved)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                if !soulseek.isLoggedIn {
                    Section { ConnectionBanner() }
                }
                if let linkLookup {
                    Section { linkRow(linkLookup) }
                }
                if !soulseek.currentQuery.isEmpty {
                    Section {
                        FilterChips(showAll: $showFilters)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        HStack {
                            Text("\(soulseek.responseCount) users · \(soulseek.results.count) folders")
                            if soulseek.hiddenCount > 0 {
                                Text("· \(soulseek.hiddenCount) filtered out")
                            }
                            Spacer()
                            if soulseek.filters.activeCount > 0 {
                                Button("Clear Filters") { soulseek.filters = ResultFilters(sort: soulseek.filters.sort) }
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                ForEach(soulseek.results) { folder in
                    NavigationLink(value: folder.id) {
                        FolderRow(folder: folder)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search Soulseek or paste a link")
            .onSubmit(of: .search) { submit(query) }
            .onChange(of: query) { old, new in
                // Pasting a link searches straight away; typed words wait for Search.
                if new.count - old.count > 8, SongLinkResolver.isLink(new) { submit(new) }
                if new.isEmpty, linkLookup != nil { linkLookup = nil }
            }
            .onReceive(router.$pendingSearch) { pending in
                // colon3://search?q=… from Shortcuts.
                guard let pending else { return }
                query = pending
                submit(pending)
                router.pendingSearch = nil
            }
            .navigationDestination(for: String.self) { id in
                FolderDetailView(folderID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: soulseek.filters.activeCount > 0
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                SearchFiltersView()
                    .presentationDetents([.medium, .large])
            }
            .overlay {
                if soulseek.currentQuery.isEmpty && soulseek.isLoggedIn && linkLookup == nil {
                    EmptyStateView(title: "Search Soulseek",
                                   message: "Type an artist, album or song, or paste a song or album link from Spotify, Apple Music, YouTube Music, YouTube, Deezer or SoundCloud to find it here.\n\nResults arrive over about 30 seconds as people answer.",
                                   systemImage: "magnifyingglass")
                }
            }
        }
    }

    /// Searches for the words, or for the song a streaming link points to.
    private func submit(_ text: String) {
        guard SongLinkResolver.isLink(text) else {
            linkLookup = nil
            soulseek.search(text)
            return
        }
        linkLookup = .resolving
        Task {
            do {
                let resolved = try await SongLinkResolver.resolve(text)
                // The bar shows what's searched, so it can be fixed by hand if the lookup was off.
                query = resolved.searchText
                linkLookup = .found(resolved)
                soulseek.search(resolved.searchText)
            } catch {
                linkLookup = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func linkRow(_ lookup: LinkLookup) -> some View {
        switch lookup {
        case .resolving:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking up the link…").foregroundStyle(.secondary)
            }
        case let .found(resolved):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolved.kind == .album ? "Album from \(resolved.service)" : "Song from \(resolved.service)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(resolved.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if !resolved.artist.isEmpty {
                        Text(resolved.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: "link")
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.subheadline)
        }
    }
}

struct FolderRow: View {
    let folder: FolderResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(source: .remote(folder.coverQuery), size: 60, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(2)
                if !folder.parentPath.isEmpty {
                    Text(folder.parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(folder.formatSummary)
                    Text("\(folder.files.count) files")
                    Text(Formatting.bytes(folder.totalSize))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label(folder.username, systemImage: "person")
                        .lineLimit(1)
                    if folder.slotFree {
                        Label("Free slot", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Queue \(folder.queueLength)", systemImage: "hourglass")
                            .foregroundStyle(.orange)
                    }
                    Text(Formatting.speed(folder.speed))
                }
                .font(.caption2)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
    }
}

struct FolderDetailView: View {
    let folderID: String
    @EnvironmentObject private var soulseek: SoulseekModel
    @AppStorage(AppSettings.wholeFolderKey) private var alwaysWholeFolder = false

    /// Songs in the folder the search didn't match, once fetched.
    private var others: [SharedFile] {
        if case let .loaded(files) = soulseek.folderListings[folderID] { return files }
        return []
    }

    var body: some View {
        if let folder = soulseek.folder(withID: folderID) {
            List {
                Section {
                    HStack(spacing: 16) {
                        ArtworkView(source: .remote(folder.coverQuery), size: 110, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(.headline)
                            Text(folder.formatSummary).font(.subheadline).foregroundStyle(.secondary)
                            Text("\(folder.files.count) files · \(Formatting.bytes(folder.totalSize))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        var whole = folder
                        whole.files += others
                        soulseek.downloadFolder(whole)
                    } label: {
                        Label(others.isEmpty ? "Download All" : "Download All \(folder.files.count + others.count) Files",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!soulseek.isLoggedIn)
                } footer: {
                    Text("From \(folder.username) · \(folder.folder). The album cover is fetched too when the folder has one; otherwise it's looked up online.")
                }

                Section {
                    ForEach(folder.files, id: \.path) { file in
                        FileRow(file: file, username: folder.username, folderImages: folder.images)
                    }
                } header: {
                    if soulseek.folderListings[folderID] != nil { Text("Matching Your Search") }
                }

                otherFiles(folder)
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if alwaysWholeFolder, soulseek.isLoggedIn { soulseek.loadWholeFolder(folder) }
            }
        } else {
            Text("This result is no longer available.")
                .foregroundStyle(.secondary)
        }
    }

    /// The rest of the folder: a button to fetch it, then its songs.
    @ViewBuilder
    private func otherFiles(_ folder: FolderResult) -> some View {
        switch soulseek.folderListings[folderID] {
        case nil:
            Section {
                Button {
                    soulseek.loadWholeFolder(folder)
                } label: {
                    Label("Show Other Songs in Folder", systemImage: "folder")
                }
                .disabled(!soulseek.isLoggedIn)
            } footer: {
                Text("Search only lists the files that match your words. This asks \(folder.username) for the rest of the folder.")
            }
        case .some(.loading):
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking \(folder.username) for the folder…").foregroundStyle(.secondary)
                }
            }
        case .some(.failed):
            Section {
                Button {
                    soulseek.loadWholeFolder(folder)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("\(folder.username) didn't send the folder's contents. They may be offline or not accepting connections.")
            }
        case .some(.loaded):
            Section {
                if others.isEmpty {
                    Text("Nothing else in this folder.").foregroundStyle(.secondary)
                }
                ForEach(others, id: \.path) { file in
                    FileRow(file: file, username: folder.username, folderImages: folder.images)
                }
            } header: {
                Text("Other Songs in Folder")
            }
        }
    }
}

struct FileRow: View {
    let file: SharedFile
    let username: String
    let folderImages: [SharedFile]
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusButton
        }
    }

    private var details: String {
        var parts = [Formatting.bytes(file.size)]
        if let duration = file.attributes.duration { parts.append(Formatting.duration(Double(duration))) }
        if let bitrate = file.attributes.bitrate { parts.append("\(bitrate) kbps") }
        if let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            parts.append("\(depth)-bit/\(Formatting.kilohertz(rate)) kHz")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusButton: some View {
        switch soulseek.state(of: file, from: username) {
        case .none, .some(.failed):
            Button {
                soulseek.download(file, from: username, knownImages: folderImages)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(!soulseek.isLoggedIn)
        case .some(.completed):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            ProgressView()
        }
    }
}

struct SearchFiltersView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.wholeFolderKey) private var wholeFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort By", selection: $soulseek.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                }

                Section("Quality") {
                    Picker("File Type", selection: $soulseek.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Minimum Bitrate", selection: $soulseek.filters.minBitrate) {
                        ForEach(ResultFilters.bitrateChoices, id: \.self) { kbps in
                            Text(kbps == 0 ? "Any" : "\(kbps) kbps").tag(kbps)
                        }
                    }
                    Toggle("Playable Formats Only", isOn: $soulseek.audioOnly)
                }

                Section {
                    Toggle("Free Upload Slot Only", isOn: $soulseek.filters.freeSlotOnly)
                    Stepper(value: $soulseek.filters.minFiles, in: 1...30) {
                        LabeledContent("Minimum Files", value: soulseek.filters.minFiles == 1 ? "Any" : "\(soulseek.filters.minFiles)")
                    }
                } header: {
                    Text("Availability")
                } footer: {
                    Text("A minimum of around 6 files skips loose singles and finds complete albums.")
                }

                Section {
                    Toggle("Show Whole Folders", isOn: $wholeFolder)
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Search only lists the songs that match your words. When on, opening a result also asks for the other songs in its folder.")
                }

                Section {
                    TextField("live, remix, karaoke", text: $soulseek.filters.excludeWords)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Exclude Words")
                } footer: {
                    Text("Hides folders whose path contains any of these.")
                }

                if !soulseek.filters.isDefault {
                    Section {
                        Button("Reset Filters", role: .destructive) { soulseek.filters = ResultFilters() }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One-tap sort and filter controls above the results.
struct FilterChips: View {
    @Binding var showAll: Bool
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort By", selection: $soulseek.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                } label: {
                    chip(soulseek.filters.sort.rawValue, systemImage: "arrow.up.arrow.down", active: true)
                }

                Menu {
                    Picker("File Type", selection: $soulseek.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    chip(soulseek.filters.fileType.shortLabel, systemImage: "doc", active: soulseek.filters.fileType != .any)
                }

                Button {
                    soulseek.filters.freeSlotOnly.toggle()
                } label: {
                    chip("Free Slot", systemImage: "checkmark.circle", active: soulseek.filters.freeSlotOnly)
                }

                Button {
                    soulseek.filters.minFiles = soulseek.filters.minFiles > 1 ? 1 : 6
                } label: {
                    chip("Albums", systemImage: "square.stack", active: soulseek.filters.minFiles > 1)
                }

                Button {
                    showAll = true
                } label: {
                    chip("More", systemImage: "slider.horizontal.3", active: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, systemImage: String, active: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Capsule())
    }
}
