# GRASP: working rules

Read `DESIGN.md` before any UI work. Windows notes are in `Windows/CLAUDE.md`.

## Workflow
- One branch per task, off `study-guides`. Report back before merging.
- Never change `Sources/GRASPCore` without asking.
- Run `GRASP_SKIP_OCR=1 swift test 2>&1 | tee <log>` and put the log path in your report.
- Build Mac (`./build.sh`) and iPhone (`GRASPiOS`) before reporting.
- `study-guides` is the main line. `windows-app` only fast-forwards to it.

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

## Tests and CI
- GitHub Actions (`.github/workflows/ci.yml`) runs `GRASP_SKIP_OCR=1 swift test` on every push to `study-guides`, `windows-app` and `main`, and on every pull request. It does not build the iPhone app or the Windows port, so keep doing those by hand before reporting.
- New logic goes in `GRASPCore` with a test in `Tests/GRASPCoreTests` (names match the feature, e.g. `LearnEngineTests`). App-layer logic that can't live in the core goes in `Tests/GRASPTests`.
- Tests build their own fixtures (`VaultFixture`, `TestZip`) and never touch the real library; see "Real data is off limits".
