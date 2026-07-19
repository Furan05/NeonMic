import Foundation

/// Pure matching logic for the latency calibration wizard: the app plays
/// metronome ticks at known times, onset detection hears the user clap or
/// sing back, and this estimates the round-trip latency between them.
public enum LatencyCalibrator {

    /// Minimum matched tick/onset pairs required for a trustworthy estimate.
    public static let minimumValidPairs = 3

    /// Deltas beyond this window (seconds) are treated as mismatches — a
    /// stray noise, not a delayed response — and discarded.
    public static let maximumPairDelta: TimeInterval = 0.35

    /// Estimates the latency offset in seconds (positive = the user's onsets
    /// lag the ticks), or nil when fewer than ``minimumValidPairs`` onsets
    /// could be matched.
    ///
    /// Each onset is paired with its nearest tick; when several onsets claim
    /// the same tick only the closest survives. The *median* delta is used so
    /// one missed clap or one wild outlier cannot skew the estimate.
    public static func offset(tickTimes: [TimeInterval], detectedOnsets: [TimeInterval]) -> Double? {
        guard !tickTimes.isEmpty else { return nil }
        let ticks = tickTimes.sorted()

        var bestDeltaByTick: [Int: Double] = [:]
        for onset in detectedOnsets {
            let index = nearestIndex(to: onset, in: ticks)
            let delta = onset - ticks[index]
            guard abs(delta) <= maximumPairDelta else { continue }
            if let existing = bestDeltaByTick[index], abs(existing) <= abs(delta) { continue }
            bestDeltaByTick[index] = delta
        }

        let deltas = bestDeltaByTick.values.sorted()
        guard deltas.count >= minimumValidPairs else { return nil }
        let mid = deltas.count / 2
        return deltas.count.isMultiple(of: 2) ? (deltas[mid - 1] + deltas[mid]) / 2 : deltas[mid]
    }

    /// Binary search for the index of the tick nearest to `time`.
    private static func nearestIndex(to time: TimeInterval, in sortedTicks: [TimeInterval]) -> Int {
        var low = 0
        var high = sortedTicks.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sortedTicks[mid] < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low > 0, abs(sortedTicks[low - 1] - time) <= abs(sortedTicks[low] - time) {
            return low - 1
        }
        return low
    }
}
