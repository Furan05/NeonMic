# NEON MIC

## Project

NEON MIC is a karaoke game for macOS inspired by classic console karaoke games. The player sings into the mic, real-time pitch detection (YIN) analyzes their voice, and performance is scored against UltraStar-format charts. Built with SwiftUI + AVAudioEngine, targeting macOS 14+.

## Architecture

Engine logic (parsing, audio analysis, scoring, models) goes in `NeonMicKit/` with unit tests; SwiftUI views and app lifecycle go in `App/`. Never put UI code in the Kit.

## Design system — "Midnight Karaoke Box"

8 color tokens:

| Token | Hex |
|---|---|
| ink | `#0A0A12` |
| inkDeep | `#050508` |
| roomGlow | `#16121F` |
| neonPink | `#FF3B81` |
| electricCyan | `#2EE6D6` |
| signalYellow | `#FFD23F` |
| ultraViolet | `#7B5CFF` |
| paper | `#F4F1EA` |

Tokens live in `App/` as `NeonMicDesign.swift`; the visual reference is `design/reference/`. Never introduce colors outside these tokens.

## Commands

- `cd NeonMicKit && swift build`
- `cd NeonMicKit && swift test`

Always run tests after changes to the Kit.

## Conventions

- Swift API Design Guidelines, English identifiers, doc comments on public APIs.
- Text charts from the UltraStar community are user-provided content: never commit copyrighted song files to the repo; use original fixture files for tests.
