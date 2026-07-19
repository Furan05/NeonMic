/// One singer part of a chart. Solo songs have exactly one voice; duets have
/// two (`P1` and `P2` in the UltraStar format).
public struct Voice: Equatable, Sendable {
    /// The lyric lines of this part, in chart order.
    public var phrases: [Phrase]

    /// Creates a voice from its phrases.
    public init(phrases: [Phrase]) {
        self.phrases = phrases
    }
}
