/// The kind of a chart note, matching the line-type character used by the
/// UltraStar text format.
public enum NoteType: Character, CaseIterable, Equatable, Sendable {
    /// A regular sung note (`:`).
    case normal = ":"
    /// A golden note (`*`), worth bonus points.
    case golden = "*"
    /// A freestyle note (`F`); lyrics are shown but the singer is not scored.
    case freestyle = "F"
    /// A rap note (`R`); timed speech, not pitch-scored.
    case rap = "R"
    /// A golden rap note (`G`); bonus-worthy timed speech, not pitch-scored.
    case rapGolden = "G"

    /// Whether notes of this type are scored against the singer's pitch.
    ///
    /// Freestyle and rap notes (including golden rap) only carry lyrics and
    /// timing; pitch detection must ignore them when scoring.
    public var isPitchScored: Bool {
        switch self {
        case .normal, .golden:
            return true
        case .freestyle, .rap, .rapGolden:
            return false
        }
    }
}
