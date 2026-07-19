/// A recoverable problem found while parsing a chart.
///
/// Warnings mark lines the parser skipped or could not fully honor; the
/// resulting ``Song`` is still playable.
public struct ParseWarning: Equatable, Sendable, CustomStringConvertible {
    /// The 1-based line number in the chart file.
    public let lineNumber: Int
    /// The offending line, exactly as read.
    public let lineContent: String
    /// A human-readable explanation of what was wrong.
    public let message: String

    /// Creates a warning.
    public init(lineNumber: Int, lineContent: String, message: String) {
        self.lineNumber = lineNumber
        self.lineContent = lineContent
        self.message = message
    }

    public var description: String {
        "line \(lineNumber): \(message) — \"\(lineContent)\""
    }
}
