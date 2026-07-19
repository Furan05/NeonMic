# App

Xcode project created manually here (macOS App, SwiftUI, name: NeonMic). Depends on the local NeonMicKit package.

## Sources to add to the app target

The project is not checked in, so when (re)creating it, add these files to the
app target (or point an Xcode 16 synchronized folder at `App/`):

- `NeonMicApp.swift` — `@main` entry + debug navigation (picker ↔ gameplay).
- `NeonMicDesign.swift` — the 8 "Midnight Karaoke Box" color tokens, neon glow, grain, LED counter, neon buttons.
- `Game/GameCoordinator.swift` — run-loop wiring: chart → clock → player → mic → pitch tracker → scoring session.
- `Game/GameplayView.swift` — the playable screen (highway, comet, lyrics, HUD, stamps, pause).
- `Game/DebugSongPicker.swift` — temporary launcher until the Songbook exists.

If you delete Xcode's generated `ContentView.swift`/app file, this folder's
`NeonMicApp.swift` is the entry point.

## Target settings the feature needs

- **NSMicrophoneUsageDescription** in Info: e.g. "NEON MIC listens to your singing to score your pitch."
- **App Sandbox** (if enabled): Audio Input + User Selected File (read) entitlements.
- Link the local `NeonMicKit` package (File → Add Package Dependencies → Add Local…).
- macOS deployment target 14.0.
