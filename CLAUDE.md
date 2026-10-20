# GRASP: working rules

Read `DESIGN.md` before any UI work. Windows notes are in `Windows/CLAUDE.md`.

## Workflow
- One branch per task, off `main` (it equals `study-guides` for now). Report back before merging.
- Never change `Sources/GRASPCore` without asking.
- Run `GRASP_SKIP_OCR=1 swift test 2>&1 | tee <log>` and put the log path in your report.
- Build Mac (`./build.sh`) and iPhone (`GRASPiOS`) before reporting.
- `main` is the main line. `study-guides` is kept at the same commit. `windows-app` only fast-forwards to it.

## Branches (as of 2026-10-20)
- `main` = `study-guides` = `questions-tab`, all at the same commit (fast-forwarded, no merge commits). It contains the study guides, understanding meter, Test feeds the meter, Learn streak (synced), comebacks, two-miss drop, test defaults, suspend deck, stage colours, generation quality and the Questions tab (migration v19). Tag `main-before-questions-tab` marks the old `main`.
- 2026-10-20: `main` also contains move/copy questions, photo import (migration v20: `questionImage`, `testQuestion.imageCrop`, `syncState.pictureCursor`; pictures sync apart from other rows in small pages) and `polish-1`. Tag `main-before-photo-import` marks the previous `main` (2f4b395). Branches `question-move-copy`, `photo-import` and `polish-1` are merged.
- Not in `main`, each its own branch: `cloud-speed` (call timing, pacing, batched checks; conflicts with `AIKeyStore.swift` and `AnswerJudge.swift`, and adds required `CardGenerator` methods), `cpp-question-rules` (merges clean), `windows-app` (Windows session; `Windows/CLAUDE.md` will conflict, keep both sections). `cloud-speed-baseline` is a measurement copy, never merged.
- The real library is at schema v20 once the Mac app built from this `main` has been opened on it; the phone needs a reinstall to match.

## Real data is off limits
- Screenshots and UI tests must NEVER create real data. Use a copy of the
  library (like the simulator's stripped copy) or a throwaway profile, never
  the real profile.
- Do not run Study, Learn or Test against the real library. They write review
  history, move the streak and sync to the server and the phone.
- Do not approve, suspend, delete or generate cards in the real library.
- If a temporary deck is unavoidable, it goes in a throwaway profile.

## Copy
- No double hyphens or dashes in UI text. Use a period or a comma.
- Name AI actions by what they produce: cards, overview, study guide, test questions.
  Never "questions" for card generation ("Generate cards", not "Generate questions").

## Design
- Tokens and components come from `Sources/GRASP/Shared/Theme.swift`,
  `Controls.swift` and `Popups.swift`. No new colours or fonts without asking.
- One filled yellow primary per screen. The sparkle means AI.
- Every animation uses a `Motion` token (0.12 / 0.20 / 0.32 s, no overshoot), which carries the Reduce Motion rule; see DESIGN.md "Motion".
- Canned AI hooks for screenshots (`GRASP_STUB_JUDGE`, `GRASP_STUB_EXPLAIN`) go through `StubHooks`: debug builds only, and they also need the launch flag `-GRASPAllowStubs 1`. A release build ignores them.
