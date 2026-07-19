import Foundation

/// Conversions between frequency and MIDI note numbers, and the
/// octave-agnostic pitch comparison the scorer builds on.
public enum MusicalMath {

    /// Converts a frequency in Hz to a (fractional) MIDI note number,
    /// with A4 = 440 Hz = MIDI 69.
    public static func midiNote(fromHz hz: Double) -> Double {
        69 + 12 * log2(hz / 440)
    }

    /// Converts a (fractional) MIDI note number to its frequency in Hz.
    public static func hz(fromMidiNote midiNote: Double) -> Double {
        440 * exp2((midiNote - 69) / 12)
    }

    /// The distance in semitones between two MIDI notes, ignoring octaves:
    /// the result is always in `0...6`.
    ///
    /// Karaoke scoring must accept a singer performing an octave (or two)
    /// away from the chart — classic console karaoke games score by pitch
    /// *class*, and so do we. (60, 72) is a perfect match; (60, 61) is one
    /// semitone off.
    public static func semitoneDistanceIgnoringOctave(_ a: Double, _ b: Double) -> Double {
        let wrapped = abs(a - b).truncatingRemainder(dividingBy: 12)
        return min(wrapped, 12 - wrapped)
    }
}
