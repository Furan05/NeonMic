import Foundation

/// Everything the HUD shows about one voice at one instant.
public struct GameSnapshot: Equatable, Sendable {
    /// The playback time this snapshot was taken at.
    public let time: TimeInterval
    /// The running score, rounded (`rules.maxScore` at most — 100 000 by
    /// default).
    public let score: Int
    /// Weighted coverage of the notes finalized so far, 0...1 (0 while no
    /// pitch-scored note has finished).
    public let accuracy: Double
    /// Current run of consecutive hit notes.
    public let combo: Int
    /// Best combo of the session.
    public let comboBest: Int
    /// Golden notes caught so far (coverage ≥ star threshold).
    public let starsCaught: Int
    /// Golden notes in the voice.
    public let starsTotal: Int
    /// Results of finished phrases, oldest first. Phrases with no
    /// pitch-scored notes never appear — they cannot be failed.
    public let phraseResults: [PhraseResult]
}

/// Orchestrates scoring for one voice of one song: feed it every
/// ``PitchReading`` from that voice's singer, snapshot it every frame.
/// Duets run two independent sessions, one per voice.
///
/// `snapshot(at:)` finalizes notes and phrases whose end has passed (in
/// latency-compensated input time), so call it with non-decreasing times.
public final class GameSession {

    /// The voice this session scores.
    public let voiceIndex: Int
    /// The clock mapping times to beats (carries the latency offset).
    public let clock: SongClock
    /// The rules in effect.
    public let rules: ScoringRules

    private let voice: Voice
    private let scorer: NoteScorer
    private var combo = ComboTracker()
    private var phraseResults: [PhraseResult] = []
    private var finalizedNotes = 0
    private var finalizedPhrases = 0
    private let starsTotal: Int

    /// Creates a session for one voice of `song`.
    ///
    /// - Parameters:
    ///   - song: The song being played.
    ///   - voiceIndex: Which voice to score; must exist in the song.
    ///   - clock: The clock to use; pass the one carrying the calibrated
    ///     latency offset. Defaults to a zero-latency clock for the song.
    ///   - rules: Scoring configuration.
    public init(song: Song, voiceIndex: Int, clock: SongClock? = nil, rules: ScoringRules = ScoringRules()) {
        precondition(song.voices.indices.contains(voiceIndex), "voiceIndex \(voiceIndex) not in song")
        self.voiceIndex = voiceIndex
        self.clock = clock ?? SongClock(song: song)
        self.rules = rules
        let voice = song.voices[voiceIndex]
        self.voice = voice
        let scorer = NoteScorer(voice: voice, clock: self.clock, rules: rules)
        self.scorer = scorer
        self.starsTotal = scorer.notes.filter { $0.note.type == .golden }.count
    }

    /// Feeds one pitch reading from this voice's singer (ascending times).
    public func process(_ reading: PitchReading) {
        scorer.process(reading)
    }

    /// Finalizes everything that has ended by `time` and returns the HUD
    /// state. Call with non-decreasing times.
    public func snapshot(at time: TimeInterval) -> GameSnapshot {
        finalize(upTo: clock.inputBeat(at: time))

        let starsCaught = scorer.notes
            .filter { $0.note.type == .golden && $0.coverage >= rules.starCoverageThreshold }
            .count
        let finalized = scorer.notes[..<finalizedNotes]
        let finalizedWeight = finalized.reduce(0) { $0 + $1.weight }
        let accuracy = finalizedWeight > 0
            ? finalized.reduce(0) { $0 + $1.coverage * $1.weight } / finalizedWeight
            : 0

        return GameSnapshot(
            time: time,
            score: Int(scorer.score.rounded()),
            accuracy: accuracy,
            combo: combo.current,
            comboBest: combo.best,
            starsCaught: starsCaught,
            starsTotal: starsTotal,
            phraseResults: phraseResults
        )
    }

    /// Highway geometry for this voice with live note coverage wired in.
    public func highwayFrame(at time: TimeInterval, window: HighwayWindow = HighwayWindow()) -> HighwayFrame {
        HighwayFrame.compute(voice: voice, clock: clock, at: time, window: window) { phrase, note in
            scorer.coverage(phraseIndex: phrase, noteIndex: note)
        }
    }

    private func finalize(upTo inputBeat: Double) {
        while finalizedNotes < scorer.notes.count,
              Double(scorer.notes[finalizedNotes].note.endBeat) <= inputBeat {
            combo.registerNote(hit: scorer.isHit(scorer.notes[finalizedNotes]))
            finalizedNotes += 1
        }
        while finalizedPhrases < voice.phrases.count,
              Double(voice.phrases[finalizedPhrases].endBeat) <= inputBeat {
            let phraseIndex = finalizedPhrases
            let scored = scorer.notes.filter { $0.phraseIndex == phraseIndex }
            let weight = scored.reduce(0) { $0 + $1.weight }
            if weight > 0 {
                let accuracy = scored.reduce(0) { $0 + $1.coverage * $1.weight } / weight
                phraseResults.append(PhraseResult(
                    phraseIndex: phraseIndex,
                    accuracy: accuracy,
                    rating: rules.rating(forAccuracy: accuracy)
                ))
            }
            finalizedPhrases += 1
        }
    }
}
