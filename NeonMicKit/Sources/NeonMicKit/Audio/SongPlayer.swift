import AVFoundation

/// Plays a song's backing track through AVAudioEngine.
///
/// ⚠️ Hardware-facing: this class drives the real output device and cannot
/// run in CI; unit tests cover only its error paths. Keep game logic out of
/// here — everything time-related is testable through ``SongClock`` instead.
///
/// `currentTime` derives from the player node's *sample time* — the number
/// of frames the hardware has actually rendered — never from wall-clock
/// `Date` math. The sample clock is what keeps lyrics and the pitch highway
/// glued to the audible audio even when rendering stutters or drifts.
///
/// Not thread-safe: call all members from a single thread (in practice the
/// main actor).
public final class SongPlayer {

    /// Errors thrown by loading and transport control.
    public enum PlaybackError: Error, Equatable {
        /// No file exists at the given URL.
        case fileNotFound(URL)
        /// The file exists but AVFoundation cannot read it as audio.
        case unsupportedFormat(URL)
        /// A transport operation was called before `load(fileAt:)`.
        case noFileLoaded
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var file: AVAudioFile?
    /// File position (seconds) where the currently scheduled segment starts;
    /// the node's sample time counts from this point.
    private var segmentStartTime: TimeInterval = 0
    /// Time reported while paused or stopped, when the sample clock is idle.
    private var restingTime: TimeInterval = 0
    /// Invalidates completion handlers of segments replaced by a seek or
    /// stop, so only a genuine end-of-file fires `onPlaybackEnded`.
    private var scheduleGeneration = 0

    /// Whether the player is currently playing.
    public private(set) var isPlaying = false

    /// Called on the main queue when the file plays through to its end.
    /// After that, call `stop()` or `seek(to:)` before playing again.
    public var onPlaybackEnded: (() -> Void)?

    /// Creates an idle player.
    public init() {
        engine.attach(playerNode)
    }

    deinit {
        playerNode.stop()
        engine.stop()
    }

    /// Duration of the loaded file in seconds (0 when nothing is loaded).
    public var duration: TimeInterval {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// The current playback position in seconds, derived from the sample
    /// clock while playing and frozen at the last position otherwise.
    public var currentTime: TimeInterval {
        guard isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return restingTime
        }
        return segmentStartTime + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Loads an audio file and rewinds to its beginning.
    public func load(fileAt url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.fileNotFound(url)
        }
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw PlaybackError.unsupportedFormat(url)
        }
        invalidateAndStopNode()
        file = audioFile
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)
        segmentStartTime = 0
        restingTime = 0
        scheduleSegment(from: 0)
    }

    /// Starts or resumes playback.
    public func play() throws {
        guard file != nil else { throw PlaybackError.noFileLoaded }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        playerNode.play()
        isPlaying = true
    }

    /// Pauses playback; `currentTime` freezes at the pause position.
    public func pause() {
        guard isPlaying else { return }
        restingTime = currentTime
        playerNode.pause()
        isPlaying = false
    }

    /// Stops playback and rewinds to the beginning.
    public func stop() {
        invalidateAndStopNode()
        segmentStartTime = 0
        restingTime = 0
        scheduleSegment(from: 0)
    }

    /// Moves the playback position, keeping the play/pause state.
    public func seek(to time: TimeInterval) throws {
        guard file != nil else { throw PlaybackError.noFileLoaded }
        let clamped = min(max(0, time), duration)
        let wasPlaying = isPlaying
        // AVAudioPlayerNode has no repositioning: stop (resetting its sample
        // timeline), schedule the remainder of the file, restart if needed.
        invalidateAndStopNode()
        segmentStartTime = clamped
        restingTime = clamped
        scheduleSegment(from: clamped)
        if wasPlaying {
            try play()
        }
    }

    /// Emits `currentTime` at a fixed cadence until the task consuming it is
    /// cancelled. The cadence is wall-clock, but every emitted value reads
    /// the sample clock — use this for UI ticks, not for scoring math.
    public func timeUpdates(every interval: TimeInterval = 1.0 / 30.0) -> AsyncStream<TimeInterval> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    continuation.yield(self.currentTime)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Internals

    private func invalidateAndStopNode() {
        scheduleGeneration += 1
        playerNode.stop()
        isPlaying = false
    }

    private func scheduleSegment(from time: TimeInterval) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        guard startFrame < file.length else { return }
        let frameCount = AVAudioFrameCount(file.length - startFrame)
        let generation = scheduleGeneration
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.isPlaying = false
                self.restingTime = self.duration
                self.onPlaybackEnded?()
            }
        }
    }
}
