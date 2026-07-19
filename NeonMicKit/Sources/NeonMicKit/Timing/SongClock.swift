import Foundation

/// Maps between playback time and chart beats for one song, and answers the
/// game loop's "what is at this beat" queries.
///
/// Two time-to-beat conversions exist on purpose:
/// - ``currentBeat(at:)`` is the *chart/audio* side, used to draw lyrics and
///   the pitch highway in sync with what is playing.
/// - ``inputBeat(at:)`` is the *singer input* side: a mic sample captured at
///   time `t` was sung against audio the singer heard `latencyOffsetMs`
///   earlier, so the offset is subtracted here and only here.
///
/// Lookup queries assume phrases and notes are sorted by start beat within
/// each voice. The parser emits them in chart order, which well-formed charts
/// keep ascending; this invariant is what makes binary search valid.
public struct SongClock: Sendable {
    /// The song whose chart defines the beat grid.
    public let song: Song
    /// Round-trip audio latency in milliseconds, measured by the calibration
    /// wizard, compensated on singer-input times only.
    public var latencyOffsetMs: Double

    /// Creates a clock for a song.
    public init(song: Song, latencyOffsetMs: Double = 0) {
        self.song = song
        self.latencyOffsetMs = latencyOffsetMs
    }

    // MARK: Time ↔ beat

    /// The playback time at which `beat` occurs (see `Song.seconds(fromBeat:)`
    /// for the quarter-beat formula).
    public func time(atBeat beat: Double) -> TimeInterval {
        song.seconds(fromBeat: beat)
    }

    /// The chart beat playing at playback time `time`. Inverse of
    /// ``time(atBeat:)``; no latency compensation is applied.
    public func currentBeat(at time: TimeInterval) -> Double {
        (time - song.gapMs / 1000) * song.bpm * 4 / 60
    }

    /// The chart beat a singer-input sample captured at `time` was sung
    /// against, compensating for the calibrated latency offset.
    public func inputBeat(at time: TimeInterval) -> Double {
        currentBeat(at: time - latencyOffsetMs / 1000)
    }

    // MARK: Chart lookup

    /// The phrase containing `beat` in the given voice, or nil when the beat
    /// falls between phrases or the voice does not exist. Beat ranges are
    /// half-open: a phrase's `endBeat` belongs to no note of that phrase.
    public func phrase(atBeat beat: Double, inVoice voiceIndex: Int) -> Phrase? {
        guard song.voices.indices.contains(voiceIndex) else { return nil }
        let phrases = song.voices[voiceIndex].phrases
        guard let index = lastIndex(startingAtOrBefore: beat, count: phrases.count, startBeat: { phrases[$0].startBeat }),
              beat < Double(phrases[index].endBeat) else {
            return nil
        }
        return phrases[index]
    }

    /// The note sounding at `beat` in the given voice, or nil when the beat
    /// falls in a rest, between phrases, or the voice does not exist.
    public func note(atBeat beat: Double, inVoice voiceIndex: Int) -> Note? {
        guard let phrase = phrase(atBeat: beat, inVoice: voiceIndex) else { return nil }
        let notes = phrase.notes
        guard let index = lastIndex(startingAtOrBefore: beat, count: notes.count, startBeat: { notes[$0].startBeat }),
              beat < Double(notes[index].endBeat) else {
            return nil
        }
        return notes[index]
    }

    /// Binary search: index of the last element whose start beat is <= `beat`.
    private func lastIndex(startingAtOrBefore beat: Double, count: Int, startBeat: (Int) -> Int) -> Int? {
        var low = 0
        var high = count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if Double(startBeat(mid)) <= beat {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
