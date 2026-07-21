import Foundation

/// Sanity-checks a generated (or fetched) chart against the video it belongs
/// to, flagging likely mismatches and sync problems.
///
/// These are *heuristics*, not proof: real sync detection would correlate the
/// audio, which NEON MIC does not decode here. The checks catch the common
/// failure modes — lyrics that clearly don't fit the video's length, an
/// implausible `#GAP`, non-monotonic timing — and hand the player a concrete
/// suggestion (usually "nudge the GAP") to fix in the preview.
public struct ChartValidator {

    /// One validation finding.
    public struct Issue: Equatable, Sendable {
        public enum Severity: Sendable { case info, warning, error }
        public var severity: Severity
        public var message: String
        public var suggestion: String?

        public init(severity: Severity, message: String, suggestion: String? = nil) {
            self.severity = severity
            self.message = message
            self.suggestion = suggestion
        }
    }

    /// The outcome of validation.
    public struct Report: Equatable, Sendable {
        public var issues: [Issue]
        /// A GAP nudge (milliseconds) the player might apply, when a shift is
        /// the likely fix. Nil when nothing concrete can be inferred.
        public var suggestedGapDeltaMs: Double?

        public init(issues: [Issue], suggestedGapDeltaMs: Double? = nil) {
            self.issues = issues
            self.suggestedGapDeltaMs = suggestedGapDeltaMs
        }

        /// Whether the chart is usable as-is (no blocking errors).
        public var isUsable: Bool { !issues.contains { $0.severity == .error } }
    }

    public init() {}

    /// Validates `song` (with its GAP/BPM) against the source video length.
    public func validate(song: Song, videoDurationSeconds: Double?) -> Report {
        let notes = song.voices.flatMap { $0.phrases.flatMap(\.notes) }
        guard let first = notes.min(by: { $0.startBeat < $1.startBeat }),
              let last = notes.max(by: { $0.endBeat < $1.endBeat }) else {
            return Report(issues: [Issue(
                severity: .error,
                message: "Le chart ne contient aucune note.",
                suggestion: "Vérifie que des paroles synchronisées ont bien été trouvées.")])
        }

        var issues: [Issue] = []
        var suggestedGapDeltaMs: Double?

        let firstSeconds = song.seconds(fromBeat: Double(first.startBeat))
        let lastSeconds = song.seconds(fromBeat: Double(last.endBeat))

        // Monotonic timing per voice.
        for voice in song.voices {
            let starts = voice.phrases.flatMap(\.notes).map(\.startBeat)
            if zip(starts, starts.dropFirst()).contains(where: { $0 > $1 }) {
                issues.append(Issue(
                    severity: .warning,
                    message: "Des notes sont dans le désordre — le timing peut sauter."))
                break
            }
        }

        // GAP plausibility.
        if song.gapMs < 0 {
            issues.append(Issue(severity: .info, message: "Le GAP est négatif (les paroles précèdent l'audio)."))
        }
        if firstSeconds > 20 {
            issues.append(Issue(
                severity: .info,
                message: "Long silence avant la première parole (\(Int(firstSeconds)) s).",
                suggestion: "Si c'est faux, réduis le GAP dans la prévisualisation."))
        }

        // Lyrics-vs-video length: the strongest mismatch signal we have.
        if let duration = videoDurationSeconds, duration > 1 {
            if lastSeconds > duration + 5 {
                let overshoot = Int(lastSeconds - duration)
                issues.append(Issue(
                    severity: .warning,
                    message: "Les paroles dépassent la vidéo de ~\(overshoot) s.",
                    suggestion: "Les paroles ne correspondent peut-être pas à cette vidéo."))
            } else if lastSeconds < duration * 0.4 {
                issues.append(Issue(
                    severity: .warning,
                    message: "Les paroles sont bien plus courtes que la vidéo.",
                    suggestion: "Vérifie que les paroles correspondent à cette version."))
            }

            // Sync-offset hint: a large, isolated leading silence relative to a
            // reasonable lyric span suggests a constant offset the GAP can fix.
            let span = lastSeconds - firstSeconds
            if firstSeconds > 8, span > 0, firstSeconds > duration * 0.35, span < duration * 0.9 {
                suggestedGapDeltaMs = -min(firstSeconds - 2, 10) * 1000
                issues.append(Issue(
                    severity: .info,
                    message: "Décalage de synchro possible (~\(Int(firstSeconds)) s de retard).",
                    suggestion: "Applique le calage suggéré, puis affine à l'oreille."))
            }
        }

        return Report(issues: issues, suggestedGapDeltaMs: suggestedGapDeltaMs)
    }
}
