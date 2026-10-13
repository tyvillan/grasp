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

## Design
- Tokens and components come from `Sources/GRASP/Shared/Theme.swift`,
  `Controls.swift` and `Popups.swift`. No new colours or fonts without asking.
- One filled yellow primary per screen. The sparkle means AI.
- Every animation has a Reduce Motion path.
