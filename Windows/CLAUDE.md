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
scripts\windows\grasp.cmd app         # build and open the Windows app (blocks while it runs)
scripts\windows\grasp.cmd app-build   # build the app without opening it
scripts\windows\grasp.cmd app-release # optimised build (~12 min, recompiles WinUI); the desktop shortcut runs this one
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

## Speed (Tyler found the app slow)

- **Tyler runs the installed app** in `%LOCALAPPDATA%\Programs\GRASP` (Start menu and desktop shortcuts, listed in Settings > Apps). After shipping a change, run `scripts\windows\install.ps1` (builds release, closes his window, reinstalls; `-SkipBuild` reuses the last build, `-Uninstall` removes it). It copies the Swift runtime DLLs beside the exe, so it runs without the toolchain on PATH. Debug is for development only: it opened the window in 7.1 s against 2.4 s, and switched screens about twice as slowly.
- **Cost is per view on screen, not per modifier.** Measured (debug): each Text or shape costs about 2.5 ms to create, `.padding`/`.background`/`.cornerRadius`/`.onTapGesture` add almost nothing, and every screen change also pays about 150 ms to re-measure the whole window (sidebar included). Database reads are 0-30 ms and not the problem.
- So: keep rows light (no per-row `Menu`: 50 card rows with one each took 1.6 s), page long lists (cards show 25 at a time), and put actions in a sheet or a single toolbar instead of on every row.
- `Library.cards(inDecks:)` and `deckOverview(inDecks:)` cache on `revision`; follow that for any other read a body makes.

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
- **Sheets need the window to be up.** Presenting a `.sheet` during the first `onAppear` crashes with "This element does not have a XamlRoot" (WinUIBackend+Sheets.swift). From a click it's fine; from code, wait a moment first.
- `Picker(of:selection:)` is a drop-down that labels options with `"\(option)"`, so give option types a `description` (see `Choice` in `EventEditor.swift`).
- WinUI's `Toggle` draws in Windows' accent colour (pink here), not GRASP's amber. Use `SegmentedChoice` pills instead. Labels inside a row of pills need `.fixedSize()`.
- `DatePicker` maps to WinUI's native date and time pickers and works well.
- **Don't use SwiftCrossUI's URL schemes (`urlSchemes` / `onOpenURL`).** WinUIBackend delivers a redirected link on a background thread, and the open window crashes in `dispatch.dll` (0xc000001d) about 15 s later while the second copy hangs. `SignInLink.swift` does it instead: it registers `grasp://` in HKCU itself, and a link launch hands the URL to the open window through `sign-in-link.txt` and quits before SwiftCrossUI starts.
- **Stack size:** Windows gives the main thread 1 MB; SwiftCrossUI's recursive layout of a long overview lesson overflowed it (0xc00000fd in swiftCore, crash appears a few seconds after the screen opens, often with no backtrace). `grasp.ps1` links with `/STACK:16777216`. Keep it, and still prefer small named subviews over one giant body.
- A process that crashed stays alive for several seconds while it writes its backtrace, so check for a window handle and the crash text, not just `HasExited`.
- `print` output doesn't reach `GRASPWindows.log` promptly (stdout is fully buffered there); write to stderr for debugging.

**GRASPCore data**
- **Paths are identity.** `Material.relativePath`, `Course.folderPath` and `ExcludedFolder.folderPath` are full paths, and Tyler's are Mac iCloud paths. Imports here go through `VaultScanner(database:paths:)` with `Library.vaultPaths()`, a `VaultPathMap` that stores the Mac path for anything under `%USERPROFILE%\iCloudDrive` (app containers like `iCloud~md~obsidian` lose their `Documents` folder on Windows) and maps back to open files. Never import iCloud files with a bare `VaultScanner(database:)`, or every note duplicates. The sweep won't retire a Mac note whose folder hasn't synced to this PC.
- `RowOperation.target`/`source` are **1-based**, as written (R₁); subtract 1 for array indices.

## The Windows app today (`Windows/Sources/GRASPWindows/`)

| File | Role |
|---|---|
| `Launcher.swift` | The real `@main`: makes GUI launches safe (see gotchas), then runs `GRASPWindowsApp` |
| `GRASPWindowsApp.swift` | The app; `ContentView` (sidebar of semesters/courses, then Home or a course), `CourseView` + `DeckColumn` (Mac-style deck column with All Cards), `DeckView` |
| `HomeView.swift` | The dashboard: wordmark, greeting, figures with streak and daily-goal bar, upcoming exams, course tiles |
| `CalendarScreen.swift`, `EventEditor.swift` | The calendar (month / week / agenda, workload dots) and the event sheet (study plans, delete), over GRASPCore's `CalendarActions` |
| `SettingsScreen.swift`, `AppSettings.swift` | Settings, and this profile's preferences in `Profiles\<id>\settings.json` (daily goal, week start, calendar view, notes folder) |
| `CardList.swift`, `SearchScreen.swift` | The Cards tab's list and card editor; Search over cards and notes, and the note reader |
| `OverviewReader.swift`, `LessonFigureViews.swift` | The Overview tab: lessons, callouts, figures, concept map |
| `Theme.swift` | The Mac's `GRASPColor` palette and type scale, `SectionLabel`, `DueBadge` |
| `Library.swift` | `@Observable` model: opens the profile's DB, semesters/courses/decks with the Mac's ordering, import (folder / sample), study actions via `Study`, row-reduction lookup. Counterpart of the Mac's `AppStore` |
| `ConsoleOutput.swift`, `WindowIcon.swift` | Windows plumbing: log file and CRT handler for GUI launches; puts the embedded icon on the window |
| `Resources/GRASP.ico`, `GRASP.rc` | The app icon (from the iPhone AppIcon, via `scripts\windows\make-icon.ps1`), embedded by `grasp.ps1` |
| `StudySessionView.swift`, `TestSession.swift` | Study modes: flashcards, Learn rounds, tests (setup, run, results), and the shared question view |
| `RowReductionView.swift` | Steps through a row reduction from the notes: `MatrixGrid`, `Bracket` shape |
| `Account.swift` | Sign-in/sign-up (Google via the browser, or email + password), linking the profile, sync every 120 s and 8 s after a change, reloading on pulled changes |
| `AccountViews.swift` | Sidebar account panel and the sign-in sheet |
| `SignInLink.swift`, `ExternalLink.swift` | The `grasp://auth-callback` link Google sign-in returns with (registration, hand-off to the open window); opening the browser |
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
   - ~~Home's "pick up where you left off" card and recent decks~~ **Done** (GRASPCore `Dashboard`, `[needs Mac check]`). Continue opens the deck straight into flashcards via `Library.requestStudy`.
   - **Calendar and Settings: done** (Tyler asked for them ahead of overviews). Calendar logic moved into GRASPCore (`CalendarActions`, `StudyProgress`, marked `[needs Mac check]`). Not ported: the Mac's "Sync Calendar", which reads macOS Calendar. Settings covers what works on Windows; the Mac's focus timer, AI test questions and duplicate/off-topic sweeps get their settings when those features arrive.
3. **Overviews: read-only reader done.** Deck page has Cards / Overview tabs; lessons render one at a time (picker, Previous/Next) with objectives, sections, key terms with is/isn't and matrix contrasts, figures (row reduction, two lines, 2x2 transform), worked examples, checks, code, takeaways and the concept map. Assembly is GRASPCore's `DeckOverviewReader` (moved from the Mac's OverviewStore, `[needs Mac check]`). Writing works too: Ollama 0.34 and `qwen3.5:9b` are installed on this PC (RTX 5060, 8 GB; about 2.5 minutes a lecture). `OverviewJob` runs the Mac's per-note loop over GRASPCore's `OverviewWriter` (`[needs Mac check]`), loading the model first. Still to do: the Mac's \"On this page\" rail, and polishing the concept map against real diagrams.
   - The Mac generates overviews and they sync as `noteOverview` rows, so after sign-in they're already in the Windows DB.
   - Render them read-only first: sections, key terms, worked examples, figures. The Mac's `Sources/GRASP/Shared/OverviewStore.swift` and `Shared/Overview/*` show how.
4. **The rest of the Mac feature set**, roughly in order of use:
   - ~~card editing and draft review, search~~ **Done:** the Cards tab lists cards (status filter, text filter, 50 at a time) with a menu to edit, approve, suspend, move, revert an AI refinement or delete, plus New Card; Search (sidebar) finds cards and notes and opens a note to read. Logic is GRASPCore's `CardActions` (`[needs Mac check]`). Also the Mac's sort (deck order, A–Z, date added, due), mastery filter, and bulk actions via a Select button (no Cmd/Shift-click in SwiftCrossUI).
   - ~~Learn mode, custom tests~~ **Done:** the deck header has Study / Learn / Test, each taking over the deck page (`StudySessionView.swift`, `TestSession.swift`). Flashcards use the Mac's two verdicts (Needs Review / I Know This), not four grades. Logic is GRASPCore's `Study.mark`, `learnRound`, `recordLearnAnswer`, `startTest`, `finishTest`… in `StudyModes.swift` (`[needs Mac check]`). Answers save without reloading the library; `Library.finishSession()` reloads when a session ends. AI test questions (Settings → Local AI, `CardAI.generateTestQuestions`) and the focus timer (`FocusTimer.swift`, flashcards only, as on the Mac) are done too. Keyboard: flashcards take the Mac's Space / 1 / 2 / arrows / E / S / Esc through `KeyCommands` (a thread-local WH_GETMESSAGE hook, since SwiftCrossUI only has `onSubmit`); a screen sets `KeyCommands.handler` on appear and clears it on disappear. Typed answers and PIN fields submit on Enter.
   - calendar and exams
   - ~~course and deck organising~~ **Done:** the deck column's ••• menu has New Deck, Edit Course (name, code, colour, timeline), Archive and Delete Course; the deck page's ••• has Rename and Delete Deck (move its cards or delete them); + New Course sits under Import. The course menu also has Dates for This Course (the Mac's ExamsSheet) and Add Files (`VaultScanner.importPaths`; SwiftCrossUI's file dialog picks one file or folder). GRASPCore `LibraryActions` (`[needs Mac check]`). SwiftCrossUI has no right-click on WinUI (`TapGesture.secondary` fatalErrors), so these are menus, not context menus.
   - ~~profile picker and PIN lock~~ **Done:** `ProfilePicker.swift` (Who's studying?, New Profile, PIN unlock), `AppSession` in `GRASPWindowsApp.swift`; skipped at launch when there's one profile with no PIN (the Mac always shows it). Settings → Profile sets/removes the PIN and has Switch Profile. Sign-in stays inside a profile (the Mac's picker also offers it).
   - ~~AI card actions~~ **Done:** the deck header's Tools menu has Refine Drafts with AI, Fill Gaps with AI and Review Duplicates; the card window has Refine with AI; Settings has the check-every-card sweep. GRASPCore `CardAI` (`[needs Mac check]`); `CardAIJob` runs them with progress and Stop.
5. **Platform work:**
   - ~~PDF text and image OCR~~ **Done** via `WindowsOCR` (GRASPCore, `#if os(Windows)`): Windows PowerShell 5.1 reaches Windows.Data.Pdf and Windows.Media.Ocr through .NET's WinRT interop, so the extractors run a small script and read UTF-8 text back. PDF pages are rendered and OCR'd (works for scanned PDFs too); no console window appears from the GUI app. Old note: swift-winui's `UWP` module has no projections for Windows.Data.Pdf or Windows.Media.Ocr (only C headers in CWinRT), and Windows.Data.Pdf renders pages but doesn't extract text. Options: generate projections with swift-winrt, or a pure-Swift PDF text reader. Low priority while notes are imported on the Mac.
   - ~~Deck files, source note, Copy Lesson~~ **Done:** Tools → Files in This Deck (GRASPCore `DeckFiles`, `[needs Mac check]`), Show Source Note in the card window, Copy Lesson on overviews; `ExternalLink`/`Clipboard` wrap ShellExecute and the Win32 clipboard.
   - ~~Google sign-in~~ **Done:** PKCE through `SupabaseAuth.oauthStart` / `completeOAuth`, back via `grasp://auth-callback` (already allowed in Supabase for the Mac). Tyler still has to try it for real.
   - ~~an installer~~ **Done:** `scripts\windows\install.ps1` (per-user, no admin). A signed MSIX would need a certificate.

## From the Mac session: study guides (read before touching GRASPCore)

The Mac added study guides, which attach to an exam. Tyler's first real ones are for ECO 2023 Midterm 1 (Sep 29). New shared code, all with tests:

- **Schema:** migration `v9_study_guide` adds `studyGuide`, `studyGuidePartDeck` and `skillRating`, all synced (appended to `SyncSchema.tables` after `calendarEvent`). A new migration goes after it with a new name. Never edit or reorder v9. `SyncSchema.installTriggers` now skips tables that don't exist yet, so a migration that adds a synced table just calls it again.
- **Code:** `Sources/GRASPCore/StudyGuide/`: `StudyGuideDocument`, `StudyGuideParser` (rules-based), `StudyGuideMatcher` (links a guide to an exam and its parts to lecture decks), `StudyGuideModels`, `StudyGuideActions` (import, rematch, set exam/decks, rate a skill, delete, `examPage`, `examDeckIds`).
- **Import:** `VaultScanner` treats a file titled like a study guide ("study guide", "exam N review"…) as not study-worthy: no parser cards, no General deck. Instead it calls `StudyGuideActions.importGuide`.
- **Extractors:** `PDFExtractor.extractPages(from:)` returns one entry per page (the parser uses page numbers). On Windows it wraps `WindowsOCR`'s whole-document text as a single page, so guides read there have no page numbers. Per-page output from the PowerShell script would fix it. `Ingest/Extractors/TextRecognition.swift` is the shared Vision helper (Apple only).
- **Porting:** the Mac's exam page is `Sources/GRASP/Views/StudyGuide/ExamStudyView.swift` (parts, question counts, skills rated can-do-cold / shaky / can't-yet, traps, practice problems with the answer hidden until tapped, and Flashcards/Learn/Test over the exam's decks via `DeckScope.exam`). No rush. A Windows build without this core code skips guide rows when it syncs, and those rows don't come back after updating until a guide changes again.
- **Coming on the Mac:** weakest-skills-first, tests weighted by question count, traps as true/false questions, and an AI fallback parser. Clickable key terms may be reused on the exam page.

## When you finish a chunk

Push, then give Tyler a short summary: what works now, what he should click to try it, and anything that needs the Mac (commits marked `[needs Mac check]`). He'll pass that to the Mac session.
