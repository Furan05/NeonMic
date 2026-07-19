/// A single note of a chart: one syllable sung at one pitch for a beat range.
public struct Note: Equatable, Sendable {
    /// The beat the note starts on, always absolute (relative-mode charts are
    /// converted during parsing).
    public var startBeat: Int
    /// The note's duration in beats.
    public var lengthBeats: Int
    /// The target pitch in semitones as stored in the chart, relative to the
    /// octave the singer chooses (octave-independent scoring compares pitch
    /// classes, not absolute frequencies).
    public var pitch: Int
    /// The syllable text exactly as written in the chart. Leading and trailing
    /// spaces are significant: they define how syllables join into words.
    public var text: String
    /// The note kind (`normal`, `golden`, `freestyle`, `rap`, `rapGolden`).
    public var type: NoteType

    /// The first beat after the note ends.
    public var endBeat: Int { startBeat + lengthBeats }

    /// Creates a note.
    public init(startBeat: Int, lengthBeats: Int, pitch: Int, text: String, type: NoteType) {
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.pitch = pitch
        self.text = text
        self.type = type
    }
}
