import Foundation
@testable import NeonMicKit

/// Builds a one-voice test song. BPM 60 makes one chart beat exactly 0.25 s,
/// so a 4-beat note lasts one second — convenient for exact expectations.
func makeSong(bpm: Double = 60, gapMs: Double = 0, phrases: [[Note]]) -> Song {
    Song(title: "Test", artist: "Singer", bpm: bpm, gapMs: gapMs, voices: [Voice(phrases: phrases.map(Phrase.init))])
}

/// Shorthand note constructor for test charts.
func chartNote(_ startBeat: Int, _ lengthBeats: Int, pitch: Int, type: NoteType = .normal, text: String = "la") -> Note {
    Note(startBeat: startBeat, lengthBeats: lengthBeats, pitch: pitch, text: text, type: type)
}

/// Deterministic fake singer: emits the PitchReading sequence a real
/// mic+tracker pipeline would produce for a voice, without any audio.
enum SimulatedSinger {

    /// Generates readings tracking each pitch-scored note of `voice`.
    ///
    /// - Parameters:
    ///   - semitoneOffset: Detuning applied to every reading (−12 for an
    ///     octave-down singer).
    ///   - noteFraction: How much of each note's duration is sung (from its
    ///     start).
    ///   - interval: Spacing between readings (~40–50/s like the real
    ///     tracker).
    ///   - sings: Filter deciding which notes are sung at all, by
    ///     (phraseIndex, noteIndex).
    static func readings(
        for voice: Voice,
        clock: SongClock,
        semitoneOffset: Double = 0,
        noteFraction: Double = 1.0,
        interval: TimeInterval = 0.02,
        sings: (_ phraseIndex: Int, _ noteIndex: Int) -> Bool = { _, _ in true }
    ) -> [PitchReading] {
        var readings: [PitchReading] = []
        for (phraseIndex, phrase) in voice.phrases.enumerated() {
            for (noteIndex, note) in phrase.notes.enumerated() {
                guard note.type.isPitchScored, sings(phraseIndex, noteIndex) else { continue }
                let start = clock.time(atBeat: Double(note.startBeat))
                let end = clock.time(atBeat: Double(note.endBeat))
                let singUntil = start + (end - start) * noteFraction
                let midi = Double(note.pitch) + semitoneOffset
                var time = start
                while time < singUntil - 1e-9 {
                    readings.append(PitchReading(time: time, f0Hz: MusicalMath.hz(fromMidiNote: midi), midiNote: midi))
                    time += interval
                }
            }
        }
        return readings
    }
}
