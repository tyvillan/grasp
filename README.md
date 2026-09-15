# GRASP

**G**ather **R**esources, **A**pply, **S**tudy, **P**erform

A native macOS study app that turns your own class notes into flashcards,
adaptive practice, and tests — instead of retyping everything into Quizlet
by hand. Point it at a folder of lecture notes (Markdown, PDF, docx,
PowerPoint, Jupyter notebooks, scanned images) and it organizes them into
courses and decks automatically, then drills them with the study modes
that actually work.

> **Status: in development.** Built against one real Obsidian vault so
> far; the core is solid (162 automated tests, most run against real
> imported content) but it hasn't been used by anyone but its author yet.

## What it does today

- **Imports** Markdown, PDF, docx, PowerPoint (`.pptx`, slide text plus
  speaker notes), `.ipynb`, and PNG/JPEG images (via on-device OCR),
  organizing them into courses and decks automatically from folder
  structure and filenames — or add a course by hand and drop in one-off
  files/folders (a homework PDF, a scanned handout) that never lived in
  the vault at all
- **Deterministic flashcard generation** from lecture-style notes (term +
  definition pairs), with a review queue so nothing reaches study
  unapproved
- **"All Cards"** — a course-wide view spanning every deck at once,
  alongside each individual deck, with multi-select (shift/cmd-click),
  batch approve/suspend/move/delete, and a hover preview that doesn't
  disturb the list
- **Near-duplicate detection** catches overlapping cards from two notes
  covering the same material at import time, plus a review sheet for
  cleaning up what's already in a deck
- **Flashcards** on a real spaced-repetition schedule (a from-scratch
  FSRS-5 implementation, verified against the algorithm's own published
  reference test vectors)
- **Learn mode** — adaptive multiple-choice → written → true/false rounds
  that escalate as you master a term, with fuzzy answer grading (a small
  spelling slip doesn't fail you)
- **Custom tests** — configurable question count, types, and shuffling;
  missed questions feed back into your flashcard schedule
- **Exam dates** that bias scheduling: cards get capped to resurface
  before the exam, and the queue reorders by weakest retention in the
  final week
- **Full-text search** across every note you've imported
- **Freeform timelines** ("Fall 2026", "2026-2027", whatever you actually
  call your terms) instead of a fixed dropdown, with autocomplete against
  what you've already used
- **Local profiles** — no accounts, no server, no network. Each profile's
  data lives in its own local database; share the app with someone and
  they get their own separate profile
- **Optional local AI**, via a local Ollama server if you have one
  running (with setup/status detection built into Settings) or Apple's
  on-device model as a zero-setup fallback — refines parser output, and
  can propose brand-new cards for concepts a note implies but never got
  its own card, always grounded in that note's own text. Fully usable
  with neither; cards just come from the deterministic parser
- **Deleting a course is permanent** — its vault folder is excluded from
  future imports rather than silently recreated on the next scan, with a
  one-click undo (or just add its files to a course by hand again)

## What it doesn't do (yet)

- No matching/arcade-style games
- No Canvas LMS integration — notes come from a local folder, not a
  synced course site
- No cloud sync — a profile's data stays on the Mac it was created on

## Stack

Swift 6 / SwiftUI, SwiftPM (no Xcode project), [GRDB.swift](https://github.com/groue/GRDB.swift)
over SQLite, PDFKit for PDF text extraction, `NSAttributedString`'s Office
Open XML reader for docx, Vision for on-device image OCR, and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) to read pptx's
slide XML.

## Building

```sh
swift build          # debug build
swift test           # run the test suite
./build.sh           # release build, packaged and signed into build/GRASP.app
```

`build.sh` produces a universal (Apple Silicon + Intel) signed `.app`
bundle. Point the app at a folder of class notes via Settings, or use the
default vault path as a starting example.
