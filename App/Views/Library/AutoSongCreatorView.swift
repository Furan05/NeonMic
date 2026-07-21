import SwiftUI
import NeonMicKit

/// The "create a song from a YouTube URL" sheet: paste a link, preview the
/// auto-generated chart, nudge the timing, and add it to the library.
///
/// Leads with a copyright notice — everything acquired here is third-party
/// content for the player's personal use only.
struct AutoSongCreatorView: View {
    var onClose: () -> Void = {}

    @Environment(LibraryService.self) private var library
    @State private var creator = AutoSongCreator()

    var body: some View {
        @Bindable var creator = creator
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    copyrightNotice
                    urlRow(creator: creator)
                    switch creator.phase {
                    case .idle:
                        hint
                    case .analyzing:
                        busy("Analyse de la vidéo et recherche des paroles…")
                    case .ready:
                        if let plan = creator.plan { preview(plan: plan, creator: creator) }
                    case .committing:
                        committing
                    case .done:
                        doneState
                    case .failed(let message):
                        failure(message)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 540, height: 660)
        .background(NeonMicDesign.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CRÉATION AUTOMATIQUE")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(NeonMicDesign.ultraViolet)
                    .neonGlow(NeonMicDesign.ultraViolet, radius: 6)
                Text("vidéo + paroles → chanson complète")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.45))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: Copyright

    private var copyrightNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(NeonMicDesign.signalYellow)
            Text("Usage personnel uniquement. Les paroles, charts et vidéos restent la propriété de leurs ayants droit — assure-toi d'en avoir le droit et ne redistribue rien.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(NeonMicDesign.signalYellow.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NeonMicDesign.signalYellow.opacity(0.4), lineWidth: 1))
    }

    // MARK: URL

    private func urlRow(creator: AutoSongCreator) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
                TextField("Colle une URL YouTube…", text: $creator.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                    .onSubmit { Task { await creator.analyze() } }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Capsule().fill(NeonMicDesign.roomGlow))
            .overlay(Capsule().strokeBorder(NeonMicDesign.paper.opacity(0.12), lineWidth: 1))

            Button("Analyser") { Task { await creator.analyze() } }
                .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.electricCyan))
                .controlSize(.small)
                .disabled(creator.urlText.trimmingCharacters(in: .whitespaces).isEmpty || creator.isBusy)
        }
    }

    private var hint: some View {
        Text("Colle le lien d'un clip, puis lance l'analyse : NEON MIC récupère le titre, l'artiste et des paroles synchronisées, puis génère un chart jouable.")
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func busy(_ label: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(NeonMicDesign.electricCyan)
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: Preview

    private func preview(plan: AutoSongPlan, creator: AutoSongCreator) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sourceBadge(plan)
            metadataFields(creator: creator)
            chartStats(plan: plan, creator: creator)
            lyricsPreview(plan.song)
            if !plan.validation.issues.isEmpty || !plan.warnings.isEmpty {
                validation(plan)
            }
            timingAdjust(creator: creator, plan: plan)
            outputInfo
            Button {
                Task { await creator.commit(into: library) }
            } label: {
                Label("Créer et ajouter à la bibliothèque", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.neonPink))
            .disabled(library.rootURL == nil)
            if library.rootURL == nil {
                Text("Choisis d'abord un dossier de bibliothèque dans le Songbook.")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.signalYellow.opacity(0.8))
            }
        }
    }

    private func sourceBadge(_ plan: AutoSongPlan) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sourceIcon(plan.source)).font(.system(size: 11, weight: .bold))
            Text(sourceLabel(plan.source)).font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(NeonMicDesign.electricCyan)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(NeonMicDesign.electricCyan.opacity(0.12)))
        .overlay(Capsule().strokeBorder(NeonMicDesign.electricCyan.opacity(0.4), lineWidth: 1))
    }

    private func metadataFields(creator: AutoSongCreator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField("Titre", text: $creator.titleOverride)
            labeledField("Artiste", text: $creator.artistOverride)
            Button("Réanalyser avec ces infos") { Task { await creator.analyze() } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(NeonMicDesign.electricCyan)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
                .frame(width: 54, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(NeonMicDesign.roomGlow))
        }
    }

    private func chartStats(plan: AutoSongPlan, creator: AutoSongCreator) -> some View {
        HStack(spacing: 16) {
            stat("BPM", String(Int(plan.bpm)))
            stat("GAP", "\(Int(creator.adjustedGapMs)) ms")
            stat("Notes", "\(plan.song.voices.first?.phrases.reduce(0) { $0 + $1.notes.count } ?? 0)")
            stat("Lignes", "\(plan.song.voices.first?.phrases.count ?? 0)")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper)
        }
    }

    private func lyricsPreview(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("APERÇU DES PAROLES").font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(NeonMicDesign.ultraViolet.opacity(0.8))
            ForEach(Array(previewLines(song).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.75)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(NeonMicDesign.roomGlow.opacity(0.6)))
    }

    private func validation(_ plan: AutoSongPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(plan.validation.issues.enumerated()), id: \.offset) { _, issue in
                issueRow(icon: severityIcon(issue.severity), color: severityColor(issue.severity),
                         text: issue.suggestion.map { "\(issue.message) — \($0)" } ?? issue.message)
            }
            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                issueRow(icon: "info.circle", color: NeonMicDesign.paper.opacity(0.4), text: warning)
            }
        }
    }

    private func issueRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timingAdjust(creator: AutoSongCreator, plan: AutoSongPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CALAGE TIMING").font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.ultraViolet.opacity(0.8))
                Spacer()
                Text("\(creator.gapOffsetMs >= 0 ? "+" : "")\(Int(creator.gapOffsetMs)) ms")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.signalYellow)
            }
            Slider(value: $creator.gapOffsetMs, in: -3000...3000, step: 50)
                .tint(NeonMicDesign.signalYellow)
            Text("Décale toutes les paroles (négatif = plus tôt). Affine après écoute.")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
        }
    }

    private var outputInfo: some View {
        HStack(spacing: 6) {
            Image(systemName: "film").font(.system(size: 10, weight: .bold))
            Text("Sortie : vidéo MP4 jusqu'à 1080p + audio AAC 320 kbps (.m4a)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
    }

    // MARK: Commit states

    private var committing: some View {
        VStack(alignment: .leading, spacing: 10) {
            busy("Téléchargement du clip et écriture du chart…")
            NeonProgressBar(fraction: creator.commitFraction, accent: NeonMicDesign.neonPink)
                .frame(height: 6)
        }
    }

    private var doneState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(NeonMicDesign.electricCyan)
                .neonGlow(NeonMicDesign.electricCyan, radius: 8)
            Text("Chanson ajoutée à ta bibliothèque !")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper)
            HStack(spacing: 12) {
                Button("Créer une autre") { creator.reset() }
                    .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.electricCyan)).controlSize(.small)
                Button("Fermer") { onClose() }
                    .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.ultraViolet)).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(NeonMicDesign.neonPink)
                Text(message).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Réessayer") { Task { await creator.analyze() } }
                .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.signalYellow)).controlSize(.small)
        }
    }

    // MARK: Helpers

    private func previewLines(_ song: Song, limit: Int = 8) -> [String] {
        guard let phrases = song.voices.first?.phrases else { return [] }
        return phrases.prefix(limit).map { phrase in
            phrase.notes.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        }
    }

    private func sourceLabel(_ source: AutoSongPlan.Source) -> String {
        switch source {
        case .existingChart(let name): "Chart existant · \(name)"
        case .generatedFromSyncedLyrics(let name): "Paroles synchronisées · \(name)"
        case .generatedFromPlainLyrics(let name): "Paroles simples · \(name)"
        }
    }

    private func sourceIcon(_ source: AutoSongPlan.Source) -> String {
        switch source {
        case .existingChart: "doc.text.fill"
        case .generatedFromSyncedLyrics: "waveform"
        case .generatedFromPlainLyrics: "text.alignleft"
        }
    }

    private func severityIcon(_ severity: ChartValidator.Issue.Severity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func severityColor(_ severity: ChartValidator.Issue.Severity) -> Color {
        switch severity {
        case .info: NeonMicDesign.ultraViolet
        case .warning: NeonMicDesign.signalYellow
        case .error: NeonMicDesign.neonPink
        }
    }
}
