import Foundation

/// Every tunable number of the scoring system in one place, so balancing the
/// game never means hunting magic constants through the engine.
public struct ScoringRules: Equatable, Sendable {

    /// Score of a perfect performance. The score is normalized: whatever the
    /// chart's length or note mix, singing everything perfectly yields
    /// exactly this value.
    public var maxScore: Double

    /// Weight multiplier for golden notes (weight = note beats × this).
    public var goldenWeightMultiplier: Double

    /// Maximum octave-agnostic distance (semitones) between the sung pitch
    /// and the chart pitch for a reading to count.
    public var pitchToleranceSemitones: Double

    /// Phrase accuracy at or above this rates ``PhraseRating/great``.
    public var greatThreshold: Double

    /// Phrase accuracy at or above this (but below `greatThreshold`) rates
    /// ``PhraseRating/ok``; anything lower is ``PhraseRating/tryAgain``.
    public var okThreshold: Double

    /// Minimum coverage for a note to count as hit (feeds the combo).
    public var hitCoverageThreshold: Double

    /// Minimum coverage for a golden note to count as a star caught.
    public var starCoverageThreshold: Double

    /// Cap on the duration credited by a single reading. Readings arrive
    /// ~40–50/s; capping the gap to the previous reading means a stalled
    /// pipeline can never credit a long hole in one go.
    public var maxReadingGap: TimeInterval

    /// Creates rules, defaulting every knob to the shipping values.
    public init(
        maxScore: Double = 100_000,
        goldenWeightMultiplier: Double = 2,
        pitchToleranceSemitones: Double = 0.75,
        greatThreshold: Double = 0.90,
        okThreshold: Double = 0.60,
        hitCoverageThreshold: Double = 0.5,
        starCoverageThreshold: Double = 0.8,
        maxReadingGap: TimeInterval = 0.05
    ) {
        self.maxScore = maxScore
        self.goldenWeightMultiplier = goldenWeightMultiplier
        self.pitchToleranceSemitones = pitchToleranceSemitones
        self.greatThreshold = greatThreshold
        self.okThreshold = okThreshold
        self.hitCoverageThreshold = hitCoverageThreshold
        self.starCoverageThreshold = starCoverageThreshold
        self.maxReadingGap = maxReadingGap
    }
}
