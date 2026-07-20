import Foundation

/// The local files produced by a completed video download.
public struct VideoPaths: Equatable, Sendable {
    /// The downloaded background video (`.mp4` preferred, `.mov` accepted).
    public var videoURL: URL
    /// The audio track extracted from the video, if extraction was requested.
    ///
    /// Always an AAC `.m4a`: AVFoundation ships an MP3 *decoder* but no MP3
    /// *encoder*, so the closest native equivalent to "MP3 320 kbps" is AAC
    /// at 320 kbps — see ``AudioExtractor``.
    public var extractedAudioURL: URL?

    /// Creates a paths pair.
    public init(videoURL: URL, extractedAudioURL: URL? = nil) {
        self.videoURL = videoURL
        self.extractedAudioURL = extractedAudioURL
    }
}
