# GRASP: working rules

Read `DESIGN.md` before any UI work. Windows notes are in `Windows/CLAUDE.md`.

## Workflow
- One branch per task, off `main` (it equals `study-guides` for now). Report back before merging.
- Never change `Sources/GRASPCore` without asking.
- Run `GRASP_SKIP_OCR=1 swift test 2>&1 | tee <log>` and put the log path in your report.
- Build Mac (`./build.sh`) and iPhone (`GRASPiOS`) before reporting.
- `main` is the main line. `study-guides` is kept at the same commit. `windows-app` only fast-forwards to it.

## Branches (as of 2026-10-21)
- `main` = `study-guides` = `questions-tab`, all at the same commit (fast-forwarded, no merge commits). It contains the study guides, understanding meter, Test feeds the meter, Learn streak (synced), comebacks, two-miss drop, test defaults, suspend deck, stage colours, generation quality and the Questions tab (migration v19). Tag `main-before-questions-tab` marks the old `main`.
- 2026-10-20: `main` also contains move/copy questions, photo import (migration v20: `questionImage`, `testQuestion.imageCrop`, `syncState.pictureCursor`; pictures sync apart from other rows in small pages) and `polish-1`. Tag `main-before-photo-import` marks the previous `main` (2f4b395). Branches `question-move-copy`, `photo-import` and `polish-1` are merged.
- 2026-10-20: `main` (9442bdf) also contains the Library features (course cards grouped by time frame, off-topic check limited to chosen courses), any-folder import (layouts Automatic, Obsidian vault, Any folder and None, with an info popup each) and `cloud-speed` (call timing, pacing, batched off-topic checks, one stub guard, one judge clock). Branches `library-courses`, `library-timeframes`, `any-folder-import` and `cloud-speed` are merged. No schema change since v20.
- 2026-10-21: `main` also contains the first-run tutorial (merged ea38a2c; branch `tutorial` is merged), the README with screenshots, and a test fix so `TutorialTests` and the generator-selection test never touch the Keychain (`fix-tutorial-test-keychain` is merged). Real-vault test suites now run only with `GRASP_REAL_VAULT=1`.
- `feedback` is built and unmerged: Send feedback on Mac and iPhone, the two one-time asks, and `supabase/feedback.sql` (already run in Supabase). It is waiting for a real send test against Supabase, using a throwaway library (`GRASP_SUPPORT_DIR`) and a bundled build. See `supabase/FEEDBACK_SETUP.md`. Do not merge it before that test passes.
- Not in `main`, each its own branch: `cpp-question-rules` (merges clean), `windows-app` (Windows session; `Windows/CLAUDE.md` will conflict, keep both sections). `cloud-speed-baseline` is a measurement copy, never merged.
- Not yet run on real hardware or services: the Photos picker and camera, a real model answering photo questions, a real Supabase photo sync (and pulling many photos onto a fresh device), cloud-speed batching against a cloud model, an any-folder import in the app (core tests only), and a Windows compile of the newer core files.
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
