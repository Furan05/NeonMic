import SwiftUI

/// The "Midnight Karaoke Box" design system: the 8 color tokens plus the
/// shared neon building blocks (glow, grain, LED counter, neon buttons).
/// Every color drawn anywhere in the app comes from these tokens.
enum NeonMicDesign {

    // MARK: Color tokens

    /// Primary background. `#0A0A12`
    static let ink = Color(rgb: 0x0A0A12)
    /// Deepest background, for vignettes and dimming. `#050508`
    static let inkDeep = Color(rgb: 0x050508)
    /// Raised surfaces — cards, cassette labels. `#16121F`
    static let roomGlow = Color(rgb: 0x16121F)
    /// Hero accent — sung lyrics, combo, primary actions. `#FF3B81`
    static let neonPink = Color(rgb: 0xFF3B81)
    /// Live signal — notes, the pitch comet. `#2EE6D6`
    static let electricCyan = Color(rgb: 0x2EE6D6)
    /// Reward — golden notes, score, "great". `#FFD23F`
    static let signalYellow = Color(rgb: 0xFFD23F)
    /// Ambience — corridor, secondary glow. `#7B5CFF`
    static let ultraViolet = Color(rgb: 0x7B5CFF)
    /// Text and hairlines. `#F4F1EA`
    static let paper = Color(rgb: 0xF4F1EA)
}

private extension Color {
    /// A token color from its 24-bit sRGB hex value.
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Neon glow

extension View {
    /// The signature bloom: a tight bright halo inside a wider soft one.
    func neonGlow(_ color: Color, radius: CGFloat = 8) -> some View {
        shadow(color: color.opacity(0.9), radius: radius * 0.4)
            .shadow(color: color.opacity(0.5), radius: radius)
    }
}

// MARK: - Grain

/// A static film-grain wash that keeps large ink areas from reading flat.
/// Deterministic (seeded PRNG, drawn once) and cheap: one Canvas, no timers.
struct GrainOverlay: View {
    var opacity: Double = 0.05

    var body: some View {
        Canvas { context, size in
            var random = SplitMix64(seed: 0x5EED_CA55_E77E)
            let count = Int(size.width * size.height / 550)
            for _ in 0..<max(count, 1) {
                let x = random.nextUnit() * size.width
                let y = random.nextUnit() * size.height
                let side = 0.6 + random.nextUnit()
                context.fill(
                    Path(CGRect(x: x, y: y, width: side, height: side)),
                    with: .color(NeonMicDesign.paper.opacity(0.3 + 0.7 * random.nextUnit()))
                )
            }
        }
        .opacity(opacity)
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }

    /// Tiny deterministic PRNG so the grain never re-rolls between draws.
    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}

// MARK: - LED counter

/// A cassette-deck score readout: dim ghost segments with lit digits on top.
struct LEDCounter: View {
    let value: Int
    var digits: Int = 6

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(String(repeating: "8", count: digits))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.08))
            Text(formatted)
                .foregroundStyle(NeonMicDesign.signalYellow)
                .neonGlow(NeonMicDesign.signalYellow, radius: 6)
        }
        .font(.system(size: 34, weight: .bold, design: .monospaced))
        .monospacedDigit()
    }

    private var formatted: String {
        let clamped = max(0, value)
        let text = String(clamped)
        return text.count >= digits ? text : String(repeating: "0", count: digits - text.count) + text
    }
}

// MARK: - Neon button

/// A neon-tube button: paper label in an outlined capsule of the accent
/// color that brightens and blooms on hover and press.
struct NeonButtonStyle: ButtonStyle {
    var accent: Color = NeonMicDesign.neonPink

    func makeBody(configuration: Configuration) -> some View {
        NeonButtonLabel(accent: accent, configuration: configuration)
    }

    private struct NeonButtonLabel: View {
        let accent: Color
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            let lit = isHovering || configuration.isPressed
            configuration.label
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(configuration.isPressed ? accent.opacity(0.25) : NeonMicDesign.roomGlow)
                )
                .overlay(
                    Capsule().strokeBorder(accent.opacity(lit ? 1 : 0.7), lineWidth: 1.5)
                )
                .neonGlow(accent, radius: lit ? 12 : 6)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}
