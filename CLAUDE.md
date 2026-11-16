# Kerf

A Dynamic Island for the MacBook notch, for macOS 26. Open source, built and installed with `scripts/install.sh`.

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
- Kerf has no server of its own and talks to nothing personal: only Open-Meteo for the weather, and the user's own tools (Claude Code, `gh`, and `git` in the clone it was installed from, to look for updates). Keep it that way.
- Check UI changes with the lab: `Kerf --lab shot <scene> <file.png>`.

## Patch notes: in every pull request

Other people build Kerf too, so everyone sees what's new: after an update Kerf shows the notes you haven't seen, and it offers an update as soon as `main` has a note the installed build lacks. A change without a note reaches nobody.

- **Every change that reaches `main` (a pull request, or a commit pushed straight to it) and changes what someone using Kerf sees or can do adds one note**: `WhatsNew/<yyyy-mm-dd>-<a-few-words>.json`, the format in `WhatsNew/README.md`. English and Dutch, one or two short sentences about what changes for them (not how it's built), `by` your GitHub login. A fix counts too.
- Working with an AI agent: write the note before you commit or open the pull request, without being asked. If you're about to open one without a note, stop and add it.
- Nothing anyone notices (a refactor, tests, docs, the lab): no note, and tick that box in the pull request.
- The Patch note check (`.github/workflows/patch-note.yml`) fails a pull request that changes `Kerf/` or `KerfKit/Sources/` without a note, or whose note misses English, Dutch or `by`.
- One file per change, and never edit someone else's note: two pull requests can't collide.

## Build, test, release

```bash
xcodebuild -project Kerf.xcodeproj -scheme Kerf -configuration Debug build
cd KerfKit && swift test
scripts/install.sh             # Release build into /Applications (or ~/Applications); it remembers this clone for updates
scripts/release.sh --publish   # after raising MARKETING_VERSION
```
