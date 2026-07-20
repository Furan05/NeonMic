import SwiftUI
import Observation
import NeonMicKit

/// Which singer a download belongs to. The only thing this carries into the UI
/// is an accent color: player one glows ``NeonMicDesign/neonPink``, player two
/// ``NeonMicDesign/electricCyan`` — the same pink/cyan split the highway uses.
enum DownloadPlayer: Equatable {
    case one
    case two

    /// The neon accent that tints this player's progress bars and rings.
    var accent: Color {
        switch self {
        case .one: NeonMicDesign.neonPink
        case .two: NeonMicDesign.electricCyan
        }
    }

    /// A short label for badges ("P1" / "P2").
    var badge: String {
        switch self {
        case .one: "P1"
        case .two: "P2"
        }
    }
}

/// One row in the download list: a song, who it is for, and its live progress.
///
/// A reference type so the driving `Task` in ``DownloadCenter`` can mutate it
/// in place and SwiftUI re-renders only the affected row. Progress, speed, and
/// ETA are fed from the service's ``DownloadProgress`` stream via ``ingest(_:)``.
@MainActor
@Observable
final class DownloadItem: Identifiable {
    /// Stable identity for `ForEach`.
    let id = UUID()
    /// The song whose background clip is being fetched.
    let song: Song
    /// Which player's accent tints this download.
    var player: DownloadPlayer

    /// The lifecycle state, mirrored from the service's progress stream.
    var state: VideoDownloadState = .pending
    /// The running stage (fetch vs. audio extraction) for the status line.
    var phase: DownloadProgress.Phase = .fetchingVideo
    /// Overall completion in `0...1`.
    var fractionCompleted: Double = 0
    /// Bytes received so far, when the transport reports them.
    var bytesReceived: Int64?
    /// Total expected bytes, when the transport knows them.
    var expectedBytes: Int64?
    /// Smoothed transfer rate in bytes per second, or nil when unknown
    /// (yt-dlp downloads that never report byte counts).
    var speedBytesPerSecond: Double?
    /// Estimated seconds remaining, or nil when it cannot be estimated yet.
    var etaSeconds: Double?
    /// The classified failure, once this download ends in `.failed`. Drives
    /// the error banner and detail sheet.
    var failure: VideoDownloadError?

    /// The service key for this download (`"Artist - Title"`).
    var key: String { song.librarySongName }

    /// Set once the driving task has written the authoritative terminal state,
    /// so a late progress snapshot from the stream cannot overwrite it.
    @ObservationIgnored var isTerminalResolved = false

    // Wall-clock scratch state for the speed/ETA estimate. This is background
    // I/O, not gameplay, so it correctly uses a monotonic `ContinuousClock`
    // rather than the song sample clock (and never `Date()`).
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var lastInstant: ContinuousClock.Instant?
    @ObservationIgnored private var lastBytes: Int64?
    @ObservationIgnored private var lastFraction: Double = 0
    /// The task driving this download; cancelled on cancel/retry.
    @ObservationIgnored var driver: Task<Void, Never>?

    init(song: Song, player: DownloadPlayer) {
        self.song = song
        self.player = player
    }

    /// Folds one progress snapshot into the row, updating state, completion,
    /// and the smoothed speed/ETA estimate.
    func ingest(_ progress: DownloadProgress) {
        // Once the driver has resolved the final state (with its friendly
        // message), ignore any trailing stream snapshots.
        guard !isTerminalResolved else { return }
        phase = progress.phase
        state = progress.state
        fractionCompleted = progress.fractionCompleted

        let now = clock.now
        defer {
            lastInstant = now
            lastBytes = progress.bytesReceived
            lastFraction = progress.fractionCompleted
        }

        guard state.isActive else {
            // Finished, cancelled, or failed: nothing left to estimate.
            speedBytesPerSecond = nil
            etaSeconds = nil
            bytesReceived = progress.bytesReceived
            expectedBytes = progress.expectedBytes
            return
        }

        bytesReceived = progress.bytesReceived
        expectedBytes = progress.expectedBytes

        guard let last = lastInstant else { return }
        let elapsed = seconds(from: last, to: now)
        guard elapsed > 0.15 else { return }  // ignore jittery sub-tick deltas

        if let bytes = progress.bytesReceived, let previous = lastBytes, bytes >= previous {
            // Byte-accurate path (URLSession direct downloads).
            let instant = Double(bytes - previous) / elapsed
            speedBytesPerSecond = smoothed(speedBytesPerSecond, instant)
            if let total = progress.expectedBytes, let speed = speedBytesPerSecond, speed > 0 {
                etaSeconds = Double(max(0, total - bytes)) / speed
            }
        } else {
            // Fraction-only path (yt-dlp): rate of completion → time left.
            let advanced = progress.fractionCompleted - lastFraction
            if advanced > 0 {
                let ratePerSecond = advanced / elapsed
                if ratePerSecond > 0 {
                    let remaining = max(0, 1 - progress.fractionCompleted) / ratePerSecond
                    etaSeconds = smoothed(etaSeconds, remaining)
                }
            }
        }
    }

    /// Resets the estimator so a retried download starts clean.
    func resetProgress() {
        state = .pending
        phase = .fetchingVideo
        fractionCompleted = 0
        bytesReceived = nil
        expectedBytes = nil
        speedBytesPerSecond = nil
        etaSeconds = nil
        failure = nil
        isTerminalResolved = false
        lastInstant = nil
        lastBytes = nil
        lastFraction = 0
    }

    /// Exponential moving average that seeds from the first sample.
    private func smoothed(_ previous: Double?, _ sample: Double) -> Double {
        guard let previous else { return sample }
        return previous * 0.7 + sample * 0.3
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// App-side hub that turns ``VideoDownloaderService`` — a lock-protected,
/// pull-only service — into an observable list the UI can render and drive.
///
/// It owns the visible ``DownloadItem`` rows, launches one driver task per
/// download that pumps the service's ``DownloadProgress`` stream into its row,
/// and exposes start / cancel / retry / clear. The service remains the single
/// source of truth for the actual queue; this is its view model.
@MainActor
@Observable
final class DownloadCenter {

    /// The shared hub, injected into the environment at the app root.
    static let shared = DownloadCenter()

    /// Every download the user has started this session, newest first.
    private(set) var items: [DownloadItem] = []

    private let service: VideoDownloaderService
    private let errors: VideoDownloadErrorHandler
    private let banners: BannerCenter

    init(
        service: VideoDownloaderService = .shared,
        errors: VideoDownloadErrorHandler = .shared,
        banners: BannerCenter = .shared
    ) {
        self.service = service
        self.errors = errors
        self.banners = banners
    }

    // MARK: Queries

    /// The newest row for `song`, if one exists (active or finished).
    func item(for song: Song) -> DownloadItem? {
        items.first { $0.key == song.librarySongName }
    }

    /// Rows still pending or transferring.
    var activeItems: [DownloadItem] { items.filter { $0.state.isActive } }
    /// Rows whose video landed successfully.
    var completedItems: [DownloadItem] { items.filter { $0.state == .completed } }
    /// Rows that failed or were cancelled — the "needs attention" bucket.
    var failedItems: [DownloadItem] {
        items.filter { if case .failed = $0.state { true } else { $0.state == .cancelled } }
    }

    // MARK: Commands

    /// Starts (or restarts) the background-clip download for `song`.
    ///
    /// A no-op when a download for the same song is already active; a finished
    /// or failed row for the same song is replaced by a fresh one.
    func start(_ song: Song, player: DownloadPlayer = .one) {
        if let existing = item(for: song) {
            guard !existing.state.isActive else { return }
            existing.driver?.cancel()
            items.removeAll { $0.id == existing.id }
        }
        let item = DownloadItem(song: song, player: player)
        withAnimation(.easeOut(duration: 0.25)) {
            items.insert(item, at: 0)
        }
        launch(item)
    }

    /// Re-runs a failed or cancelled download in place.
    func retry(_ item: DownloadItem) {
        guard !item.state.isActive else { return }
        errors.markRetried(songName: item.key)
        item.driver?.cancel()
        item.resetProgress()
        launch(item)
    }

    /// Cancels an in-flight download; leaves the row visible as cancelled.
    func cancel(_ item: DownloadItem) {
        service.cancelDownload(for: item.key)
        item.driver?.cancel()
    }

    /// Removes a finished/failed row from the list.
    func remove(_ item: DownloadItem) {
        item.driver?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            items.removeAll { $0.id == item.id }
        }
    }

    /// Clears every finished, cancelled, or failed row at once.
    func clearFinished() {
        withAnimation(.easeOut(duration: 0.2)) {
            items.removeAll { !$0.state.isActive }
        }
    }

    // MARK: Driver

    /// Kicks off the download and pumps its progress stream into `item`.
    ///
    /// Two concurrent tasks: `download` is the authority on the terminal state
    /// (so an instant failure like "no video source" surfaces immediately),
    /// while `pump` attaches to the service's live progress stream once the
    /// queue entry registers and feeds intermediate progress into the row.
    private func launch(_ item: DownloadItem) {
        let song = item.song
        let key = item.key
        let service = self.service
        item.state = .pending
        item.driver = Task { [weak item] in
            let download = Task<VideoPaths, Error> { try await song.downloadVideo(using: service) }

            let pump = Task { [weak item] in
                // The service registers the entry synchronously at the top of
                // `downloadVideo`, but from here we cannot observe that instant,
                // so wait for the live stream to appear, then drain it.
                for _ in 0..<600 {
                    if Task.isCancelled { return }
                    if let updates = service.task(for: key)?.updates {
                        for await progress in updates { item?.ingest(progress) }
                        return
                    }
                    await Task.yield()
                }
            }

            do {
                _ = try await download.value
                pump.cancel()
                if let item {
                    item.ingest(DownloadProgress(
                        phase: item.phase, fractionCompleted: 1, state: .completed))
                    item.isTerminalResolved = true
                    resolveSuccess(item)
                }
            } catch is CancellationError {
                pump.cancel()
                item?.state = .cancelled
                item?.isTerminalResolved = true
            } catch {
                pump.cancel()
                if let item { resolveFailure(item, error: error) }
            }
        }
    }

    /// Marks a finished download resolved and announces it.
    private func resolveSuccess(_ item: DownloadItem) {
        errors.noteSuccess(songName: item.key)
        banners.show(.success(
            title: "Clip téléchargé avec succès",
            message: "« \(item.song.title) » est prêt à chanter 🎤"))
    }

    /// Classifies the failure, records it, marks the row failed with a friendly
    /// one-liner, and raises an actionable error banner.
    private func resolveFailure(_ item: DownloadItem, error: Error) {
        let classified = VideoDownloadError.classify(error)
        item.failure = classified
        item.state = .failed(message: errors.shortMessage(for: classified))
        item.isTerminalResolved = true

        let record = errors.record(classified, songName: item.key)
        banners.show(errors.banner(for: record, onRetry: { [weak self, weak item] in
            guard let self, let item else { return }
            self.retry(item)
        }))
    }
}

#if DEBUG
extension DownloadCenter {
    /// A hub pre-seeded with a row in each state for previews. No real
    /// downloads are launched — the rows carry canned progress only.
    static func previewFilled() -> DownloadCenter {
        let center = DownloadCenter()
        func song(_ title: String, _ artist: String) -> Song {
            Song(title: title, artist: artist, bpm: 120)
        }

        let downloading = DownloadItem(song: song("Neon Skyline", "The Midnights"), player: .one)
        downloading.state = .downloading
        downloading.phase = .fetchingVideo
        downloading.fractionCompleted = 0.42
        downloading.speedBytesPerSecond = 1_480_000
        downloading.etaSeconds = 78

        let extracting = DownloadItem(song: song("Cassette Heart", "Lumen"), player: .two)
        extracting.state = .downloading
        extracting.phase = .extractingAudio
        extracting.fractionCompleted = 0.9

        let pending = DownloadItem(song: song("Corridor", "Violet Static"), player: .one)
        pending.state = .pending

        let completed = DownloadItem(song: song("After Hours Karaoke", "Sora"), player: .two)
        completed.state = .completed
        completed.fractionCompleted = 1

        let failed = DownloadItem(song: song("Ghost Signal", "Neon Divers"), player: .one)
        failed.state = .failed(message: "yt-dlp a échoué : HTTP 403")

        center.items = [downloading, extracting, pending, completed, failed]
        return center
    }
}
#endif

// MARK: - Formatting

/// Shared byte/speed/time formatting for the download UI.
enum DownloadFormat {

    /// A transfer rate like `"1,2 Mo/s"`.
    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(max(0, bytesPerSecond))))/s"
    }

    /// A byte count like `"48,3 Mo"`.
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }

    /// A rough time-remaining phrase like `"~2 min 10 s"`.
    static func eta(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 1 { return "presque fini" }
        if total < 60 { return "~\(total) s" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return "~\(minutes) min \(remainder) s" }
        let hours = minutes / 60
        return "~\(hours) h \(minutes % 60) min"
    }
}
