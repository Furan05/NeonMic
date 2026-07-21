import Foundation

/// Parses LRC lyric files into an ``LRCDocument``.
///
/// Handles standard line-synced LRC (`[mm:ss.xx] text`), multiple time tags
/// per line, ID metadata tags (`[ti:]`, `[ar:]`, `[offset:]`…), and "enhanced"
/// word-synced LRC with inline `<mm:ss.xx>` word tags. Unparseable lines are
/// skipped, never fatal.
public enum LRCParser {

    /// Parses LRC text into a time-sorted document.
    public static func parse(_ text: String) -> LRCDocument {
        var metadata: [String: String] = [:]
        var pending: [(time: TimeInterval, text: String, words: [TimedWord]?)] = []

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            if rest.hasSuffix("\r") { rest = rest.dropLast() }

            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTime(inner) {
                    times.append(time)
                } else if let colon = inner.firstIndex(of: ":") {
                    let key = inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { metadata[key] = value }
                }
                rest = rest[rest.index(after: close)...]
            }

            guard !times.isEmpty else { continue }
            let (plain, words) = parseWordTags(rest)
            for time in times {
                pending.append((time, plain, words))
            }
        }

        // Apply the ID `offset` (milliseconds) to every timestamp.
        let offsetSeconds = (metadata["offset"].flatMap { Double($0) } ?? 0) / 1000
        var lines: [LRCLine] = []
        lines.reserveCapacity(pending.count)
        for entry in pending {
            var shiftedWords: [TimedWord]?
            if let words = entry.words {
                shiftedWords = words.map { TimedWord(time: max(0, $0.time + offsetSeconds), text: $0.text) }
            }
            lines.append(LRCLine(
                time: max(0, entry.time + offsetSeconds),
                text: entry.text,
                words: shiftedWords))
        }
        lines.sort { $0.time < $1.time }

        return LRCDocument(metadata: metadata, lines: lines, raw: text)
    }

    // MARK: Helpers

    /// Parses `mm:ss`, `mm:ss.xx(x)`, or `hh:mm:ss(.xx)` into seconds.
    static func parseTime(_ token: Substring) -> TimeInterval? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        // Leading whole units (hours, minutes) must be integers.
        for part in parts.dropLast() {
            guard let value = Int(part) else { return nil }
            seconds = seconds * 60 + Double(value)
        }
        seconds *= 60
        guard let last = Double(parts[parts.count - 1]) else { return nil }
        return seconds + last
    }

    /// Splits an enhanced-LRC line into plain text plus any `<t>`-tagged words.
    static func parseWordTags(_ text: Substring) -> (String, [TimedWord]?) {
        guard text.contains("<") else { return (String(text), nil) }
        var plain = ""
        var words: [TimedWord] = []
        var pendingTime: TimeInterval?
        var pendingText = ""
        var index = text.startIndex

        func flush() {
            if let time = pendingTime {
                words.append(TimedWord(time: time, text: pendingText))
            }
            pendingText = ""
        }

        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">"),
               let time = parseTime(text[text.index(after: index)..<close]) {
                flush()
                pendingTime = time
                index = text.index(after: close)
                continue
            }
            plain.append(text[index])
            pendingText.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return (plain, words.isEmpty ? nil : words)
    }
}
