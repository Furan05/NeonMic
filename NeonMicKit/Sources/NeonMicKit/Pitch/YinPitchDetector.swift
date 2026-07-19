import Foundation

/// Monophonic fundamental-frequency estimator implementing YIN
/// (de Cheveigné & Kawahara, 2002): difference function, cumulative
/// mean-normalized difference (CMND), absolute threshold, then parabolic
/// interpolation around the chosen lag for sub-sample precision.
///
/// The detector reuses internal scratch buffers between calls, so a single
/// instance allocates only on its first frame (or when the lag range grows).
/// That also makes instances non-thread-safe: use one per audio stream.
public final class YinPitchDetector {

    /// CMND value under which a lag qualifies as a pitch candidate. Lower is
    /// stricter; 0.10–0.15 is the usual range for singing voice.
    public var threshold: Double
    /// Lowest detectable fundamental in Hz; bounds the lag search range.
    public var minFrequencyHz: Double
    /// Highest detectable fundamental in Hz; bounds the lag search range.
    public var maxFrequencyHz: Double

    private var difference: [Double] = []
    private var cmnd: [Double] = []

    /// Creates a detector. The defaults cover the human singing range.
    public init(threshold: Double = 0.15, minFrequencyHz: Double = 60, maxFrequencyHz: Double = 1200) {
        self.threshold = threshold
        self.minFrequencyHz = minFrequencyHz
        self.maxFrequencyHz = maxFrequencyHz
    }

    /// Estimates the fundamental frequency of `samples` in Hz, or returns nil
    /// when nothing periodic clears the threshold (silence, noise, or a
    /// fundamental outside the configured range).
    ///
    /// The analysis window is the first half of the buffer, so the buffer
    /// must span at least two periods of the lowest frequency of interest
    /// (2048+ samples at 44.1 kHz for the defaults).
    public func detectFrequency(in samples: [Float], sampleRate: Double) -> Double? {
        let window = samples.count / 2
        let maxLag = min(window, Int(sampleRate / minFrequencyHz))
        let minLag = max(2, Int(sampleRate / maxFrequencyHz))
        guard window > 0, maxLag > minLag + 2 else { return nil }

        if difference.count < maxLag + 1 {
            difference = [Double](repeating: 0, count: maxLag + 1)
            cmnd = [Double](repeating: 1, count: maxLag + 1)
        }

        // Difference function: d[τ] = Σ_{i<window} (x[i] − x[i+τ])²
        for tau in 1...maxLag {
            var sum = 0.0
            for i in 0..<window {
                let delta = Double(samples[i]) - Double(samples[i + tau])
                sum += delta * delta
            }
            difference[tau] = sum
        }

        // CMND: d'[τ] = d[τ] · τ / Σ_{j=1..τ} d[j]; d'[0] = 1 by definition.
        cmnd[0] = 1
        var runningSum = 0.0
        for tau in 1...maxLag {
            runningSum += difference[tau]
            cmnd[tau] = runningSum > 0 ? difference[tau] * Double(tau) / runningSum : 1
        }

        // Absolute threshold: first dip under the threshold, followed to its
        // local minimum so we land in the trough, not on its leading edge.
        var estimate = -1
        var tau = minLag
        while tau <= maxLag {
            if cmnd[tau] < threshold {
                while tau + 1 <= maxLag, cmnd[tau + 1] < cmnd[tau] {
                    tau += 1
                }
                estimate = tau
                break
            }
            tau += 1
        }
        guard estimate > 0 else { return nil }

        // Parabolic interpolation through the trough and its neighbors.
        var refinedLag = Double(estimate)
        if estimate > 1, estimate < maxLag {
            let left = cmnd[estimate - 1]
            let center = cmnd[estimate]
            let right = cmnd[estimate + 1]
            let denominator = 2 * (left - 2 * center + right)
            if abs(denominator) > .ulpOfOne {
                let shift = (left - right) / denominator
                if abs(shift) < 1 {
                    refinedLag += shift
                }
            }
        }

        let frequency = sampleRate / refinedLag
        guard frequency >= minFrequencyHz, frequency <= maxFrequencyHz else { return nil }
        return frequency
    }
}
