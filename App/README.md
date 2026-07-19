# App

The NeonMic macOS app (SwiftUI, macOS 14+). Depends on the local NeonMicKit package.

The Xcode project is **generated** with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml` and is not committed. After cloning (`brew install xcodegen` once):

```sh
cd App && xcodegen
open NeonMic.xcodeproj
```

`project.yml` is the source of truth for target settings: the generated
`Info.plist` (mic usage description), `NeonMic.entitlements` (app sandbox,
audio input, user-selected files read-only), the local NeonMicKit package
link, and no-team local code signing — pick your team in
Signing & Capabilities if you need a real certificate; regeneration resets it.

CLI build:

```sh
xcodebuild -project App/NeonMic.xcodeproj -scheme NeonMic -destination 'platform=macOS' build
```

## Sources

- `NeonMicApp.swift` — `@main` entry + debug navigation (picker ↔ gameplay).
- `NeonMicDesign.swift` — the 8 "Midnight Karaoke Box" color tokens, neon glow, grain, LED counter, neon buttons.
- `Game/GameCoordinator.swift` — run-loop wiring: chart → clock → player → mic → pitch tracker → scoring session.
- `Game/GameplayView.swift` — the playable screen (highway, comet, lyrics, HUD, stamps, pause).
- `Game/DebugSongPicker.swift` — temporary launcher until the Songbook exists.
