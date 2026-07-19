import AVFoundation
import Foundation
import Observation
import NeonMicKit

/// One sung-pitch sample kept for the comet tail.
struct CometSample: Equatable {
    /// Song playback time of the reading.
    let time: TimeInterval
    /// Fractional MIDI note; fold with `HighwayFrame.lanePosition(forMidiNote:)`.
    let midiNote: Double
}

/// A phrase verdict currently flashing on screen, with its age in song time
/// so the stamp animation is a pure function of the sample clock.
struct PhraseStamp: Equatable {
    let rating: PhraseRating
    /// Seconds since the verdict landed, `0..<PhraseStamp.duration`.
    let age: TimeInterval

    /// Total on-screen life of a stamp (spring ~0.6 s, then fade).
    static let duration: TimeInterval = 1.0
}

/// Owns one playable run of one song: chart → clock → player → mic → pitch
/// tracker → scoring session, all keyed to the *sample clock*
/// (`SongPlayer.currentTime`) — never wall-clock `Date`.
///
/// Views stay dumb: they read `snapshot()` / `highwayFrame()` each display
/// frame and render what they are given.
@MainActor
@Observable
final class GameCoordinator {

    /// UserDefaults key for the calibrated round-trip latency (milliseconds).
    static let latencyOffsetKey = "latencyOffsetMs"

    /// Seconds of pitch history kept for the comet tail — matches the
    /// highway's default look-behind so the trail dies exactly at the edge.
    static let trailDuration: TimeInterval = 1.5

    /// The parsed song (metadata for the HUD cards).
    let song: Song
    /// Non-fatal chart problems, surfaced by the debug picker.
    let warnings: [ParseWarning]

    /// The voice this run scores. Duets are a later feature; voice 0 for now.
    private let voiceIndex = 0
    private let audioURL: URL
    private let songPlayer = SongPlayer()
    private let micEngine = MicEngine()
    private var session: GameSession
    private var pitchTracker: PitchTracker?
    private var trackerSampleRate: Double = 0
    private var micTask: Task<Void, Never>?

    /// Whether the run is paused (player and mic tap stop together).
    private(set) var isPaused = false
    /// Whether the backing track has played through to its end.
    private(set) var isFinished = false
    /// The newest raw pitch reading — the comet's head. Views should treat a
    /// reading older than ~0.2 s as "not singing" rather than a live head.
    private(set) var latestReading: PitchReading?
    /// The last ``GameCoordinator/trailDuration`` seconds of sung pitch,
    /// oldest first — the comet's tail.
    private(set) var cometTrail: [CometSample] = []
    /// A problem worth showing in the HUD (mic failed to start, …).
    private(set) var statusMessage: String?

    /// Creates a coordinator: parses the chart, builds the latency-aware
    /// clock and the scoring session, and loads (but does not start) the
    /// backing track.
    init(chartURL: URL, audioURL: URL) throws {
        let parsed = try UltraStarParser.parseCollectingWarnings(fileAt: chartURL)
        self.song = parsed.song
        self.warnings = parsed.warnings
        self.audioURL = audioURL

        let latencyOffsetMs = UserDefaults.standard.double(forKey: Self.latencyOffsetKey)
        let clock = SongClock(song: parsed.song, latencyOffsetMs: latencyOffsetMs)
        self.session = GameSession(song: parsed.song, voiceIndex: 0, clock: clock)

        try songPlayer.load(fileAt: audioURL)
        songPlayer.onPlaybackEnded = { [weak self] in
            guard let self else { return }
            self.isFinished = true
            self.stopMic()
        }
    }

    // MARK: Clock-derived state (read every display frame)

    /// The current song playback time, from the player's sample clock.
    var currentTime: TimeInterval { songPlayer.currentTime }

    /// Duration of the backing track in seconds.
    var duration: TimeInterval { songPlayer.duration }

    /// HUD state at the current playback time.
    func snapshot() -> GameSnapshot {
        session.snapshot(at: songPlayer.currentTime)
    }

    /// Highway geometry at the current playback time.
    func highwayFrame() -> HighwayFrame {
        session.highwayFrame(at: songPlayer.currentTime)
    }

    /// The phrase verdict to flash right now, derived — not stored — from
    /// the newest ``GameSnapshot/phraseResults`` entry and the song clock,
    /// so rendering never mutates state mid-frame.
    func phraseStamp(for snapshot: GameSnapshot) -> PhraseStamp? {
        guard let last = snapshot.phraseResults.last else { return nil }
        let phrases = song.voices[voiceIndex].phrases
        guard phrases.indices.contains(last.phraseIndex) else { return nil }
        // The verdict lands when the phrase's end passes in *input* time.
        let clock = session.clock
        let landedAt = clock.time(atBeat: Double(phrases[last.phraseIndex].endBeat)) + clock.latencyOffsetMs / 1000
        let age = snapshot.time - landedAt
        guard age >= 0, age < PhraseStamp.duration else { return nil }
        return PhraseStamp(rating: last.rating, age: age)
    }

    // MARK: Transport

    /// Starts the backing track and the microphone together.
    func start() throws {
        try songPlayer.play()
        startMic()
    }

    /// Pauses the run: backing track and mic tap stop together, and the
    /// sample clock freezes, so scoring sees no gap.
    func pause() {
        guard !isPaused, !isFinished else { return }
        isPaused = true
        songPlayer.pause()
        stopMic()
    }

    /// Resumes a paused run: player and mic restart together.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        try? songPlayer.play()
        startMic()
    }

    /// Restarts the song from the top with a **fresh** ``GameSession``.
    ///
    /// This is a rebuild, not a rewind, by contract: `GameSession.snapshot(at:)`
    /// finalizes notes and phrases monotonically and must be called with
    /// non-decreasing times, so a session that has seen time T can never be
    /// asked about time 0 again — reusing one across a rewind is a bug.
    func restart() {
        stopMic()
        try? songPlayer.seek(to: 0)
        session = GameSession(song: song, voiceIndex: voiceIndex, clock: session.clock)
        cometTrail.removeAll()
        latestReading = nil
        statusMessage = nil
        isFinished = false
        isPaused = false
        try? songPlayer.play()
        startMic()
    }

    /// Tears the run down (leaving the gameplay screen).
    func stop() {
        stopMic()
        songPlayer.stop()
    }

    // MARK: Mic pipeline

    private func startMic() {
        do {
            let stream = try micEngine.start()
            statusMessage = nil
            micTask = Task { [weak self] in
                for await buffer in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.ingest(buffer)
                }
            }
        } catch {
            statusMessage = "microphone unavailable — singing is not being scored"
        }
    }

    private func stopMic() {
        micTask?.cancel()
        micTask = nil
        micEngine.stop()
    }

    /// Turns one captured buffer into a scored, drawable pitch reading.
    private func ingest(_ buffer: MicEngine.CapturedBuffer) {
        guard songPlayer.isPlaying else { return }
        if pitchTracker == nil || trackerSampleRate != buffer.sampleRate {
            pitchTracker = PitchTracker(sampleRate: buffer.sampleRate)
            trackerSampleRate = buffer.sampleRate
        }

        // Map the buffer's host-clock capture time onto the song timeline:
        // it was captured `captureAge` seconds before "now", and "now" on the
        // song timeline is the player's sample clock — no Date() anywhere.
        let hostNow = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let captureAge = max(0, hostNow - buffer.time)
        let songTime = songPlayer.currentTime - captureAge

        guard let reading = pitchTracker?.process(buffer.samples, at: songTime) else { return }
        session.process(reading)
        latestReading = reading

        cometTrail.append(CometSample(time: reading.time, midiNote: reading.midiNote))
        let cutoff = reading.time - Self.trailDuration
        if let firstKept = cometTrail.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            cometTrail.removeFirst(firstKept)
        }
    }
}
