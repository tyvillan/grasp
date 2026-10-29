# GRASP: working rules

Read `DESIGN.md` before any UI work. Windows notes are in `Windows/CLAUDE.md`.

## Workflow
- One branch per task, off `study-guides`. Report back before merging.
- Never change `Sources/GRASPCore` without asking.
- Run `GRASP_SKIP_OCR=1 swift test 2>&1 | tee <log>` and put the log path in your report.
- Build Mac (`./build.sh`) and iPhone (`GRASPiOS`) before reporting.
- `study-guides` is the main line. `windows-app` only fast-forwards to it.

## Branches (as of 2026-10-29)
- 2026-10-29: the old `main` was merged into `study-guides` (merge commit ceaf999) and the local `main` branch deleted, so `study-guides` is the only main line. Everything the notes below describe as being in `main` is in `study-guides` now. The merge needed two conflict fixes: `CardAI.swift` takes `main`'s batched context check (it replaced the earlier Library version), and the Questions tab row keeps both the move/copy/photo row and the understanding meter. `origin/main` still exists on GitHub until it is pushed past or deleted.
- `main` = `study-guides` = `questions-tab`, all at the same commit (fast-forwarded, no merge commits). It contains the study guides, understanding meter, Test feeds the meter, Learn streak (synced), comebacks, two-miss drop, test defaults, suspend deck, stage colours, generation quality and the Questions tab (migration v19). Tag `main-before-questions-tab` marks the old `main`.
- 2026-10-20: `main` also contains move/copy questions, photo import (migration v20: `questionImage`, `testQuestion.imageCrop`, `syncState.pictureCursor`; pictures sync apart from other rows in small pages) and `polish-1`. Tag `main-before-photo-import` marks the previous `main` (2f4b395). Branches `question-move-copy`, `photo-import` and `polish-1` are merged.
- 2026-10-20: `main` (9442bdf) also contains the Library features (course cards grouped by time frame, off-topic check limited to chosen courses), any-folder import (layouts Automatic, Obsidian vault, Any folder and None, with an info popup each) and `cloud-speed` (call timing, pacing, batched off-topic checks, one stub guard, one judge clock). Branches `library-courses`, `library-timeframes`, `any-folder-import` and `cloud-speed` are merged. No schema change since v20.
- 2026-10-21: `main` also contains the first-run tutorial (merged ea38a2c; branch `tutorial` is merged), the README with screenshots, and a test fix so `TutorialTests` and the generator-selection test never touch the Keychain (`fix-tutorial-test-keychain` is merged). Real-vault test suites now run only with `GRASP_REAL_VAULT=1`.
- 2026-10-21: `main` also contains `feedback` (merged): Send feedback on Mac (Settings and Help menu) and iPhone (Settings), the two one-time asks, the offline queue, and `supabase/feedback.sql` (run in Supabase; a real send with a screenshot and the read-only security probe both passed). No local database change. Tag `main-before-feedback` marks the previous `main` (99fb83d). Send feedback sits above the profile button in the Mac sidebar and at the top right of iPhone Settings. The iPhone needs a reinstall to get it.
- Not in `study-guides`, each its own branch: `cpp-question-rules` (merges clean), `windows-app` (Windows session; `Windows/CLAUDE.md` will conflict, keep both sections). `cloud-speed-baseline` is a measurement copy, never merged.
- Not yet run on real hardware or services: the Photos picker and camera, a real model answering photo questions, a real Supabase photo sync (and pulling many photos onto a fresh device), cloud-speed batching against a cloud model, an any-folder import in the app (core tests only), and a Windows compile of the newer core files.
- The real library is at schema v20 once the Mac app built from this branch has been opened on it; the phone needs a reinstall to match.

## Real data is off limits
- Screenshots and UI tests must NEVER create real data. Use a copy of the
  library (like the simulator's stripped copy) or a throwaway profile, never
  the real profile.
- Do not run Study, Learn or Test against the real library. They write review
  history, move the streak and sync to the server and the phone.
- Do not approve, suspend, delete or generate cards in the real library.
- If a temporary deck is unavoidable, it goes in a throwaway profile.

## Real vault tests
- Off by default. Run them with `GRASP_REAL_VAULT=1 swift test` (about 40 s more).
- They scan my real Obsidian vault (`Master Vault` in iCloud), read-only, into a
  throwaway database. They never write to the vault, but reading can make iCloud
  download notes. Do not run them without asking.
- Run them after changes to: vault scanning or import (`Ingest`), the note
  parser or card pairing, file extraction (PDF, docx, ipynb, images), course or
  semester detection and folder layouts, course deletion and exclusion, the
  database schema or migrations, search indexing, and study, mastery or Test
  logic that is checked against imported notes.
- A plain `swift test` skips them, so a green run does not cover those areas.

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
