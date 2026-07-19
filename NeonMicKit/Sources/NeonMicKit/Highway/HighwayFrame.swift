import Foundation

/// The time window the highway shows around the now-line.
public struct HighwayWindow: Equatable, Sendable {
    /// Seconds of already-played chart kept visible behind the now-line.
    public var lookBehind: TimeInterval
    /// Seconds of upcoming chart visible ahead of the now-line.
    public var lookAhead: TimeInterval

    /// Creates a window (defaults: 1.5 s behind, 4 s ahead).
    public init(lookBehind: TimeInterval = 1.5, lookAhead: TimeInterval = 4.0) {
        self.lookBehind = lookBehind
        self.lookAhead = lookAhead
    }
}

/// One note bar positioned for rendering.
public struct HighwayNote: Equatable, Sendable {
    /// The chart note (style by `note.type`, sing text from `note.text`).
    public let note: Note
    /// Index of the note's phrase within the voice.
    public let phraseIndex: Int
    /// Index of the note within its phrase.
    public let noteIndex: Int
    /// Horizontal position of the note's start edge: 0 at the now-line, 1 at
    /// the look-ahead edge, negative behind the now-line. One unit equals
    /// `window.lookAhead` seconds on *both* sides, so notes cross the whole
    /// highway at constant speed.
    public let normalizedX: Double
    /// The note's length in the same normalized units.
    public let normalizedWidth: Double
    /// Pitch lane 0...11: the octave-folded pitch class of the chart pitch.
    /// Lane 0 = C (chart pitch 0), lane 11 = B; negative pitches fold to the
    /// same classes, so a pitch class always occupies the same lane.
    public let laneIndex: Int
    /// Live coverage from the scorer (0 without a scorer), driving the
    /// "ignited" look of notes being sung correctly.
    public let coverage: Double
}

/// One syllable of a lyric line with its karaoke-wipe progress.
public struct SyllableProgress: Equatable, Sendable {
    /// The syllable text exactly as charted (spaces included).
    public let text: String
    /// 0 before the syllable starts, 1 after it ends, beat-linear between.
    public let progress: Double
}

/// A lyric line prepared for display.
public struct LyricLine: Equatable, Sendable {
    /// Index of the phrase within the voice.
    public let phraseIndex: Int
    /// The line's syllables in order, freestyle and rap included.
    public let syllables: [SyllableProgress]
}

/// Everything the highway renders for one voice at one instant — computed
/// here, deterministically, so the SwiftUI layer stays dumb and this stays
/// testable.
public struct HighwayFrame: Equatable, Sendable {
    /// The playback time the frame was computed for.
    public let time: TimeInterval
    /// Notes visible in the window, chart order.
    public let notes: [HighwayNote]
    /// The line being sung — or, during a rest, the next line coming up.
    /// Nil once the last phrase has ended.
    public let currentLine: LyricLine?
    /// The line after `currentLine`, for the preview row. Nil on the last.
    public let nextLine: LyricLine?

    /// Computes the frame for `voice` at playback time `time`.
    ///
    /// - Parameter coverage: Live coverage lookup by (phraseIndex,
    ///   noteIndex); wire in ``NoteScorer/coverage(phraseIndex:noteIndex:)``
    ///   (or use ``GameSession/highwayFrame(at:window:)``). Defaults to 0.
    public static func compute(
        voice: Voice,
        clock: SongClock,
        at time: TimeInterval,
        window: HighwayWindow = HighwayWindow(),
        coverage: (_ phraseIndex: Int, _ noteIndex: Int) -> Double = { _, _ in 0 }
    ) -> HighwayFrame {
        let earliest = time - window.lookBehind
        let latest = time + window.lookAhead

        var highwayNotes: [HighwayNote] = []
        for (phraseIndex, phrase) in voice.phrases.enumerated() {
            for (noteIndex, note) in phrase.notes.enumerated() {
                let start = clock.time(atBeat: Double(note.startBeat))
                let end = clock.time(atBeat: Double(note.endBeat))
                guard end >= earliest, start <= latest else { continue }
                highwayNotes.append(HighwayNote(
                    note: note,
                    phraseIndex: phraseIndex,
                    noteIndex: noteIndex,
                    normalizedX: (start - time) / window.lookAhead,
                    normalizedWidth: (end - start) / window.lookAhead,
                    laneIndex: laneIndex(forPitch: note.pitch),
                    coverage: coverage(phraseIndex, noteIndex)
                ))
            }
        }

        let currentBeat = clock.currentBeat(at: time)
        let currentIndex = voice.phrases.firstIndex { Double($0.endBeat) > currentBeat }
        let currentLine = currentIndex.map {
            lyricLine(for: voice.phrases[$0], phraseIndex: $0, currentBeat: currentBeat)
        }
        let nextLine: LyricLine? = currentIndex.flatMap { index in
            let next = index + 1
            guard next < voice.phrases.count else { return nil }
            return lyricLine(for: voice.phrases[next], phraseIndex: next, currentBeat: currentBeat)
        }

        return HighwayFrame(time: time, notes: highwayNotes, currentLine: currentLine, nextLine: nextLine)
    }

    /// The stable lane for a chart pitch: its pitch class, folded into one
    /// octave. Lane 0 = C, lane 11 = B, negatives included.
    public static func laneIndex(forPitch pitch: Int) -> Int {
        ((pitch % 12) + 12) % 12
    }

    private static func lyricLine(for phrase: Phrase, phraseIndex: Int, currentBeat: Double) -> LyricLine {
        LyricLine(
            phraseIndex: phraseIndex,
            syllables: phrase.notes.map { note in
                let length = Double(note.lengthBeats)
                let raw: Double
                if length > 0 {
                    raw = (currentBeat - Double(note.startBeat)) / length
                } else {
                    raw = currentBeat >= Double(note.startBeat) ? 1 : 0
                }
                return SyllableProgress(text: note.text, progress: min(1, max(0, raw)))
            }
        )
    }
}
