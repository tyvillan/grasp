# GRASP design system

How the Mac and iPhone apps are actually built. Source of truth is the code:
`Sources/GRASP/Shared/Theme.swift` (tokens, type, space, motion),
`Controls.swift` (buttons, menus, chips), `Popups.swift` (sheets and form
controls). The iPhone app compiles the same files, so the two cannot drift.

## Colour
All colours are `GRASPColor` tokens in `Theme.swift`, dynamic for dark and light. Never write a hex in a view.

| Token | Dark | Light | Use |
|---|---|---|---|
| `canvas` | `0E100F` | `F7F4E3` | the page |
| `inset` | `0A0B0A` | `EEEAD4` | wells: progress tracks, fields, unselected pills |
| `surface` ("panel") | `171917` | `FFFDF3` | cards, sidebar, strips |
| `surfaceRaised` | `1F221F` | `FFFFFF` | hover, selected, segmented selection |
| `hairline` / `hairlineStrong` | `2C2E2A` / `3B3E38` | `E2DDC4` / `CFC9AC` | every border |
| `textPrimary` (cream) | `FFFCE1` | `14160F` | titles, body |
| `textSecondary` | `B9B7A5` | `4A4A3E` | supporting text |
| `textTertiary` (muted) | `8C8C7E` | `6A695B` | meta, status words; never lighter (4.5:1 floor) |
| `brand` | `FFD43B` | same | yellow as a fill |
| `ink` | `0E100F` | same | text on `brand` |
| `accent` | `FFD43B` | `7A5900` | yellow as text or icon (gold on cream) |
| `success` | `5FC9B5` | `14705E` | understood, correct, approve |
| `rejected` | `E08A83` | `B2453F` | coral: wrong, suspended, delete |

Soft variants (`accentSoft`, `successSoft`, `rejectedSoft`) are tints behind chips only.

**Yellow budget.** One filled yellow button per screen (`GRASPProminentButton`;
Study on the deck page, the generate button on an empty deck, Reveal answer in
Study). Yellow otherwise appears only as: the AI sparkle, the 6 pt brand dot on
section labels, the Home countdown numeral, selection checks and the sidebar's
current-item edge, and progress fills where a bar carries the brand. Everything else
is cream or muted. Segmented controls and filter pills select in `surfaceRaised`
with a hairline, never yellow. The Home streak chip is outlined.

**The sparkle (`AIGlyph.symbol`, "sparkles") means "AI acts here"** and is used
for nothing else: Generate cards, Rewrite with AI, Refine, AI-made drafts,
Settings → AI. It is always `accent`.

**Course colours** (`CoursePalette`, six slots, never yellow) appear on the
sidebar dot and on Calendar events, and in the course colour picker. Not on
Home, deck headers or exam rows.

## Type
Two bundled families: **Bricolage Grotesque** (display: `graspDisplay`, 800 cut for
heroes, 600 for titles) and **Instrument Sans** (everything read or clicked:
`graspUI`, 400/500/600/700). Use `.graspType(_)`, not raw sizes:
display 36, lesson title 32, numeral 30, prose H2 22, title 18, body 14,
row title 14 medium, meta 12.5, eyebrow 12 semibold uppercase (+0.96 tracking),
study prompt 26, prose 16, lede 19. Display sizes track about −0.02 em; digits are
tabular wherever a number changes. Code is system monospaced.

## Shape and depth
Pill buttons (`Capsule`); cards 14 pt radius (`GRASPRadius.card`), rows and wells
10 pt (`inner`). Depth is the surface ladder and 1 pt hairlines, not shadows. The
one deliberate shadow is the floating selection bar. 4 pt grid
(`GRASPSpace`: 4, 8, 12, 16, 24, 32, 40). Page content sits in a 1180 pt column
with 40 pt side padding (Home, Library, Study guides).

## Motion
Everything is in `Motion` (`Theme.swift`): three durations and two curves, and
nothing longer than 0.32 s, with no overshoot, no repeating animation except the
AI sparkle pulse, and nothing that blocks or delays input. Every animation is
state-driven, so a new tap interrupts it.

| Token | Value | Use |
|---|---|---|
| `quick` | 0.12 s | press, hover colour and fill, focus |
| `base` | 0.20 s | cross-fades, row status word (out then in, 0.10 each), card reveal (scale to 0.96 and back, 0.10 each, the answer fades in), strips appearing |
| `glide` | 0.32 s | entrances, slides, expand and collapse, selection bar, progress fill, count-ups |
| `out` | `timingCurve(0.2, 0, 0, 1)` | things that arrive or open |
| `inOut` | `timingCurve(0.4, 0, 0.2, 1)` | things that move between two places (thumbs, card reveal) |

Names used in views map to those: `snappy` is `glide` in-out, `settle`, `fill`
and `bouncy` are `glide`, `fade` is `base`, `press` is `quick`, `thumb` is
`glide` in-out (instant under Reduce Motion), `countUp` is `glide` (instant
under Reduce Motion). The 190 pt Home numeral (`numeral`) rolls at `base`: its
digit morph blurs, and it must be sharp inside `glide`. Transitions use `Motion.slide(from:)` (a 12 pt offset and
a fade, just a fade under Reduce Motion). Do not write `.easeOut(duration:)`,
`.spring(`, or `withAnimation {` in a view; a test fails if you do.

**Reduce Motion rule.** Positional motion (rise, slide, scale, rotation) becomes an
opacity change at `quick`; opacity-only changes (cross-fades, count-ups) become
instant. There is no exception for hover or press: a hover or press scale, lift
or nudge applies only when motion is not reduced, and under Reduce Motion the same
state is shown with opacity or colour only (a pressed button dims to 0.8, a
hovered one brightens). The tokens already do this, using `Motion.isReduced`, which is the system
setting or the launch flag `-GRASPForceReduceMotion 1` (Mac: `open -a GRASP --args
-GRASPForceReduceMotion 1`; iPhone simulator: `simctl launch ... -GRASPForceReduceMotion 1`).
A view that uses the tokens needs no check of its own.

## Patterns
- **Deck toolbar.** Left: Study (yellow), Learn, Test. Right: Generate cards
  (outlined, sparkle), then Add (Cards) or Edit (Overview), then ⋯. Under about 640 pt
  of pane width every button becomes an icon with a tooltip. Under 1000 pt of window
  the deck list collapses.
- **Menus** are GRASP's own panel (`PillMenu`, `IconMenu`), never the system menu.
  Popups are `GRASPSheet`; confirmations are `ConfirmationSheet`; no system alerts.
- **Status strip.** One rounded `surface` strip at the top of the list: drafts to
  review (layered-cards glyph) or duplicates, with one action. A failed AI run
  replaces it with the error and Retry.
- **Row status word.** One muted word on the right (Draft, New, Due today, in 3d);
  it cross-fades to the row's actions (preview, approve, ⋯) on hover or keyboard focus.
  A 2 pt rail on the left carries mastery in cream steps; AI-made drafts carry the
  sparkle and a "from <note>" line.
- **Row flag.** A parser-made draft that looks like a duplicate or a heading gets one
  muted line under its answer ("Looks like a duplicate of “Set”.", "This front
  looks like a heading."). It is a flag only: nothing is hidden or removed, and
  approved cards, manual cards and AI cards are never flagged. AI cards that fail
  the same checks are never saved (`CardQuality`).
- **Understanding meter.** Three short capsules (about 10 x 4 pt with a 2 pt gap
  on a row; 12 x 5 on a card; 16 x 6 large) for how close a card is to
  understood: recognition, recall, understood (Learn ladder levels 1 to 3; level
  0 has none filled). Capsules, not dots, so they never read as page dots or the
  sidebar's coloured dots. Shape carries the meaning and colour only reinforces
  it. A **solid** capsule was reached and shown (cream; the last turns `success`
  green when understood). A **dashed** outline was claimed with "I Know This" and
  not yet shown: a self-rated card is two dashed capsules and one empty, and one
  right answer in Learn completes it. An **outline** is not reached
  (`hairlineStrong` for a card nobody has asked about, which reads "New"; a firmer
  tertiary outline for a card asked and missed). "Understood" means mastered
  only: a self-rated card is never counted as understood, in the pips, the deck
  bar, the "Understood N" filter pill and the card preview chip alike. Sizes: row
  (left of a row, replacing the old mastery rail; draft and suspended cards keep
  the 2 pt rail), card (Study corner, muted), large with the word. A row with any
  Learn progress does not say "New" on the right; "Draft", "Due today",
  "Overdue" and "in 3d" stay. Learn shows the card after an answer, never
  before the question, using the ladder's own rules: the single current state when
  the level did not change, or the pips before, an arrow and the pips after with
  one line ("Recall to understood", "Back to recognition") when it did. The change
  fades in over 0.20 s (`Motion.base`, no overshoot) and is an instant swap under
  Reduce Motion. The deck page shows the same steps as one stacked bar
  (understood in green, recall and recognition in cream strengths, self-rated with
  a dashed edge, not asked as an outlined track), a count line ("14 understood, 9
  recall, 6 recognition, 22 not asked"), the five weakest notes (title from the
  note's first heading, else its humanized file name; the mini bar under the name
  at full width, "3 of 14 understood" on the right; tapping one filters the card
  list) and an outlined "Practice weakest" button (a Learn round on up to 8 cards;
  never a second filled yellow). On the iPhone the notes list sits behind a
  disclosure, closed by default. No yellow, no new colour, font or radius.
  VoiceOver reads "Recall, 2 of 3 steps", "Understood, 3 of 3 steps",
  "Self-rated, not yet tested", "New".
- **Selection.** Any selected row gives every row a round checkbox on its left
  (yellow check / empty ring); selected rows are `surfaceRaised`. One floating bar:
  Approve N, Suspend, Move to…, Delete (coral), clear.
- **Live generation strip.** Pulsing sparkle, "Generating from <note>…", "N new",
  Stop. New rows slide in at the top; counts everywhere come from `DeckCardCounts`
  and move together once a batch is on screen.
- **Empty states.** One action, one quiet way out, no filters or counts. An empty
  deck's single filled yellow button is "Generate cards from your notes".
- **Study finish.** "N cards done", the two tallies, one muted line of progress to
  the daily goal, then Done (the one filled yellow button) with at most one
  outlined follow-on beside it: "Learn the N you missed", else "Take a test".
- **Dimmed study row.** When Study or Learn is dimmed the deck page says why in one
  muted line under the row (Mac and iPhone use the same wording).
- **Calendar dots.** The dot beside a day number is that day's cards due (1 to 20
  green, 21 to 50 yellow, over 50 coral); the month's footer is the legend.
- **Typed answers** have three outcomes: Correct (green), Close enough (counts as
  correct: "Your answer works. The card says: ..." plus one muted reason line, a
  neutral check on Test results) and Not quite (coral, "Your answer" and "Card says"
  on separate lines). "Checking..." shows while the AI judge looks at a borderline
  answer, for at most 3 s.
- **Study sheets** (Learn, Test, flashcards) sit on a near-black scrim, one progress
  bar, answers never replace the question.

**Naming AI actions.** Name an AI action by what it produces: cards, overview,
study guide, test questions. Never "questions" for card generation. The deck
toolbar button is "Generate cards", the empty deck's is "Generate cards from your
notes", the strip says "Generating cards from <note>" and "N new cards". The Test
setup toggle is "Include AI-written questions" (fresh questions for that test only,
never saved as cards).

## Rules for new screens
1. Reuse tokens and components; add no colour, font or radius without asking.
2. One filled yellow primary per screen; yellow elsewhere only as listed above.
3. The sparkle is for AI only; AI actions are outlined, never filled.
4. Every animation has a Reduce Motion path through `Motion`.
5. Use `GRASPSheet` for popups and `PillMenu` for menus; no system alerts or menus.
6. Text on muted never goes lighter than `textTertiary`.
7. The screen must work at 800 pt wide on the Mac and on an iPhone SE.

## Known deviations
- **Mac Settings window** keeps the native title bar and tab strip. A transparent
  title bar over the canvas made the tabs vanish, so the window content uses
  brand tokens but the chrome stays system.
- **iPhone tab bar is a custom bar** (`GRASPiOS/App/MainTabView.swift`), because
  the system Liquid Glass bar cannot be made opaque. The system tab bar is hidden.
  New tabs must be added in `MainTabView`, not only in the `TabView`.
