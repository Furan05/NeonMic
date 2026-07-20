import Foundation

/// The lifecycle of one queued video download.
public enum VideoDownloadState: Equatable, Sendable {
    /// Queued behind earlier downloads; nothing transferred yet.
    case pending
    /// Bytes are flowing (or yt-dlp is running).
    case downloading
    /// The video (and extracted audio, when requested) is on disk.
    case completed
    /// `cancelDownload(for:)` interrupted the download.
    case cancelled
    /// The download stopped with an error, described for display.
    case failed(message: String)

    /// Whether the download still occupies the queue.
    public var isActive: Bool {
        self == .pending || self == .downloading
    }
}

/// A progress snapshot emitted while a download advances.
///
/// Emitted by ``VideoDownloadTask/updates`` and passed to
/// ``VideoFetchReporter/onProgress``. `fractionCompleted` covers the whole
/// job: when audio extraction is requested the fetch phase spans 0…0.85 and
/// extraction the remainder.
public struct DownloadProgress: Equatable, Sendable {
    /// Which stage of the job is running.
    public enum Phase: Equatable, Sendable {
        /// Transferring the video file.
        case fetchingVideo
        /// Re-encoding the video's audio track with ``AudioExtractor``.
        case extractingAudio
    }

    /// The running stage.
    public var phase: Phase
    /// Overall completion in `0...1`; downloads with unknown size stay at 0
    /// until they finish.
    public var fractionCompleted: Double
    /// Bytes received so far, when the transport reports them.
    public var bytesReceived: Int64?
    /// Total expected bytes, when the transport knows them.
    public var expectedBytes: Int64?
    /// The download state at the time of the snapshot.
    public var state: VideoDownloadState

    /// Creates a snapshot.
    public init(
        phase: Phase,
        fractionCompleted: Double,
        bytesReceived: Int64? = nil,
        expectedBytes: Int64? = nil,
        state: VideoDownloadState = .downloading
    ) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.bytesReceived = bytesReceived
        self.expectedBytes = expectedBytes
        self.state = state
    }
}
