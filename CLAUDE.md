# Kerf

A Dynamic Island for the MacBook notch, for macOS 26. Open source, installed through Homebrew (`brew install --cask paultje1900/tap/kerf`).

## Read first

1. `README.md`: what Kerf does, install, privacy.
2. `CLAUDE.local.md`, `PLAN.md` and `SPEC.md` if you have them: the maintainer's own notes, not in git.
3. Apple's HIG through the `apple-design` skill. Everything in the island looks exactly like Apple's own island.

## Working

- Code, comments and commit messages in English. UI text in English with Dutch translations in `Localizable.xcstrings`.
- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency. Pure logic in `KerfKit`, `nonisolated`, tested with Swift Testing.
- File-system synchronized groups: new files are picked up by themselves.
- No work in `body`, only animate what you see, measure in Release.
- No third-party packages without the maintainer's OK (the MediaRemote adapter is approved). No secrets in git.
- Kerf is the notch for coding agents first. Out of the box only Agents is on; everything else is a `Feature` (`Kerf/App/Features.swift`) switched on in Settings → Features. A new module gets a case there, starts and stops only through it (nothing runs or asks for a permission while it's off), and its page checks `IslandPage.isAvailable`.
- Kerf has no server of its own and talks to nothing personal: only Open-Meteo for the weather, and the user's own tools (Claude Code, `gh`). Keep it that way.
- Check UI changes with the lab: `Kerf --lab shot <scene> <file.png>`.

## Build, test, release

```bash
xcodebuild -project Kerf.xcodeproj -scheme Kerf -configuration Debug build
cd KerfKit && swift test
scripts/release.sh --publish   # after raising MARKETING_VERSION
```
