/// Counts consecutive hit notes for the HUD.
///
/// The combo is purely presentational: it never multiplies the score, which
/// is what keeps the "perfect performance = exactly maxScore" invariant true.
public struct ComboTracker: Equatable, Sendable {
    /// The current run of consecutive hits.
    public private(set) var current = 0
    /// The best run seen so far; survives resets.
    public private(set) var best = 0

    /// Creates a zeroed tracker.
    public init() {}

    /// Registers one finalized pitch-scored note: a hit extends the run, a
    /// miss resets it. Freestyle and rap notes must never be registered.
    public mutating func registerNote(hit: Bool) {
        if hit {
            current += 1
            best = max(best, current)
        } else {
            current = 0
        }
    }
}
