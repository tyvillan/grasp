# GRASP

**G**ather **R**esources, **A**pply, **S**tudy, **P**erform

A study app that turns your own class notes into flashcards, adaptive
practice, tests and visual lecture overviews, instead of making you retype
everything into Quizlet by hand. Point it at a folder of lecture notes
(Markdown, PDF, docx, PowerPoint, Jupyter notebooks, scanned images). It
organizes them into courses and decks automatically, then drills them with
the study modes that actually work, scheduled around your exams.

| App | Status |
|---|---|
| **Mac** | Complete: the full app |
| **iPhone** | Complete: studying, overviews, calendar and sync, sharing the Mac's core |
| **Windows** | In progress: the shared core builds and passes its tests on Windows, and a native app is under way on the `windows-app` branch |

> **Status: in development.** It's built and tested against one real
> Obsidian vault, and hasn't been used by anyone but its author yet. The
> shared core has over 470 automated tests, many of them run against real
> imported content.

## What it does

### Importing notes
- **Reads** Markdown, PDF, docx, PowerPoint (slide text and speaker
  notes), `.ipynb`, and PNG/JPEG images (on-device OCR).
- **Organizes** notes into semesters, courses and decks automatically,
  from folder structure and filenames.
- **Takes one-off files too:** add a course by hand and drop in files or
  folders that never lived in the vault, like a homework PDF or a scanned
  handout.
- **Timelines in your words** ("Fall 2026", "2026-2027", whatever you call
  your terms) instead of a fixed dropdown.
- **Deleted courses stay deleted:** the course's folder is excluded from
  future imports instead of being recreated on the next scan, with a
  one-click undo.

### Cards
- **Built from your notes:** cards come from lecture-style notes (term and
  definition pairs) by a set of fixed rules, not AI. The same note always
  gives the same cards.
- **Drafts first:** new cards wait in a review queue, so nothing reaches
  study until you approve it.
- **"All Cards":** a course-wide view across every deck, with multi-select
  and batch approve, suspend, move and delete.
- **Near-duplicate detection:** catches overlapping cards from two notes
  on the same material, at import time and in a clean-up sheet.
- **Each card links back to its source note** and the files each deck came
  from.

### Studying
- **Flashcards** on real spaced repetition: a from-scratch FSRS-5
  implementation, checked against the algorithm's published reference
  test vectors.
- **Learn mode:** adaptive rounds that move from multiple choice to
  written answers to true/false as you master a term. Answer grading
  forgives a small spelling slip.
- **Custom tests:** choose the question count, question types and
  shuffling. Missed questions feed back into your flashcard schedule.
- **Focus timer:** an optional Pomodoro timer that suggests breaks
  without ever interrupting a session.
- **Full-text search** across every imported note.

### Lecture overviews
- **One structured overview per lecture:** key takeaways, key terms linked
  to the cards that test them, an outline and a concept diagram, read
  alongside the cards made from the same note.
- **Worked examples with step-by-step diagrams.** Math courses get exact
  row-reduction walkthroughs taken from your notes. Key terms show
  side-by-side "is / isn't" comparisons, for example an echelon matrix
  next to one that isn't.
- **Checked against the notes:** a second pass looks for statements the
  notes contradict and merges sections that repeat each other. Code
  courses show code from your own notes.
- **Kept up to date:** overviews are flagged "out of date" when their note
  changes, and regenerate on demand.

### Exams and calendar
- **Exam-aware scheduling:** cards due after an exam are pulled in to come
  back before it, and in the final week the queue puts your weakest cards
  first.
- **Calendar import:** exams and quizzes come in from the Mac's Calendar,
  including subscribed Google or iCloud calendars. GRASP only reads them;
  it never changes your calendar.
- **Study planner:** suggests study blocks leading up to an exam.

### Across devices
- **Optional accounts and sync** through Supabase: sign in with Google or
  email, and a profile's library syncs between your Mac, iPhone and
  Windows PC. Without an account, everything stays local.
- **Local profiles**, each with its own database, optionally locked with
  a PIN.
- **Widgets** for iPhone and Mac: cards due and study streak, a countdown
  to the next exam, and "jump back in" to a recent deck.

### Optional local AI
- **Two ways to run it:** a local [Ollama](https://ollama.com) server
  (setup and status built into Settings), or Apple's on-device model with
  no setup at all.
- **What it does:** writes the lecture overviews, rewords cards for
  clarity, and proposes cards for concepts a note implies but never spelled
  out. It always stays grounded in the note's own text.
- **Fully usable without it:** cards come from the rule-based parser
  either way.

## What it doesn't do (yet)

- No matching or arcade-style games
- No Canvas LMS integration: notes come from a local folder, not a synced
  course site
- On Windows: most of the app is still being built, including reading
  PDFs and scanned images, overviews, Google sign-in and an installer

## How it's built

- **Shared core:** `Sources/GRASPCore` is shared by every app. It holds
  import, the database ([GRDB](https://github.com/groue/GRDB.swift) over
  SQLite), FSRS scheduling, study actions, overview generation and
  figures, and sync. It's plain Swift with no UI code, and it builds on
  macOS, iOS and Windows.
- **Mac app:** `Sources/GRASP`, built with SwiftUI.
- **iPhone app:** `GRASPiOS/`, an Xcode project with SwiftUI and WidgetKit
  widgets. It shares the Mac's app layer where it can.
- **Windows app:** `Windows/`, built with
  [SwiftCrossUI](https://github.com/moreSwift/swift-cross-ui), which draws
  native WinUI controls. It's a separate package, so its dependencies stay
  out of the Apple builds.
- **Apple-only readers:** on Apple platforms, PDFKit, Vision (OCR) and
  Cocoa's Office reader handle PDFs, images and docx.
  [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) reads pptx
  slides.
- **Sync:** every synced row is plain JSON in one Supabase table, so any
  client can read and write it. See [SYNC_SETUP.md](SYNC_SETUP.md).

## Building

**Mac**

```sh
swift build          # debug build
swift test           # run the test suite
./build.sh           # release build, packaged and signed into build/GRASP.app
```

`build.sh` produces a signed universal (Apple Silicon and Intel) `.app`
with its widgets. Point the app at a folder of class notes in Settings.

**iPhone:** open `GRASPiOS/GRASPiOS.xcodeproj` in Xcode and run the
`GRASPiOS` scheme.

**Windows:** follow [WINDOWS.md](WINDOWS.md). A helper script builds
SQLite and sets up the toolchain, then runs the core check or the tests:

```powershell
scripts\windows\grasp.cmd check   # smoke test of the core
scripts\windows\grasp.cmd test    # test suite
```

**Sync** is optional. To turn it on, follow [SYNC_SETUP.md](SYNC_SETUP.md)
to create the Supabase table.
