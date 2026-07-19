/// One lyric line of a chart: the notes between two line breaks.
public struct Phrase: Equatable, Sendable {
    /// The notes of the phrase, in chart order.
    public var notes: [Note]

    /// The beat the phrase starts on (0 for an empty phrase).
    public var startBeat: Int { notes.first?.startBeat ?? 0 }

    /// The first beat after the phrase's last note ends (0 for an empty phrase).
    public var endBeat: Int { notes.last.map(\.endBeat) ?? 0 }

    /// Creates a phrase from its notes.
    public init(notes: [Note]) {
        self.notes = notes
    }
}
