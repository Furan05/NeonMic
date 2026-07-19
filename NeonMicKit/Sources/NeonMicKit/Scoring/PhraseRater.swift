/// The verdict flashed at the end of a lyric line.
public enum PhraseRating: String, Equatable, Sendable, CaseIterable {
    case great
    case ok
    case tryAgain
}

/// A finished phrase's accuracy and rating.
public struct PhraseResult: Equatable, Sendable {
    /// Index of the phrase within its voice.
    public let phraseIndex: Int
    /// Weighted coverage of the phrase's pitch-scored notes, 0...1.
    public let accuracy: Double
    /// The rating derived from `accuracy` via ``ScoringRules``.
    public let rating: PhraseRating

    /// Creates a result.
    public init(phraseIndex: Int, accuracy: Double, rating: PhraseRating) {
        self.phraseIndex = phraseIndex
        self.accuracy = accuracy
        self.rating = rating
    }
}

extension ScoringRules {
    /// Maps a phrase accuracy (0...1) to its rating using the configured
    /// thresholds.
    public func rating(forAccuracy accuracy: Double) -> PhraseRating {
        if accuracy >= greatThreshold { return .great }
        if accuracy >= okThreshold { return .ok }
        return .tryAgain
    }
}
