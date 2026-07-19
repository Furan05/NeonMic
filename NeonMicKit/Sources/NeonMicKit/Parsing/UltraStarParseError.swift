import Foundation

/// A structural failure that makes a chart unusable.
///
/// The parser throws only for these; recoverable problems on individual lines
/// are reported as ``ParseWarning`` values instead.
public enum UltraStarParseError: Error, Equatable, Sendable {
    /// A required header (`TITLE`, `ARTIST`, or `BPM`) is missing or empty.
    case missingRequiredHeader(String)
    /// The `#BPM` header exists but its value is not a positive number.
    case invalidBPM(lineNumber: Int, value: String)
    /// The chart contains no notes at all.
    case noNotes
    /// The file data could not be decoded with any supported text encoding.
    case undecodableData
}

extension UltraStarParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingRequiredHeader(let name):
            return "The chart is missing the required #\(name) header."
        case .invalidBPM(let lineNumber, let value):
            return "The #BPM value \"\(value)\" on line \(lineNumber) is not a positive number."
        case .noNotes:
            return "The chart contains no notes."
        case .undecodableData:
            return "The file could not be decoded as UTF-8 or Windows-1252 text."
        }
    }
}
