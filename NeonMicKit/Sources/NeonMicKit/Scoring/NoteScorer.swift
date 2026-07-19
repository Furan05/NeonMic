import Foundation

/// Accumulates pitch readings into per-note coverage for one voice.
///
/// Each reading credits the note sounding at its (latency-compensated) beat
/// with the time elapsed since the previous reading, capped by
/// `rules.maxReadingGap` so a stalled pipeline can never credit a hole.
/// Coverage clamps at 1, which is what makes the normalized score exact.
public final class NoteScorer {

    /// Live scoring state of one pitch-scored note.
    public struct NoteState: Equatable, Sendable {
        /// Index of the note's phrase within the voice.
        public let phraseIndex: Int
        /// Index of the note within its phrase.
        public let noteIndex: Int
        /// The chart note.
        public let note: Note
        /// Scoring weight in beats; golden notes count double.
        public let weight: Double
        /// The note's duration in seconds.
        public let durationSeconds: TimeInterval
        /// Total time credited by matching readings so far.
        public internal(set) var matchedSeconds: TimeInterval = 0
        /// Matched time over duration, clamped to 0...1.
        public var coverage: Double {
            durationSeconds > 0 ? min(1, matchedSeconds / durationSeconds) : 0
        }
    }

    /// The rules this scorer was created with.
    public let rules: ScoringRules
    /// The clock used to map reading times to beats.
    public let clock: SongClock
    /// Pitch-scored notes in chart order; freestyle and rap are excluded
    /// from scoring entirely (numerator and denominator).
    public private(set) var notes: [NoteState] = []
    /// Sum of all note weights; 0 when nothing in the voice is pitch-scored.
    public let totalWeight: Double

    private struct Position: Hashable {
        let phrase: Int
        let note: Int
    }

    private var indexByPosition: [Position: Int] = [:]
    private var lastReadingTime: TimeInterval?

    /// Creates a scorer for one voice.
    public init(voice: Voice, clock: SongClock, rules: ScoringRules = ScoringRules()) {
        self.clock = clock
        self.rules = rules
        var built: [NoteState] = []
        var index: [Position: Int] = [:]
        for (phraseIndex, phrase) in voice.phrases.enumerated() {
            for (noteIndex, note) in phrase.notes.enumerated() where note.type.isPitchScored {
                let duration = clock.time(atBeat: Double(note.endBeat)) - clock.time(atBeat: Double(note.startBeat))
                let multiplier = note.type == .golden ? rules.goldenWeightMultiplier : 1
                index[Position(phrase: phraseIndex, note: noteIndex)] = built.count
                built.append(NoteState(
                    phraseIndex: phraseIndex,
                    noteIndex: noteIndex,
                    note: note,
                    weight: Double(note.lengthBeats) * multiplier,
                    durationSeconds: duration
                ))
            }
        }
        notes = built
        indexByPosition = index
        totalWeight = built.reduce(0) { $0 + $1.weight }
    }

    /// Feeds one pitch reading. Readings must arrive in ascending time
    /// order; a reading with a non-increasing timestamp credits nothing.
    public func process(_ reading: PitchReading) {
        let credited: TimeInterval
        if let last = lastReadingTime {
            credited = reading.time > last ? min(reading.time - last, rules.maxReadingGap) : 0
        } else {
            credited = rules.maxReadingGap
        }
        lastReadingTime = reading.time
        guard credited > 0 else { return }

        let beat = clock.inputBeat(at: reading.time)
        guard let index = noteIndex(atBeat: beat) else { return }
        let distance = MusicalMath.semitoneDistanceIgnoringOctave(reading.midiNote, Double(notes[index].note.pitch))
        guard distance <= rules.pitchToleranceSemitones else { return }
        notes[index].matchedSeconds += credited
    }

    /// The running normalized score: a perfect performance is exactly
    /// `rules.maxScore`; a voice with nothing pitch-scored stays at 0.
    public var score: Double {
        guard totalWeight > 0 else { return 0 }
        let earned = notes.reduce(0) { $0 + $1.coverage * $1.weight }
        return earned / totalWeight * rules.maxScore
    }

    /// Whether a note's coverage clears the hit threshold (combo fuel).
    public func isHit(_ state: NoteState) -> Bool {
        state.coverage >= rules.hitCoverageThreshold
    }

    /// Live coverage of the note at a chart position; 0 for positions that
    /// are not pitch-scored (freestyle/rap) or do not exist.
    public func coverage(phraseIndex: Int, noteIndex: Int) -> Double {
        guard let index = indexByPosition[Position(phrase: phraseIndex, note: noteIndex)] else { return 0 }
        return notes[index].coverage
    }

    /// Binary search over the flat, sorted note list (same invariant as
    /// ``SongClock``: charts are ascending by start beat).
    private func noteIndex(atBeat beat: Double) -> Int? {
        var low = 0
        var high = notes.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if Double(notes[mid].note.startBeat) <= beat {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate, beat < Double(notes[candidate].note.endBeat) else { return nil }
        return candidate
    }
}
