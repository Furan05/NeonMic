import SwiftUI
import NeonMicKit

/// The playable screen: karaoke corridor, pitch highway, lyrics, HUD.
///
/// Dumb by design — every frame reads ``GameCoordinator/highwayFrame()`` and
/// ``GameCoordinator/snapshot()`` (both keyed to the player's sample clock)
/// and draws what it is given. No game state, no geometry, no `Date()` lives
/// here.
struct GameplayView: View {
    let coordinator: GameCoordinator
    /// Called after the run is torn down when the player exits.
    let onExit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            NeonMicDesign.ink.ignoresSafeArea()

            TimelineView(.animation(minimumInterval: nil, paused: coordinator.isPaused || coordinator.isFinished)) { _ in
                GameplayFrame(coordinator: coordinator)
            }

            if coordinator.isPaused {
                PauseOverlay(
                    song: coordinator.song,
                    progress: progress,
                    onResume: { coordinator.resume() },
                    onRestart: { coordinator.restart() },
                    onExit: exit
                )
            }

            if coordinator.isFinished {
                FinishedOverlay(
                    snapshot: coordinator.snapshot(),
                    onRestart: { coordinator.restart() },
                    onExit: exit
                )
            }

            GrainOverlay()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) { togglePause() }
        .onKeyPress(.escape) { togglePause() }
        .onAppear { isFocused = true }
        .onChange(of: coordinator.isPaused) { isFocused = true }
    }

    private var progress: Double {
        coordinator.duration > 0 ? coordinator.currentTime / coordinator.duration : 0
    }

    private func togglePause() -> KeyPress.Result {
        guard !coordinator.isFinished else { return .ignored }
        coordinator.isPaused ? coordinator.resume() : coordinator.pause()
        return .handled
    }

    private func exit() {
        coordinator.stop()
        onExit()
    }
}

// MARK: - One rendered frame

/// Everything that changes every display frame, re-read from the coordinator
/// inside the TimelineView.
private struct GameplayFrame: View {
    let coordinator: GameCoordinator

    var body: some View {
        let time = coordinator.currentTime
        let frame = coordinator.highwayFrame()
        let snapshot = coordinator.snapshot()

        GeometryReader { geo in
            ZStack {
                CorridorBackground(time: time)

                VStack(spacing: 0) {
                    topBar(snapshot: snapshot)
                        .frame(height: geo.size.height / 3, alignment: .top)

                    HighwayCanvas(
                        frame: frame,
                        trail: coordinator.cometTrail,
                        head: coordinator.latestReading
                    )
                    .frame(height: geo.size.height / 3)
                    .padding(.horizontal, 24)

                    LyricsPanel(current: frame.currentLine, next: frame.nextLine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let stamp = coordinator.phraseStamp(for: snapshot) {
                    PhraseStampView(stamp: stamp)
                        .offset(y: -geo.size.height * 0.06)
                }

                if let message = coordinator.statusMessage {
                    Text(message)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(16)
                }
            }
        }
    }

    private func topBar(snapshot: GameSnapshot) -> some View {
        HStack(alignment: .top) {
            SongCard(
                title: coordinator.song.title,
                artist: coordinator.song.artist,
                progress: coordinator.duration > 0 ? coordinator.currentTime / coordinator.duration : 0
            )
            Spacer()
            VStack(alignment: .trailing, spacing: 12) {
                LEDCounter(value: snapshot.score)
                ComboRing(combo: snapshot.combo)
            }
        }
        .padding(24)
    }
}

// MARK: - Corridor background

/// The "karaoke corridor": concentric ultraViolet outlines over an inkDeep
/// vignette, breathing slowly on the song clock. Cheap on purpose.
private struct CorridorBackground: View {
    let time: TimeInterval

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [NeonMicDesign.ink, NeonMicDesign.inkDeep],
                center: .center,
                startRadius: 100,
                endRadius: 900
            )
            ForEach(0..<3) { ring in
                RoundedRectangle(cornerRadius: 48 + CGFloat(ring) * 28)
                    .strokeBorder(
                        NeonMicDesign.ultraViolet.opacity(0.16 - 0.04 * Double(ring)),
                        lineWidth: 1.5
                    )
                    .padding(CGFloat(36 + ring * 84))
                    .scaleEffect(1 + 0.012 * sin(time * 0.5 + Double(ring) * 1.9))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Highway

/// The 12-lane pitch highway plus the comet, drawn in a single Canvas.
/// All positions come from ``HighwayFrame``; the only math here is mapping
/// normalized units to pixels.
private struct HighwayCanvas: View {
    let frame: HighwayFrame
    let trail: [CometSample]
    let head: PitchReading?

    /// A head reading older than this is "not singing" — no comet dot.
    private static let headMaxAge: TimeInterval = 0.2
    /// A silence longer than this splits the trail into separate strokes.
    private static let trailGap: TimeInterval = 0.3

    var body: some View {
        Canvas { context, size in
            let window = HighwayWindow()
            let nowX = size.width * window.lookBehind / (window.lookBehind + window.lookAhead)
            // Points per normalized unit (one unit = lookAhead seconds).
            let unit = size.width - nowX
            let laneHeight = size.height / 12
            func laneY(_ lane: Double) -> CGFloat { size.height - CGFloat(lane + 0.5) * laneHeight }

            drawLaneGuides(context, size: size, laneY: laneY)
            drawNowLine(context, size: size, nowX: nowX)
            for note in frame.notes {
                drawNote(note, context, nowX: nowX, unit: unit, laneHeight: laneHeight, laneY: laneY)
            }
            drawComet(context, window: window, nowX: nowX, unit: unit, laneY: laneY)
        }
    }

    private func drawLaneGuides(_ context: GraphicsContext, size: CGSize, laneY: (Double) -> CGFloat) {
        for lane in 0..<12 {
            let y = laneY(Double(lane))
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(NeonMicDesign.ultraViolet.opacity(0.10)), lineWidth: 1)
        }
    }

    private func drawNowLine(_ context: GraphicsContext, size: CGSize, nowX: CGFloat) {
        context.fill(
            Path(CGRect(x: nowX - 0.75, y: 0, width: 1.5, height: size.height)),
            with: .color(NeonMicDesign.paper.opacity(0.35))
        )
    }

    private func drawNote(
        _ note: HighwayNote,
        _ context: GraphicsContext,
        nowX: CGFloat,
        unit: CGFloat,
        laneHeight: CGFloat,
        laneY: (Double) -> CGFloat
    ) {
        let barHeight = laneHeight * 0.62
        let rect = CGRect(
            x: nowX + CGFloat(note.normalizedX) * unit,
            y: laneY(Double(note.laneIndex)) - barHeight / 2,
            width: max(CGFloat(note.normalizedWidth) * unit, 4),
            height: barHeight
        )
        let path = Path(roundedRect: rect, cornerRadius: barHeight / 2)
        let isGolden = note.note.type == .golden

        if note.coverage > 0 {
            // Ignited: being sung correctly right now (or already credited).
            context.drawLayer { layer in
                layer.addFilter(.shadow(
                    color: isGolden ? NeonMicDesign.signalYellow : NeonMicDesign.electricCyan,
                    radius: 5 + 7 * note.coverage
                ))
                layer.fill(path, with: .linearGradient(
                    Gradient(colors: [NeonMicDesign.electricCyan, NeonMicDesign.signalYellow]),
                    startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                ))
            }
        } else if isGolden {
            context.fill(path, with: .color(NeonMicDesign.signalYellow.opacity(0.9)))
            context.stroke(path, with: .color(NeonMicDesign.signalYellow), lineWidth: 1)
        } else {
            // Freestyle and rap carry lyrics only; render them as ghosts.
            let opacity = note.note.type.isPitchScored ? 0.85 : 0.30
            context.fill(path, with: .color(NeonMicDesign.electricCyan.opacity(opacity)))
        }
    }

    private func drawComet(
        _ context: GraphicsContext,
        window: HighwayWindow,
        nowX: CGFloat,
        unit: CGFloat,
        laneY: (Double) -> CGFloat
    ) {
        let now = frame.time

        // Fold each sample into lane space; split the polyline where the
        // octave fold wraps (B → C) or the singer went silent, so the trail
        // never slashes across the highway.
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        var previous: CometSample?
        for sample in trail {
            let lane = HighwayFrame.lanePosition(forMidiNote: sample.midiNote)
            let point = CGPoint(
                x: nowX + CGFloat((sample.time - now) / window.lookAhead) * unit,
                y: laneY(lane)
            )
            if let previous,
               abs(lane - HighwayFrame.lanePosition(forMidiNote: previous.midiNote)) > 6
                || sample.time - previous.time > Self.trailGap {
                segments.append(current)
                current = []
            }
            current.append(point)
            previous = sample
        }
        segments.append(current)

        // The tail fades with age; x is time, so a horizontal gradient up to
        // the now-line is exactly an age fade.
        let tailShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                NeonMicDesign.electricCyan.opacity(0),
                NeonMicDesign.electricCyan.opacity(0.85),
            ]),
            startPoint: CGPoint(x: nowX - unit * CGFloat(GameCoordinator.trailDuration / window.lookAhead), y: 0),
            endPoint: CGPoint(x: nowX, y: 0)
        )
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: NeonMicDesign.electricCyan, radius: 5))
            for segment in segments where segment.count > 1 {
                var path = Path()
                path.addLines(segment)
                layer.stroke(path, with: tailShading, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }

        // Bright head dot at the newest reading, only while actually singing.
        if let head, now - head.time < Self.headMaxAge {
            let center = CGPoint(
                x: nowX + CGFloat((head.time - now) / window.lookAhead) * unit,
                y: laneY(HighwayFrame.lanePosition(forMidiNote: head.midiNote))
            )
            let outer = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            let inner = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: NeonMicDesign.electricCyan, radius: 8))
                layer.fill(Path(ellipseIn: outer), with: .color(NeonMicDesign.electricCyan))
            }
            context.fill(Path(ellipseIn: inner), with: .color(NeonMicDesign.paper))
        }
    }
}

// MARK: - Lyrics

/// Current line with per-syllable karaoke wipe, next line previewed below.
private struct LyricsPanel: View {
    let current: LyricLine?
    let next: LyricLine?

    var body: some View {
        VStack(spacing: 14) {
            if let current {
                WipedLyricLine(line: current)
            }
            if let next {
                Text(next.syllables.map(\.text).joined())
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }
}

/// One lyric line: paper base with a neonPink wipe per syllable, driven by
/// ``SyllableProgress/progress`` from the frame — no timing logic here.
private struct WipedLyricLine: View {
    let line: LyricLine

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(line.syllables.enumerated()), id: \.offset) { _, syllable in
                Text(syllable.text)
                    .foregroundStyle(NeonMicDesign.paper)
                    .overlay(alignment: .leading) {
                        Text(syllable.text)
                            .foregroundStyle(NeonMicDesign.neonPink)
                            .neonGlow(NeonMicDesign.neonPink, radius: 5)
                            .mask(alignment: .leading) {
                                Rectangle().scaleEffect(x: syllable.progress, y: 1, anchor: .leading)
                            }
                            .opacity(syllable.progress > 0 ? 1 : 0)
                    }
            }
        }
        .font(.system(size: 34, weight: .bold, design: .rounded))
        .lineLimit(1)
    }
}

// MARK: - HUD pieces

/// Cassette-label song card: title, artist, thin progress strip.
struct SongCard: View {
    let title: String
    let artist: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper)
            Text(artist)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.6))
            Capsule()
                .fill(NeonMicDesign.paper.opacity(0.1))
                .frame(width: 190, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(NeonMicDesign.electricCyan)
                        .frame(width: 190 * min(max(progress, 0), 1), height: 3)
                        .neonGlow(NeonMicDesign.electricCyan, radius: 3)
                }
                .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(NeonMicDesign.roomGlow)
        )
        .overlay(alignment: .top) {
            // The cassette label's accent stripe.
            LinearGradient(
                colors: [NeonMicDesign.neonPink, NeonMicDesign.ultraViolet],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 2)
            .clipShape(Capsule())
            .padding(.horizontal, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(NeonMicDesign.paper.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Combo ring: neonPink arc that fills toward a 20-note run, ×N inside.
/// Hidden below a combo of 2.
private struct ComboRing: View {
    let combo: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(NeonMicDesign.paper.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(Double(combo) / 20, 1))
                .stroke(NeonMicDesign.neonPink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .neonGlow(NeonMicDesign.neonPink, radius: 5)
            Text("×\(combo)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(NeonMicDesign.neonPink)
        }
        .frame(width: 54, height: 54)
        .opacity(combo >= 2 ? 1 : 0)
    }
}

// MARK: - Phrase stamp

/// The verdict flash: 上手 / OK / もう一回 with the mic-drop spring
/// (scale 1 → 1.06 → 1 over ~0.6 s) then a fade — all a pure function of
/// the stamp's song-time age.
private struct PhraseStampView: View {
    let stamp: PhraseStamp

    var body: some View {
        let springPhase = min(stamp.age / 0.6, 1)
        let scale = 1 + 0.06 * sin(springPhase * .pi)
        let opacity = stamp.age < 0.6
            ? 1.0
            : max(0, 1 - (stamp.age - 0.6) / (PhraseStamp.duration - 0.6))

        Text(label)
            .font(.system(size: 46, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .neonGlow(color, radius: 14)
            .scaleEffect(scale)
            .opacity(opacity)
    }

    private var label: String {
        switch stamp.rating {
        case .great: "上手"
        case .ok: "OK"
        case .tryAgain: "もう一回"
        }
    }

    private var color: Color {
        switch stamp.rating {
        case .great: NeonMicDesign.signalYellow
        case .ok: NeonMicDesign.electricCyan
        case .tryAgain: NeonMicDesign.ultraViolet
        }
    }
}

// MARK: - Overlays

private struct PauseOverlay: View {
    let song: Song
    let progress: Double
    let onResume: () -> Void
    let onRestart: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            // Dims the frozen gameplay frame to ~25%.
            NeonMicDesign.inkDeep.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 32) {
                SongCard(title: song.title, artist: song.artist, progress: progress)
                VStack(spacing: 14) {
                    Button("Resume", action: onResume)
                        .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.electricCyan))
                    Button("Restart", action: onRestart)
                        .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.signalYellow))
                    Button("Exit", action: onExit)
                        .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.neonPink))
                }
            }
        }
    }
}

private struct FinishedOverlay: View {
    let snapshot: GameSnapshot
    let onRestart: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            NeonMicDesign.inkDeep.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 28) {
                Text("SONG COMPLETE")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                LEDCounter(value: snapshot.score)
                Text("best combo ×\(snapshot.comboBest)   stars \(snapshot.starsCaught)/\(snapshot.starsTotal)")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.6))
                VStack(spacing: 14) {
                    Button("Restart", action: onRestart)
                        .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.signalYellow))
                    Button("Exit", action: onExit)
                        .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.neonPink))
                }
            }
        }
    }
}
