import Foundation

/// Parses UltraStar `.txt` chart files into ``Song`` models.
///
/// The parser is tolerant by design: malformed individual lines are skipped
/// and reported as ``ParseWarning`` values, while structural problems —
/// missing `#TITLE`, `#ARTIST`, or `#BPM`, or a chart with no notes at all —
/// throw ``UltraStarParseError``.
///
/// Charts using `RELATIVE:YES` timing are converted to absolute beats during
/// parsing, so the models never carry relative timing.
public enum UltraStarParser {

    // MARK: Public API

    /// Parses chart text, discarding any warnings.
    public static func parse(_ text: String) throws -> Song {
        try parseCollectingWarnings(text).song
    }

    /// Reads and parses a chart file, discarding any warnings.
    public static func parse(fileAt url: URL) throws -> Song {
        try parseCollectingWarnings(fileAt: url).song
    }

    /// Reads and parses a chart file, returning non-fatal problems alongside
    /// the song.
    ///
    /// The file is decoded as UTF-8 first (a leading byte-order mark is
    /// stripped), falling back to Windows-1252 and then ISO Latin-1, which
    /// many older community files use. Both LF and CRLF line endings are
    /// accepted.
    public static func parseCollectingWarnings(fileAt url: URL) throws -> (song: Song, warnings: [ParseWarning]) {
        try parseCollectingWarnings(decode(try Data(contentsOf: url)))
    }

    /// Parses chart text, returning non-fatal problems alongside the song.
    public static func parseCollectingWarnings(_ text: String) throws -> (song: Song, warnings: [ParseWarning]) {
        var text = text
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }

        var warnings: [ParseWarning] = []

        var title: String?
        var artist: String?
        var bpmHeader: (lineNumber: Int, value: String)?
        var gapMs: Double = 0
        var mp3: String?
        var audio: String?
        var cover: String?
        var video: String?
        var background: String?
        var language: String?
        var genre: String?
        var year: Int?
        var isRelative = false
        var rawHeaders: [String: String] = [:]

        var phrasesByVoice: [[Phrase]] = [[]]
        var currentVoice = 0
        var currentNotes: [Note] = []
        var relativeOffset = 0

        func endPhrase() {
            guard !currentNotes.isEmpty else { return }
            phrasesByVoice[currentVoice].append(Phrase(notes: currentNotes))
            currentNotes = []
        }

        // Split on any newline Character: in Swift, CRLF is a single grapheme
        // cluster, so splitting on "\n" alone would never match CRLF files.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        lineLoop: for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            var line = rawLine
            if line.hasSuffix("\r") {
                line = line.dropLast()
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            // Leading indentation is never meaningful; trailing spaces are
            // (they belong to note text), so only the left side is trimmed.
            let content = line.drop(while: { $0 == " " || $0 == "\t" })

            func warn(_ message: String) {
                warnings.append(ParseWarning(lineNumber: lineNumber, lineContent: String(line), message: message))
            }

            switch content.first! {
            case "#":
                let body = content.dropFirst()
                guard let colon = body.firstIndex(of: ":") else {
                    warn("header line is missing ':'")
                    continue
                }
                let key = body[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else {
                    warn("header line has an empty name")
                    continue
                }
                switch key {
                case "TITLE": title = value
                case "ARTIST": artist = value
                case "MP3": mp3 = value
                case "AUDIO": audio = value
                case "BPM": bpmHeader = (lineNumber, value)
                case "GAP":
                    if let parsed = double(from: value) {
                        gapMs = parsed
                    } else {
                        warn("invalid GAP value")
                    }
                case "COVER": cover = value
                case "VIDEO": video = value
                case "BACKGROUND": background = value
                case "LANGUAGE": language = value
                case "GENRE": genre = value
                case "YEAR":
                    if let parsed = Int(value) {
                        year = parsed
                    } else {
                        warn("invalid YEAR value")
                    }
                case "RELATIVE": isRelative = value.uppercased() == "YES"
                default: rawHeaders[key] = value
                }

            case ":", "*", "F", "R", "G":
                switch parseNoteLine(content) {
                case .success(var note):
                    if isRelative {
                        note.startBeat += relativeOffset
                    }
                    currentNotes.append(note)
                case .failure(let failure):
                    warn(failure.message)
                }

            case "-":
                endPhrase()
                let tokens = trimmed.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" })
                let beats = tokens.compactMap { Int($0) }
                if beats.count != tokens.count {
                    warn("line break has non-numeric beat values")
                }
                if isRelative {
                    // In relative mode `- a b` advances the beat reference by
                    // b; a single-number break advances by that number.
                    if let advance = beats.count >= 2 ? beats[1] : beats.first {
                        relativeOffset += advance
                    } else {
                        warn("relative line break is missing its beat value")
                    }
                }

            case "P", "p":
                guard let number = Int(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)), number >= 1 else {
                    warn("invalid voice marker")
                    continue
                }
                endPhrase()
                while phrasesByVoice.count < number {
                    phrasesByVoice.append([])
                }
                currentVoice = number - 1
                // Relative timing restarts from zero for each voice's section.
                relativeOffset = 0

            case "E":
                if trimmed == "E" {
                    break lineLoop
                }
                warn("unrecognized line")

            default:
                warn("unrecognized line")
            }
        }
        endPhrase()

        guard let title, !title.isEmpty else {
            throw UltraStarParseError.missingRequiredHeader("TITLE")
        }
        guard let artist, !artist.isEmpty else {
            throw UltraStarParseError.missingRequiredHeader("ARTIST")
        }
        guard let bpmHeader else {
            throw UltraStarParseError.missingRequiredHeader("BPM")
        }
        guard let bpm = double(from: bpmHeader.value), bpm > 0 else {
            throw UltraStarParseError.invalidBPM(lineNumber: bpmHeader.lineNumber, value: bpmHeader.value)
        }
        guard phrasesByVoice.contains(where: { !$0.isEmpty }) else {
            throw UltraStarParseError.noNotes
        }

        let song = Song(
            title: title,
            artist: artist,
            bpm: bpm,
            gapMs: gapMs,
            audioFileName: audio ?? mp3,
            coverFileName: cover,
            videoFileName: video,
            backgroundFileName: background,
            language: language,
            genre: genre,
            year: year,
            isRelative: isRelative,
            voices: phrasesByVoice.map(Voice.init),
            rawHeaders: rawHeaders
        )
        return (song, warnings)
    }

    // MARK: Line parsing

    private struct NoteLineFailure: Error {
        let message: String
    }

    private static func parseNoteLine(_ line: Substring) -> Result<Note, NoteLineFailure> {
        var index = line.startIndex
        guard index < line.endIndex, let type = NoteType(rawValue: line[index]) else {
            return .failure(NoteLineFailure(message: "unknown note type"))
        }
        index = line.index(after: index)

        func nextInteger() -> Int? {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
            let start = index
            while index < line.endIndex, line[index] != " ", line[index] != "\t" {
                index = line.index(after: index)
            }
            guard start < index else { return nil }
            return Int(line[start..<index])
        }

        guard let startBeat = nextInteger() else {
            return .failure(NoteLineFailure(message: "malformed note line: invalid start beat"))
        }
        guard let lengthBeats = nextInteger() else {
            return .failure(NoteLineFailure(message: "malformed note line: invalid length"))
        }
        guard let pitch = nextInteger() else {
            return .failure(NoteLineFailure(message: "malformed note line: invalid pitch"))
        }

        // Exactly one space separates the pitch from the text; anything past
        // it — including further leading spaces — belongs to the syllable.
        if index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
        let text = String(line[index...])

        return .success(Note(startBeat: startBeat, lengthBeats: lengthBeats, pitch: pitch, text: text, type: type))
    }

    // MARK: Helpers

    private static func decode(_ data: Data) throws -> String {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
        }
        for encoding in [String.Encoding.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw UltraStarParseError.undecodableData
    }

    /// Parses a chart number, accepting the decimal comma ("285,5") that many
    /// community files use.
    private static func double(from value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: "."))
    }
}
