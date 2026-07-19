import Foundation

/// One smoothed pitch estimate from the tracker.
public struct PitchReading: Equatable, Sendable {
    /// The capture time of the buffer that produced this reading, passed
    /// through unchanged from ``PitchTracker/process(_:at:)``.
    public let time: TimeInterval
    /// The smoothed fundamental frequency in Hz.
    public let f0Hz: Double
    /// The smoothed pitch as a fractional MIDI note number.
    public let midiNote: Double

    /// Creates a reading.
    public init(time: TimeInterval, f0Hz: Double, midiNote: Double) {
        self.time = time
        self.f0Hz = f0Hz
        self.midiNote = midiNote
    }
}

/// Turns raw mic buffers into stable ``PitchReading`` values: an RMS noise
/// gate rejects silence and room rumble, ``YinPitchDetector`` estimates the
/// fundamental, and a median filter over the last few estimates absorbs the
/// octave-jump glitches every detector occasionally produces.
public final class PitchTracker {

    private let detector: YinPitchDetector
    private let sampleRate: Double
    private let noiseGateRMS: Float
    private let medianWindowSize: Int
    private var recentMidiNotes: [Double] = []

    /// Creates a tracker for buffers of the given sample rate.
    ///
    /// - Parameters:
    ///   - sampleRate: Sample rate of the buffers passed to `process`.
    ///   - detector: The pitch detector to wrap.
    ///   - noiseGateRMS: Buffers with RMS below this are treated as silence.
    ///   - medianWindowSize: Number of recent estimates the median smooths
    ///     over; 5 kills a single-frame octave jump without adding much lag.
    public init(
        sampleRate: Double,
        detector: YinPitchDetector = YinPitchDetector(),
        noiseGateRMS: Float = 0.01,
        medianWindowSize: Int = 5
    ) {
        precondition(medianWindowSize >= 1, "median window must hold at least one estimate")
        self.sampleRate = sampleRate
        self.detector = detector
        self.noiseGateRMS = noiseGateRMS
        self.medianWindowSize = medianWindowSize
    }

    /// Processes one buffer captured at `time`, returning a smoothed reading
    /// or nil when the buffer is silence (which also resets the median
    /// history — a new sung phrase starts fresh) or has no detectable pitch.
    public func process(_ samples: [Float], at time: TimeInterval) -> PitchReading? {
        guard rms(of: samples) >= noiseGateRMS else {
            recentMidiNotes.removeAll(keepingCapacity: true)
            return nil
        }
        guard let frequency = detector.detectFrequency(in: samples, sampleRate: sampleRate) else {
            return nil
        }

        recentMidiNotes.append(MusicalMath.midiNote(fromHz: frequency))
        if recentMidiNotes.count > medianWindowSize {
            recentMidiNotes.removeFirst()
        }
        let smoothedMidi = median(of: recentMidiNotes)
        return PitchReading(time: time, f0Hz: MusicalMath.hz(fromMidiNote: smoothedMidi), midiNote: smoothedMidi)
    }

    private func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
