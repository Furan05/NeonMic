import Foundation

/// Converts synchronized LRC lyrics into an UltraStar `.txt` chart.
///
/// LRC carries timing but no pitch, so the converter lays syllables on a fine
/// beat grid (BPM chosen by heuristic), derives `#GAP` from the first timestamp,
/// and synthesizes a gentle placeholder melody. The result is a *playable
/// starting point* meant to be pitch-edited, not a faithful transcription —
/// the chart is stamped as auto-generated so nobody mistakes it for one.
///
/// UltraStar's `#BPM` counts quarter-beats: one beat lasts `60/(BPM*4) = 15/BPM`
/// seconds, exactly ``Song/seconds(fromBeat:)``. The converter targets that
/// same relation so a round-trip through ``UltraStarParser`` reproduces the LRC
/// timings to within one beat.
public struct LRCtoUltraStarConverter {

    /// Tuning knobs for the conversion.
    public struct Options: Sendable {
        /// Lowest BPM the heuristic may pick.
        public var minBPM: Double
        /// Highest BPM the heuristic may pick.
        public var maxBPM: Double
        /// Baseline pitch the placeholder melody sits on.
        public var basePitch: Int
        /// Per-line pitch contour added to `basePitch`, cycled across syllables.
        public var pitchPattern: [Int]
        /// Extra silence kept before the first note (shifts `#GAP` earlier).
        public var leadInSeconds: Double
        /// Assumed length of the final line, which has no following timestamp.
        public var lastLineDuration: Double
        /// Cap on a single note's length, so a note never spans an instrumental.
        public var maxNoteSeconds: Double

        public init(
            minBPM: Double = 180,
            maxBPM: Double = 600,
            basePitch: Int = 0,
            pitchPattern: [Int] = [0, 2, 4, 5, 4, 2],
            leadInSeconds: Double = 0,
            lastLineDuration: Double = 2.0,
            maxNoteSeconds: Double = 2.5
        ) {
            self.minBPM = minBPM
            self.maxBPM = maxBPM
            self.basePitch = basePitch
            self.pitchPattern = pitchPattern.isEmpty ? [0] : pitchPattern
            self.leadInSeconds = leadInSeconds
            self.lastLineDuration = lastLineDuration
            self.maxNoteSeconds = maxNoteSeconds
        }
    }

    /// The media/tag fields to stamp into the generated chart header.
    public struct ChartMetadata: Sendable {
        public var title: String
        public var artist: String
        public var audioFileName: String?
        public var videoFileName: String?
        public var coverFileName: String?
        public var language: String?
        public var genre: String?
        public var year: Int?

        public init(
            title: String, artist: String,
            audioFileName: String? = nil, videoFileName: String? = nil, coverFileName: String? = nil,
            language: String? = nil, genre: String? = nil, year: Int? = nil
        ) {
            self.title = title
            self.artist = artist
            self.audioFileName = audioFileName
            self.videoFileName = videoFileName
            self.coverFileName = coverFileName
            self.language = language
            self.genre = genre
            self.year = year
        }
    }

    /// The generated chart plus the figures behind it.
    public struct ConversionResult: Sendable {
        public var chartText: String
        public var bpm: Double
        public var gapMs: Double
        public var noteCount: Int
        public var lineCount: Int
        /// Always true here — LRC has no pitch, so pitches are placeholders.
        public var generatedPitches: Bool
        public var warnings: [String]
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Conversion

    /// Converts `document` into an UltraStar chart, or throws
    /// ``LyricsError/emptyLyrics`` when there is nothing timed to place.
    public func convert(_ document: LRCDocument, metadata: ChartMetadata) throws -> ConversionResult {
        let events = Self.syllableEvents(from: document, lastLineDuration: options.lastLineDuration)
        guard !events.isEmpty else { throw LyricsError.emptyLyrics }

        var warnings: [String] = []
        warnings.append("Pitches générés automatiquement — à ajuster à l'oreille.")
        if !document.isWordSynced {
            warnings.append("Timing réparti par mot (LRC ligne par ligne) — la synchro fine peut demander des retouches.")
        }

        let bpm = Self.heuristicBPM(events.map(\.time), minBPM: options.minBPM, maxBPM: options.maxBPM)
        let secondsPerBeat = 15.0 / bpm

        let firstTime = events[0].time
        let gapMs = (max(0, firstTime - options.leadInSeconds) * 1000).rounded()
        let gapSeconds = gapMs / 1000

        let beats = Self.beats(for: events, gapSeconds: gapSeconds, secondsPerBeat: secondsPerBeat)
        let lengths = Self.lengths(
            for: events, beats: beats, secondsPerBeat: secondsPerBeat,
            lastLineDuration: options.lastLineDuration, maxNoteSeconds: options.maxNoteSeconds)

        let body = renderBody(events: events, beats: beats, lengths: lengths)
        let header = renderHeader(metadata: metadata, bpm: bpm, gapMs: gapMs)

        return ConversionResult(
            chartText: header + body,
            bpm: bpm,
            gapMs: gapMs,
            noteCount: events.count,
            lineCount: (events.last?.lineIndex ?? -1) + 1,
            generatedPitches: true,
            warnings: warnings)
    }

    /// Builds a rough LRC document from unsynchronized plain-text lyrics by
    /// spreading lines evenly across the (known or estimated) duration.
    ///
    /// A last-resort fallback so a song can still be started; the result needs
    /// hand-syncing and is flagged as such by ``ChartValidator``.
    public static func syntheticDocument(fromPlain text: String, durationSeconds: Double?) -> LRCDocument {
        let rawLines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { return LRCDocument(lines: []) }

        let total = durationSeconds ?? Double(rawLines.count) * 3
        let lead = min(8, total * 0.06)
        let tail = min(8, total * 0.06)
        let span = max(Double(rawLines.count), total - lead - tail)
        let step = span / Double(rawLines.count)

        var lines: [LRCLine] = []
        for (index, text) in rawLines.enumerated() {
            lines.append(LRCLine(time: lead + Double(index) * step, text: text))
        }
        return LRCDocument(lines: lines, raw: text)
    }

    // MARK: Event model

    struct SyllableEvent: Equatable {
        var time: Double
        var text: String
        var lineIndex: Int
        var indexInLine: Int
        var isLastInLine: Bool
    }

    /// Flattens LRC lines into per-syllable events. Word-synced lines use their
    /// word timings; line-synced lines spread words evenly to the next line.
    static func syllableEvents(from document: LRCDocument, lastLineDuration: Double) -> [SyllableEvent] {
        let lines = document.lines
        var events: [SyllableEvent] = []
        for index in lines.indices {
            let line = lines[index]
            let lineEnd = index + 1 < lines.count ? lines[index + 1].time : line.time + lastLineDuration
            let lineDuration = max(0.2, lineEnd - line.time)

            // (time, text) pairs for this line's syllables.
            var pieces: [(Double, String)] = []
            let timedWords = line.words ?? []
            if timedWords.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                for word in timedWords {
                    let text = word.text.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { pieces.append((word.time, text)) }
                }
            } else {
                var words: [String] = []
                for token in line.text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    words.append(String(token))
                }
                let step = words.isEmpty ? 0 : lineDuration / Double(words.count)
                for wordIndex in words.indices {
                    pieces.append((line.time + Double(wordIndex) * step, words[wordIndex]))
                }
            }

            guard !pieces.isEmpty else { continue }
            for offset in pieces.indices {
                events.append(SyllableEvent(
                    time: pieces[offset].0, text: pieces[offset].1,
                    lineIndex: index, indexInLine: offset, isLastInLine: offset == pieces.count - 1))
            }
        }
        return events
    }

    // MARK: Heuristics

    /// Picks a `#BPM` so a short syllable spans ~2 beats, clamped to range.
    ///
    /// Uses the 15th-percentile inter-onset gap as "a short syllable"; a finer
    /// grid (higher BPM) only ever improves quantization accuracy.
    static func heuristicBPM(_ times: [Double], minBPM: Double, maxBPM: Double) -> Double {
        let sorted = times.sorted()
        var gaps: [Double] = []
        for index in 1..<max(1, sorted.count) where sorted[index] - sorted[index - 1] > 0.03 {
            gaps.append(sorted[index] - sorted[index - 1])
        }
        let unit: Double
        if gaps.isEmpty {
            unit = 0.35
        } else {
            let ordered = gaps.sorted()
            unit = ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.15))]
        }
        // secondsPerBeat = unit/2  ⇒  BPM = 15 / (unit/2) = 30/unit.
        let raw = 30.0 / unit
        let rounded = (raw / 2).rounded() * 2
        return min(max(rounded, minBPM), maxBPM)
    }

    /// Quantizes event times to strictly increasing beats.
    static func beats(for events: [SyllableEvent], gapSeconds: Double, secondsPerBeat: Double) -> [Int] {
        var beats: [Int] = []
        var last = -1
        for event in events {
            var beat = Int(((event.time - gapSeconds) / secondsPerBeat).rounded())
            if beat <= last { beat = last + 1 }
            beats.append(beat)
            last = beat
        }
        return beats
    }

    /// Note lengths: contiguous up to the next syllable, capped so nothing
    /// stretches across a gap.
    static func lengths(
        for events: [SyllableEvent], beats: [Int], secondsPerBeat: Double,
        lastLineDuration: Double, maxNoteSeconds: Double
    ) -> [Int] {
        let maxLen = max(1, Int((maxNoteSeconds / secondsPerBeat).rounded()))
        let tailLen = max(1, Int((lastLineDuration / secondsPerBeat).rounded()))
        var lengths: [Int] = []
        for index in beats.indices {
            let next = index + 1 < beats.count ? beats[index + 1] : beats[index] + tailLen
            lengths.append(min(max(1, next - beats[index]), maxLen))
        }
        return lengths
    }

    // MARK: Rendering

    private func renderBody(events: [SyllableEvent], beats: [Int], lengths: [Int]) -> String {
        let pattern = options.pitchPattern
        var body = ""
        var index = 0
        while index < events.count {
            let line = events[index].lineIndex
            var cursor = index
            while cursor < events.count && events[cursor].lineIndex == line {
                let event = events[cursor]
                let pitch = options.basePitch + pattern[event.indexInLine % pattern.count]
                let text = event.isLastInLine ? event.text : event.text + " "
                body += ": \(beats[cursor]) \(lengths[cursor]) \(pitch) \(text)\n"
                cursor += 1
            }
            if cursor < events.count {
                body += "- \(beats[cursor])\n" // break at the next line's first beat
            }
            index = cursor
        }
        body += "E\n"
        return body
    }

    private func renderHeader(metadata: ChartMetadata, bpm: Double, gapMs: Double) -> String {
        var header = ""
        header += "#TITLE:\(metadata.title)\n"
        header += "#ARTIST:\(metadata.artist)\n"
        if let audio = metadata.audioFileName { header += "#AUDIO:\(audio)\n" }
        if let video = metadata.videoFileName { header += "#VIDEO:\(video)\n" }
        if let cover = metadata.coverFileName { header += "#COVER:\(cover)\n" }
        if let language = metadata.language { header += "#LANGUAGE:\(language)\n" }
        if let genre = metadata.genre { header += "#GENRE:\(genre)\n" }
        if let year = metadata.year { header += "#YEAR:\(year)\n" }
        header += "#BPM:\(Self.formatNumber(bpm))\n"
        header += "#GAP:\(Int(gapMs))\n"
        header += "#CREATOR:NEON MIC\n"
        header += "#COMMENT:Auto-généré depuis LRC — pitches indicatifs, à ajuster.\n"
        return header
    }

    /// Formats a BPM without a needless ".0".
    static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
