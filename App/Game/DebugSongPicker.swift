import SwiftUI
import UniformTypeIdentifiers
import NeonMicKit

/// Minimal launcher until the Songbook exists: pick an UltraStar chart and
/// its audio file, see parse warnings, hit SING. The last selection is
/// remembered in UserDefaults (as security-scoped bookmarks where available).
struct DebugSongPicker: View {
    /// Called with the chosen chart and audio; errors thrown back (parse or
    /// audio load failures) are displayed in place.
    let onSing: (_ chartURL: URL, _ audioURL: URL) throws -> Void

    @State private var chartURL: URL?
    @State private var audioURL: URL?
    @State private var song: Song?
    @State private var warnings: [ParseWarning] = []
    @State private var errorMessage: String?
    @State private var pickingChart = false
    @State private var pickingAudio = false

    private static let chartBookmarkKey = "debug.chartBookmark"
    private static let audioBookmarkKey = "debug.audioBookmark"

    var body: some View {
        ZStack {
            NeonMicDesign.ink.ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text("NEON MIC")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(NeonMicDesign.neonPink)
                        .neonGlow(NeonMicDesign.neonPink, radius: 12)
                    Text("debug songbook")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
                }

                VStack(spacing: 14) {
                    pickerRow(
                        label: "chart",
                        fileName: chartURL?.lastPathComponent,
                        accent: NeonMicDesign.electricCyan
                    ) { pickingChart = true }
                    pickerRow(
                        label: "audio",
                        fileName: audioURL?.lastPathComponent,
                        accent: NeonMicDesign.ultraViolet
                    ) { pickingAudio = true }
                }

                if let song {
                    Text("\(song.title) — \(song.artist)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(NeonMicDesign.paper)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.neonPink)
                        .lineLimit(3)
                        .frame(maxWidth: 480)
                }

                if !warnings.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning.description)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .frame(maxWidth: 520, maxHeight: 120)
                    .background(NeonMicDesign.roomGlow, in: RoundedRectangle(cornerRadius: 8))
                }

                Button("SING") {
                    guard let chartURL, let audioURL else { return }
                    do {
                        try onSing(chartURL, audioURL)
                    } catch {
                        errorMessage = "could not start: \(error)"
                    }
                }
                .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.neonPink))
                .disabled(chartURL == nil || audioURL == nil || song == nil)
                .opacity(chartURL == nil || audioURL == nil || song == nil ? 0.4 : 1)
            }
            .padding(40)
        }
        .fileImporter(isPresented: $pickingChart, allowedContentTypes: [.plainText, .text]) { result in
            if case .success(let url) = result { select(chart: url) }
        }
        .fileImporter(isPresented: $pickingAudio, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { select(audio: url) }
        }
        .onAppear(perform: restoreLastSelection)
    }

    private func pickerRow(label: String, fileName: String?, accent: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.6))
                .frame(width: 50, alignment: .trailing)
            Button(fileName ?? "choose…", action: action)
                .buttonStyle(NeonButtonStyle(accent: accent))
        }
    }

    // MARK: Selection

    private func select(chart url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        chartURL = url
        saveBookmark(for: url, key: Self.chartBookmarkKey)
        loadChart(at: url)
    }

    private func select(audio url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        audioURL = url
        saveBookmark(for: url, key: Self.audioBookmarkKey)
    }

    private func loadChart(at url: URL) {
        do {
            let parsed = try UltraStarParser.parseCollectingWarnings(fileAt: url)
            song = parsed.song
            warnings = parsed.warnings
            errorMessage = nil
        } catch {
            song = nil
            warnings = []
            errorMessage = "chart error: \(error)"
        }
    }

    // MARK: Remembered selection

    private func restoreLastSelection() {
        if chartURL == nil, let url = restoreURL(forKey: Self.chartBookmarkKey) {
            chartURL = url
            loadChart(at: url)
        }
        if audioURL == nil {
            audioURL = restoreURL(forKey: Self.audioBookmarkKey)
        }
    }

    /// Prefers a security-scoped bookmark (needed if the app is sandboxed);
    /// falls back to a plain bookmark outside the sandbox.
    private func saveBookmark(for url: URL, key: String) {
        let data = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
        UserDefaults.standard.set(data, forKey: key)
    }

    private func restoreURL(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale))
            ?? (try? URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &isStale))
        _ = url?.startAccessingSecurityScopedResource()
        return url
    }
}
