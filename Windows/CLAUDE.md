# GRASP for Windows: working guide

You're the Claude Code session on Tyler's Windows PC, and you now own the Windows app. You can build, fix, commit and push it here without relaying through the Mac. The Mac session covers what can only be checked on a Mac: the Mac and iPhone apps.

## The goal

GRASP turns a student's lecture notes (an Obsidian vault) into flashcard decks. It schedules reviews with FSRS, generates visual overviews of each lecture, and syncs across devices through Supabase. The Mac and iPhone apps are complete. **Tyler chose full parity: the Windows app should do everything the Mac app does.** Build it screen by screen on top of the shared core.

## How the repo fits together

| Path | What it is | Builds on Windows? |
|---|---|---|
| `Sources/GRASPCore/` | Shared logic: database (GRDB/SQLite), import, FSRS scheduling, study actions, overviews, sync, Supabase REST client | Yes (477+ tests pass here) |
| `Sources/GRASP/` | The Mac app (SwiftUI). **Reference only.** Port its behaviour, don't edit it | No |
| `GRASPiOS/` | The iPhone app (Xcode project). Don't touch | No |
| `Sources/grasp-check/` | Command-line smoke test of the core | Yes |
| `Windows/` | **The Windows app.** Its own SwiftPM package, so SwiftCrossUI stays out of the Mac and iPhone builds | Yes |
| `scripts/windows/grasp.ps1` (+ `.cmd`) | Builds SQLite, enters the VS environment, runs swift | Yes |
| `WINDOWS.md` | Setup guide for a fresh PC | n/a |

The UI framework is [SwiftCrossUI](https://github.com/moreSwift/swift-cross-ui), pinned to a main-branch commit in `Windows/Package.swift`, using the WinUIBackend. It looks a lot like SwiftUI but it's smaller. Before you rely on an API, check it exists in `Windows/.build/checkouts/swift-cross-ui/Sources/SwiftCrossUI/Views/`.

## Commands (plain PowerShell is fine; the script enters the VS environment itself)

```powershell
scripts\windows\grasp.cmd check       # core smoke test
scripts\windows\grasp.cmd test        # full core test suite (vault tests skip off the Mac)
scripts\windows\grasp.cmd app         # build and open the Windows app
scripts\windows\grasp.cmd uia-probe   # diagnostic: which controls crash UI Automation
```

- Anything after the command is passed on to swift, e.g. `grasp.cmd test --filter Study`.
- **Test libraries:** set `GRASP_SUPPORT_DIR` to a scratch folder so experiments don't touch Tyler's real library in `%LOCALAPPDATA%\GRASP`.
- **One instance per exe name:** SwiftCrossUI redirects a second launch of the same exe name to the running window. To run a test copy next to Tyler's window, copy the exe under another name. The exe is at `Windows\.build\out\Products\Debug-windows-x86_64\GRASPWindows.exe`.
- **Closing Tyler's window:** close it normally before rebuilding, or the exe is locked. Tell him you did.

## Ground rules

1. **Branch `windows-app`.** Commit and push there. Don't merge into `main`; the Mac session merges once the Mac and iPhone are checked.
2. **Before every push:** `grasp.cmd test` passes (vault tests skipping is expected) and `grasp.cmd app` builds with no errors or warnings from GRASP code.
3. **Edit freely** in `Windows/`, `scripts/windows/`, `WINDOWS.md`, and tests.
4. **`Sources/GRASPCore/` is shared with the Mac and iPhone, which you can't build here.**
   - Platform fixes wrapped in `#if os(Windows)` / `#if canImport(...)` are fine.
   - For new shared logic, prefer adding a GRASPCore function with tests over copying Mac code into the Windows app, so the platforms can't drift. `Study.swift` and `SupabaseREST.swift` are examples.
   - Keep behaviour identical to the Mac code you port. Put `[needs Mac check]` in the commit subject so the Mac session builds the Mac and iPhone apps and switches `AppStore` over to the new function.
5. **Never edit `Sources/GRASP/` or `GRASPiOS/`.**
6. **Commit messages:** a short imperative subject and a body saying why, plus the attribution lines your harness gives you.
7. **Secrets:** the Supabase anon key in `SupabaseSettings.swift` is public by design (row-level security protects the data). Never commit a user's password, tokens or session file.
8. **Tell Tyler what you did in plain language.** He isn't reading diffs.

## Seeing the UI

- **UI Automation crashes the app.** That's Microsoft bug microsoft-ui-xaml#11028: deep automation walks of code-created controls hit a null in `Microsoft.UI.Xaml.dll`. It's reported, it's out of our hands, and it isn't worth chasing. Don't use UIA or accessibility tooling to drive or inspect the app.
- **Screenshots instead:** capture just the GRASP window with .NET `Graphics.CopyFromScreen` over its window rectangle (or `PrintWindow`), and look at the PNG.
- **Screens that need clicks:** add a temporary env-var hook for the check, e.g. `if ProcessInfo.processInfo.environment["DEMO_STUDY"] != nil { ... }`, that opens a sheet or starts a session. Screenshot it, then **remove the hook before committing.**
- **Ask Tyler to click through** anything that needs real input, such as sign-in.

## Windows gotchas already learned (don't rediscover these)

**Build and toolchain**
- Swift 6.4's build system compiles SwiftCrossUI's Linux-only Gtk targets unless `SCUI_DEFAULT_BACKEND=WinUIBackend` is set. `grasp.ps1` sets it for `app`/`uia-probe`. Do the same for any new command.
- GRDB needs SQLite, which Windows doesn't ship. `grasp.ps1` builds SQLite 3.53.4 with FTS5 and snapshots into `.build-windows\`. Always build through the script, not bare `swift`.
- ZIPFoundation doesn't build on Windows. `ZipReader` falls back to the system `tar.exe`.

**Windows API and runtime**
- WinSDK functions like `CryptProtectData` import as Swift `Bool`, not `WindowsBool`.
- There's no `setenv` on Windows.
- **File locks:** atomic writes (`write(to:atomically: true)`) and moving a file that's still open both fail with Win32 error 32 when anything, including Defender or the indexer, has the file open. Write non-atomically, and close databases before moving them.
- **Ollama:** `URLSession` doesn't fail fast on a refused connection; it waits out the whole timeout. `OllamaGenerator` probes `isAvailable` (2 s) first. Do the same for any new network call to a local server.
- **GUI launches (shortcuts, Explorer):** `grasp.ps1` links the exe as a GUI program (`/SUBSYSTEM:WINDOWS`) with the icon from `Windows\Resources\GRASP.rc`, so there's no console. With no console, SwiftCrossUI's `earlySetup()` hands the C runtime an invalid argument, which by default fail-fasts (`0xc0000409` in `ucrtbase`, offset `0x11858`) before any window appears. `Launcher.swift` is the real `@main`: it installs a no-op `_set_invalid_parameter_handler` and redirects stdout/stderr to `GRASPWindows.log` **before** SwiftCrossUI starts (`App.init()` is too late). Keep it that way.
- Test copies started from a script still work best with stdout/stderr redirected.

**SwiftCrossUI**
- `ForEach` over ranges needs `id: \.self`.
- Pass `frame` sizes as `Double`; the `Int` overloads are deprecated.
- Buttons in an `HStack` get squeezed to "…" unless you add `.fixedSize()`.
- `setSizeLimits` is unimplemented on WinUI, so window minimum and maximum sizes are ignored.
- Some modifiers (`.background`, `.cornerRadius`) exist but behave slightly differently from SwiftUI. Check each change with a screenshot.
- **Don't use `NavigationSplitView`:** on WinUI it lays the sidebar out using the pane's stale width on first layout, which clips it. The window is a plain `HStack` with a fixed-width sidebar.
- `Divider()` stretches to whatever width it's offered, so it widens any container without a fixed width.
- `GeometryReader` can be offered an infinite width while SwiftCrossUI measures. Check `isFinite` before converting a size to `Int`, or the app crashes.
- There's no grid (`LazyVGrid`); lay tiles out as rows of fixed-width views (see `HomeView.gridLayout`).
- Tap targets (`onTapGesture`) cover their whole frame, so full-width clickable rows work.

**GRASPCore data**
- `RowOperation.target`/`source` are **1-based**, as written (R₁); subtract 1 for array indices.

## The Windows app today (`Windows/Sources/GRASPWindows/`)

| File | Role |
|---|---|
| `Launcher.swift` | The real `@main`: makes GUI launches safe (see gotchas), then runs `GRASPWindowsApp` |
| `GRASPWindowsApp.swift` | The app; `ContentView` (sidebar of semesters/courses, then Home or a course), `CourseView` + `DeckColumn` (Mac-style deck column with All Cards), `DeckView` |
| `HomeView.swift` | The dashboard: wordmark, greeting, figures, course tiles |
| `Theme.swift` | The Mac's `GRASPColor` palette and type scale, `SectionLabel`, `DueBadge` |
| `Library.swift` | `@Observable` model: opens the profile's DB, semesters/courses/decks with the Mac's ordering, import (folder / sample), study actions via `Study`, row-reduction lookup. Counterpart of the Mac's `AppStore` |
| `ConsoleOutput.swift`, `WindowIcon.swift` | Windows plumbing: log file and CRT handler for GUI launches; puts the embedded icon on the window |
| `Resources/GRASP.ico`, `GRASP.rc` | The app icon (from the iPhone AppIcon, via `scripts\windows\make-icon.ps1`), embedded by `grasp.ps1` |
| `StudySessionView.swift` | Flashcards with the four FSRS grades |
| `RowReductionView.swift` | Steps through a row reduction from the notes: `MatrixGrid`, `Bracket` shape |
| `Account.swift` | Sign-in/sign-up (email + password), linking the profile, sync every 120 s and 8 s after a change, reloading on pulled changes |
| `AccountViews.swift` | Sidebar account panel and the sign-in sheet |
| `SessionVault.swift` | The session file, DPAPI-encrypted, at `Profiles\<id>\session.bin` |
| `SupabaseSettings.swift` | The Supabase project URL and anon key (same as the Mac's Info.plist) |

`Windows/Sources/UIAProbe/` is the diagnostic behind `uia-probe`. Leave it alone.

**Core APIs you'll use most:**
- Study and import: `Study` (due cards, grade, approve drafts, next exam), `VaultScanner` (`scan(vaultRoot:)`, `importPaths`)
- Overviews: `OverviewQueries`, `NoteOverview` / `OverviewDocument`, `NoteMatrices`, `MathNotation.prettify`, `OverviewFigures.label`
- Sync and accounts: `SyncEngine`, `SupabaseAuth`, `SupabaseRESTTransport`, `ProfileStore`
- Other: `FSRS`, `LearnEngine`, `TestBuilder`, `AnswerGrading`, `SampleVault`

**Mac code to port from:**
- Logic: `Sources/GRASP/Shared/AppStore.swift` (2.3k lines, the reference for every action)
- Screens: `Sources/GRASP/Views/*`, `Sources/GRASP/Shared/Study/*`, `Sources/GRASP/Shared/Overview/*`

## Open issues, in order

1. ~~Sidebar layout bug~~ **Done.** Cause: `NavigationSplitView` on WinUI (see gotchas); the window is now an `HStack`.
2. ~~Sign-in, first real test~~ **Done.** Tyler signed in with email + password and his whole library downloaded (16 courses, ~1,860 cards). The real data exposed the flat deck list, so the window now follows the Mac's layout: Home dashboard, semesters/courses sidebar, deck column. There's also an app icon and a desktop shortcut (`%USERPROFILE%\Desktop\GRASP.lnk` → the debug exe).
   - Still to check with real data: studying a big deck, and approving drafts in bulk.
   - Home still lacks the Mac's upcoming exams, "pick up where you left off" card, recent decks and streak.
3. **Overviews.**
   - The Mac generates overviews and they sync as `noteOverview` rows, so after sign-in they're already in the Windows DB.
   - Render them read-only first: sections, key terms, worked examples, figures. The Mac's `Sources/GRASP/Shared/OverviewStore.swift` and `Shared/Overview/*` show how.
   - Generating overviews on Windows (via Ollama) comes later.
4. **The rest of the Mac feature set**, roughly in order of use:
   - card editing and draft review, search
   - Learn mode (`LearnEngine`), custom tests (`TestBuilder`)
   - calendar and exams
   - profile picker and PIN lock, settings screen
   - AI actions via Ollama (the core client already works on Windows)
5. **Platform work:**
   - PDF text via Windows.Data.Pdf and OCR via Windows.Media.Ocr (`PDFExtractor`/`ImageExtractor` currently return nil on Windows)
   - Google sign-in: PKCE via `/auth/v1/authorize`, with either a `grasp://` protocol activation (SwiftCrossUI supports URL schemes) or a loopback redirect, which needs the redirect URL added in Supabase
   - an installer or packaging, and an app icon

## When you finish a chunk

Push, then give Tyler a short summary: what works now, what he should click to try it, and anything that needs the Mac (commits marked `[needs Mac check]`). He'll pass that to the Mac session.
