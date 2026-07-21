import SwiftUI
import UniformTypeIdentifiers
import NeonMicKit

/// The library home: browse songs as a list or a clip-thumbnail grid, see at a
/// glance which have background clips, and drive downloads — per song (swipe /
/// ⌘D), the whole missing set (⇧⌘D), or open the download center (⌥⌘D).
///
/// Reads ``LibraryService`` for songs, ``DownloadCenter`` for live download
/// state, and ``VideoDownloadCoordinator`` for the actual download actions.
struct SongbookView: View {
    /// Starts a run for the chosen song (the app resolves chart + audio).
    var onSing: (LibrarySong) -> Void = { _ in }

    @Environment(LibraryService.self) private var library
    @Environment(DownloadCenter.self) private var downloads
    @Environment(VideoDownloadCoordinator.self) private var coordinator

    @State private var viewMode: ViewMode = .list
    @State private var onlyClips = false
    @State private var search = ""
    @State private var selectedID: LibrarySong.ID?
    @State private var showingDownloads = false
    @State private var showingAutoCreate = false
    @State private var isPickingFolder = false

    private enum ViewMode { case list, grid }

    var body: some View {
        ZStack {
            NeonMicDesign.ink.ignoresSafeArea()

            switch library.state {
            case .noLibrary:
                EmptyLibraryView(
                    onChoose: { isPickingFolder = true },
                    onAutoCreate: { showingAutoCreate = true })
            case .scanning:
                scanning
            case .loaded:
                loaded
            }

            GrainOverlay()
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.chooseRoot(url) }
        }
        .sheet(isPresented: $showingDownloads) {
            VideoDownloadListView()
                .environment(downloads)
                .frame(minWidth: 560, minHeight: 480)
        }
        .sheet(isPresented: $showingAutoCreate) {
            AutoSongCreatorView(onClose: { showingAutoCreate = false })
                .environment(library)
        }
        // A finished download changes what's on disk — refresh the badges.
        .onChange(of: downloads.completedItems.count) { library.refreshVideoStatus() }
    }

    // MARK: States

    private var scanning: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(NeonMicDesign.electricCyan)
            Text("Lecture de la bibliothèque…")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
        }
    }

    private var loaded: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .overlay(alignment: .bottom) { keyboardShortcutSink }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SONGBOOK")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(NeonMicDesign.neonPink)
                        .neonGlow(NeonMicDesign.neonPink, radius: 8)
                    Text(statsLine)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.paper.opacity(0.45))
                }
                Spacer()
                actionButtons
            }

            HStack(spacing: 12) {
                searchField
                Spacer()
                strategyMenu
                filterToggle
                viewModeToggle
            }

            DownloadsSummaryView { showingDownloads = true }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                showingAutoCreate = true
            } label: {
                Label("Création auto", systemImage: "wand.and.stars")
            }
            .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.ultraViolet))
            .controlSize(.small)
            .help("Créer une chanson depuis une URL YouTube")

            Button {
                downloadSelected()
            } label: {
                Label("Télécharger", systemImage: "arrow.down.circle")
            }
            .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.electricCyan))
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!canDownloadSelected)
            .opacity(canDownloadSelected ? 1 : 0.4)

            Button {
                library.downloadAllMissingVideos(using: coordinator)
            } label: {
                Label("Tout (\(library.stats.missingClips))", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.signalYellow))
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(library.stats.missingClips == 0)
            .opacity(library.stats.missingClips == 0 ? 0.4 : 1)

            Button {
                showingDownloads = true
            } label: {
                Label("Téléchargements", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.ultraViolet))
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: [.command, .option])
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
            TextField("Rechercher un titre ou un artiste…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 340)
        .background(Capsule().fill(NeonMicDesign.roomGlow))
        .overlay(Capsule().strokeBorder(NeonMicDesign.paper.opacity(0.12), lineWidth: 1))
    }

    private var strategyMenu: some View {
        Menu {
            ForEach(DownloadStrategy.allCases) { option in
                Button {
                    coordinator.strategy = option
                } label: {
                    Label(option.label, systemImage: coordinator.strategy == option ? "checkmark" : option.systemImage)
                }
            }
        } label: {
            Image(systemName: coordinator.strategy.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(coordinator.isBlockedByStrategy ? NeonMicDesign.signalYellow : NeonMicDesign.paper.opacity(0.7))
                .frame(width: 32, height: 30)
                .background(Capsule().fill(NeonMicDesign.roomGlow))
                .overlay(Capsule().strokeBorder(NeonMicDesign.paper.opacity(0.12), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 44)
        .help("Stratégie de téléchargement : \(coordinator.strategy.label)")
    }

    private var filterToggle: some View {
        Toggle(isOn: $onlyClips.animation(.easeOut(duration: 0.15))) {
            Label("Avec clips", systemImage: "film")
        }
        .toggleStyle(NeonChipToggleStyle(accent: NeonMicDesign.electricCyan))
    }

    private var viewModeToggle: some View {
        HStack(spacing: 0) {
            modeButton(.list, systemImage: "list.bullet")
            modeButton(.grid, systemImage: "square.grid.2x2")
        }
        .background(Capsule().fill(NeonMicDesign.roomGlow))
        .overlay(Capsule().strokeBorder(NeonMicDesign.paper.opacity(0.12), lineWidth: 1))
    }

    private func modeButton(_ mode: ViewMode, systemImage: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { viewMode = mode }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(viewMode == mode ? NeonMicDesign.ink : NeonMicDesign.paper.opacity(0.6))
                .frame(width: 34, height: 28)
                .background(Capsule().fill(viewMode == mode ? NeonMicDesign.electricCyan : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let entries = library.filtered(onlyClips: onlyClips, search: search)
        if entries.isEmpty {
            emptyFilter
        } else if viewMode == .list {
            listContent(entries)
        } else {
            gridContent(entries)
        }
    }

    private func listContent(_ entries: [LibrarySong]) -> some View {
        List {
            ForEach(entries) { entry in
                SongbookRowView(
                    entry: entry,
                    item: downloads.item(for: entry.song),
                    isSelected: selectedID == entry.id
                )
                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .onTapGesture(count: 2) { sing(entry) }
                .onTapGesture { select(entry) }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    swipeDownload(entry)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func gridContent(_ entries: [LibrarySong]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 16)], spacing: 16) {
                ForEach(entries) { entry in
                    SongbookGridCell(
                        entry: entry,
                        item: downloads.item(for: entry.song),
                        isSelected: selectedID == entry.id
                    )
                    .onTapGesture(count: 2) { sing(entry) }
                    .onTapGesture { select(entry) }
                    .contextMenu { rowMenu(entry) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func swipeDownload(_ entry: LibrarySong) -> some View {
        if entry.hasClipSource {
            Button {
                coordinator.download(entry.song)
            } label: {
                Label("Télécharger", systemImage: "arrow.down")
            }
            .tint(NeonMicDesign.electricCyan)
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: LibrarySong) -> some View {
        Button {
            sing(entry)
        } label: {
            Label("Chanter", systemImage: "mic.fill")
        }
        if entry.hasClipSource {
            Button {
                coordinator.download(entry.song)
            } label: {
                Label("Télécharger le clip", systemImage: "arrow.down.circle")
            }
        }
    }

    private var emptyFilter: some View {
        VStack(spacing: 12) {
            Image(systemName: onlyClips ? "film" : "music.note.list")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.25))
            Text(onlyClips ? "Aucune chanson avec clip pour ce filtre." : "Aucune chanson trouvée.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An invisible sink so ⌘D / ⇧⌘D / ⌥⌘D stay live even when their header
    /// buttons scroll out of view is unnecessary (header is fixed), but this
    /// keeps Return-to-sing working from anywhere in the list.
    private var keyboardShortcutSink: some View {
        Button {
            if let entry = selectedEntry { sing(entry) }
        } label: { EmptyView() }
        .keyboardShortcut(.return, modifiers: [])
        .disabled(selectedEntry == nil)
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: Actions

    private var statsLine: String {
        let stats = library.stats
        var parts = ["\(stats.total) chanson\(stats.total > 1 ? "s" : "")"]
        parts.append("\(stats.withClips) clip\(stats.withClips > 1 ? "s" : "")")
        if stats.missingClips > 0 {
            parts.append("\(stats.missingClips) manquant\(stats.missingClips > 1 ? "s" : "")")
        }
        return parts.joined(separator: " · ")
    }

    private var selectedEntry: LibrarySong? {
        library.songs.first { $0.id == selectedID }
    }

    private var canDownloadSelected: Bool {
        selectedEntry?.hasClipSource == true
    }

    private func select(_ entry: LibrarySong) {
        selectedID = entry.id
        coordinator.currentSong = entry.song
    }

    private func downloadSelected() {
        guard let entry = selectedEntry, entry.hasClipSource else { return }
        coordinator.download(entry.song)
    }

    private func sing(_ entry: LibrarySong) {
        select(entry)
        onSing(entry)
    }
}

// MARK: - Empty library

/// Shown before a library folder is chosen: a neon prompt, a folder picker,
/// and the automatic-creation entry point.
private struct EmptyLibraryView: View {
    var onChoose: () -> Void
    var onAutoCreate: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Text("NEON MIC")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(NeonMicDesign.neonPink)
                .neonGlow(NeonMicDesign.neonPink, radius: 12)
            VStack(spacing: 6) {
                Image(systemName: "folder.badge.music")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(NeonMicDesign.electricCyan)
                Text("Choisis ton dossier de bibliothèque")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                Text("un dossier « Artiste - Titre » par chanson")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.45))
            }
            HStack(spacing: 14) {
                Button("Choisir la bibliothèque…", action: onChoose)
                    .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.electricCyan))
                Button {
                    onAutoCreate()
                } label: {
                    Label("Création auto", systemImage: "wand.and.stars")
                }
                .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.ultraViolet))
            }
        }
        .padding(40)
    }
}

// MARK: - Chip toggle

/// A neon on/off chip used for the "Avec clips" filter.
struct NeonChipToggleStyle: ToggleStyle {
    var accent: Color = NeonMicDesign.electricCyan

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(configuration.isOn ? accent : NeonMicDesign.paper.opacity(0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(configuration.isOn ? accent.opacity(0.16) : NeonMicDesign.roomGlow))
                .overlay(Capsule().strokeBorder(accent.opacity(configuration.isOn ? 0.85 : 0.2), lineWidth: 1.2))
                .neonGlow(configuration.isOn ? accent : .clear, radius: configuration.isOn ? 5 : 0)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Songbook") {
    SongbookView()
        .environment(LibraryService.preview())
        .environment(DownloadCenter.previewFilled())
        .environment(VideoDownloadCoordinator())
        .frame(width: 900, height: 640)
}
