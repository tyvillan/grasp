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
for nothing else: Generate questions, Rewrite with AI, Refine, AI-made drafts,
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
Everything is in `Motion` and is fast: `snappy` spring (hover, selection),
`settle` (cards arriving), `bouncy` (small icons), `press` 0.1 s, `fill` (progress),
`flip` 0.22 s, `fade` 0.18 s, `stagger` 0.05 s. Rows arriving during generation
slide in about 60 ms apart (1.5 s cap). **Reduce Motion is always respected:**
read `accessibilityReduceMotion` and use `Motion.choose(_, reduceMotion:)` or
`Motion.fade`; no movement, scaling, pulsing or stagger remains.

## Patterns
- **Deck toolbar.** Left: Study (yellow), Learn, Test. Right: Generate questions
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
- **Selection.** Any selected row gives every row a round checkbox on its left
  (yellow check / empty ring); selected rows are `surfaceRaised`. One floating bar:
  Approve N, Suspend, Move to…, Delete (coral), clear.
- **Live generation strip.** Pulsing sparkle, "Generating from <note>…", "N new",
  Stop. New rows slide in at the top; counts everywhere come from `DeckCardCounts`
  and move together once a batch is on screen.
- **Empty states.** One action, one quiet way out, no filters or counts. An empty
  deck's single filled yellow button is "Generate questions from your notes".
- **Study sheets** (Learn, Test, flashcards) sit on a near-black scrim, one progress
  bar, answers never replace the question.

## Rules for new screens
1. Reuse tokens and components; add no colour, font or radius without asking.
2. One filled yellow primary per screen; yellow elsewhere only as listed above.
3. The sparkle is for AI only; AI actions are outlined, never filled.
4. Every animation has a Reduce Motion path through `Motion`.
5. Use `GRASPSheet` for popups and `PillMenu` for menus; no system alerts or menus.
6. Text on muted never goes lighter than `textTertiary`.
7. The screen must work at 800 pt wide on the Mac and on an iPhone SE.
