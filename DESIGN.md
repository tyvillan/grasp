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
- **Deck tabs.** Overview, Cards, Questions, in that order, as one segmented
  control (Mac: capsule buttons that become icons under about 640 pt of pane; iPhone:
  full-width segments). Overview appears only for a deck with source notes. The last
  tab used is remembered across decks and launches; Cards the first time.
- **Questions tab.** Cards are for remembering, questions are for practicing like
  the exam; the empty state says so in one line and offers one quiet "Write a
  question" button. A row is the prompt (two lines), then a source badge, the
  question's type, and its history ("Right 2 of the last 3", or "Not asked yet").
  The badge is "Yours", "From a photo" or "AI", and only AI carries the sparkle.
  Suspended rows sink to the bottom with a red "Suspended"; a draft says "Draft".
  No Learn ladder or understanding meter on a question: a question linked to a card
  moves that card's meter when it is answered in a test, and never its flashcard
  schedule. The Add menu is an outlined button (Study stays the one yellow button):
  Write a question, then two disabled items marked "(coming soon)", with no sparkle
  while they cannot be used.
- **Generate questions with AI.** Lives on the Questions tab only (the Add menu item,
  the one place its sparkle appears there; disabled with a reason when no model is set
  up). The sheet lists the deck's source notes (all on), how many (10), and the kinds:
  multiple choice and written, true / false shown off with "Not written by AI yet", and
  code or math kinds only for a note that is code or math and only where the Mac can
  check them. It says in plain words when Cloud sends the notes' text to Google. Results
  land as drafts, local to the device until approved: a "To review" filter with a count
  (a number beside the tab on the Mac, "Questions 4" on the iPhone), each draft showing
  "From <note>", with Approve, Edit and Delete, and "Approve all", which approves only
  drafts that pass every check. A run ends with a banner ("Wrote 7 draft questions") and,
  when something was dropped, "3 dropped: 2 repeats, 1 unclear" with "See why". Drafts
  never count toward the card draft number. The model line and the Google line sit at
  the top of the sheet, above the notes, so they are seen before the button. A draft
  that fails a check on Approve all stays under To review with the reason on its row.
  "What was dropped" scrolls inside its sheet. The deck tabs keep their words at 800 pt
  even with the draft count (a tighter padding step before falling back to icons).
  Debug builds with `-GRASPAllowStubs 1` and `GRASP_STUB_QUESTIONS=1` never read the
  Keychain (`AIKeyStore.skipsKeychain`), so demo and screenshot runs cannot raise a
  password prompt.
- **Select, move and copy.** A "Select" button above the list turns on select mode: a
  tick circle in front of each row, a bar with Done, the count, All and an Actions menu
  (Approve for drafts, Move to deck, Copy to deck, Suspend, Reactivate, Delete). On the
  Mac the bar stays at the top while the list scrolls; on the iPhone it scrolls with the
  list (the tab sits in a List row, where a pinned header does not work). Each row's menu
  also has Move to deck and Copy to deck. The picker lists the other decks of the same
  course. A moved question keeps its history, source and status; a copy is new, with no
  history, and is skipped if the deck already has that question word for word.
- **From a photo (branch `photo-import`).** The Add menu's "From a photo"
  opens a sheet to choose pictures (Library and camera on the iPhone; Choose Images and
  Paste on the Mac). Text is read on the device with Vision, split into questions, and
  saved as drafts under To review with source "From a photo". An answer the page prints
  is kept as printed; one it does not print is written by AI and marked "answer written
  by AI: check it", which Approve all skips. The picture is a small JPEG row that stays
  on the device until its question is approved. A draft row shows a small thumbnail of its photo (tap to enlarge)
  and "Check the answer" when the AI wrote the answer; the editor shows the photo above the fields.
  A title above the first numbered question is ignored (one line, two lines, or a course
  code and date).
  The reader turns a sideways or upside-down photo upright (it tries the four ways up and
  keeps the one whose numbers count up), reads a tilted page line by line, and stores the
  upright picture. A draft's thumbnail is cropped to its own question (Vision gives each
  line's box; `testQuestion.imageCrop` holds "x,y,width,height" as page fractions) and
  the viewer shows the whole page with that question framed. A photo that starts partway
  through a question (options or an answer with no question above) is joined onto the
  question at the end of the photo before it; alone, it is reported as starting partway.
  Notes with no question in them make no question and say so. A photo the reader is unsure of
  (low confidence, or many words the spell checker does not know, as with handwriting)
  marks every draft from it "Check the wording", and Approve all skips them.
- **Test sources.** Test setup has two independent switches under the question
  types: "Quiz me on flashcards" and "Include questions". With both on, saved
  questions are about a third of the test; with only questions on, the whole test.
  A deck with no cards starts a questions-only test: the flashcards switch is off and
  disabled with "This deck has no cards." Test is dimmed only when a deck has neither
  cards nor saved questions, with the reason in the muted line under the pills.
  Neither switch on says "Turn on flashcards or questions to start a test." and disables
  Start. "Include AI-written questions" stays as a sparkle option that goes with
  the flashcards.
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
  sidebar's coloured dots. Shape carries the meaning and colour reinforces it,
  and the whole meter takes the colour of the stage reached: **recognition a
  light gray** (lighter than a draft's rail, so the two never read alike),
  **recall yellow** (`accent`, an exception Tyler asked for to the yellow budget),
  **understood green** (`success`). A **dashed** gray outline is self-rated ("I
  Know This", not yet shown): two dashed capsules and one empty, completed by one
  right answer. An **outline** is not reached (`hairlineStrong` for a card nobody
  has asked about, which reads "New"; a firmer outline for a card asked and
  missed). A **suspended** card shows its meter in coral. "Understood" means
  mastered only: self-rated is never counted as understood, in the pips, the
  deck bar, the "Understood N" pill and the preview chip alike. A card moves on
  the ladder by Learn answers and by Test answers on card questions (same rules;
  AI-written and bank questions have no card). It drops a level only after two
  misses in a row (the first is remembered, a right answer clears it). A row
  with any Learn progress does not say "New" on the right. Learn shows the card
  after an answer, using the ladder's own rules: the single current state when
  the level did not change ("Missed once..." after a first miss), or the pips
  before, an arrow and the pips after with one line when it did, fading in over
  0.20 s (`Motion.base`) and instant under Reduce Motion. The deck page shows the
  same steps as one stacked bar (understood green, recall yellow, recognition
  light gray, self-rated with a dashed edge, not asked as an outlined track), a
  count line, the five weakest notes (title from the note's first heading, else
  its humanized file name; mini bar under the name, "3 of 14 understood" on the
  right; tapping one filters the list) and an outlined "Practice weakest"
  button. On the iPhone the notes list sits behind a disclosure, closed by
  default. The same colours appear everywhere a card or deck shows how well it
  is known: card rows, the Study corner, the Learn feedback and its progress bars
  (the stacked bar, not a single teal bar), each deck's row in the deck list (a
  4 pt bar under the name), the card preview pane, and each card question on the
  Test results. VoiceOver reads "Recall, 2 of 3 steps", "Understood, 3 of 3 steps",
  "Self-rated, not yet tested", "New".
- **Learn comebacks.** Up to three of a round's seven questions bring back a card you answered before once it has rested: an understood card after a day, then 3, 7 and 14 days as it keeps passing; a card still being learned after 20 minutes, then a day, then 3 days (a remembered miss, 10 minutes). Such a question has one muted line above the prompt ("Checking a card you understood" or "Coming back to a card you answered before"), is asked at the card's own level, and moves the card by the usual rules.
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

- **Learn streak.** From the third right answer in a row, a flame banner
  ("3 correct in a row") appears under the answer and a flame chip with the count
  sits in the header; each further right answer updates it, and the first miss
  ends it ("Streak ended at N"). It is saved in the synced `learnStreak` row (newest write wins), so it carries between visits and between the Mac and iPhone, and ends only on a miss.
  One 0.32 s entrance (flame scales in, six embers rise once and fade); under
  Reduce Motion the flame only fades in. Flame and embers use `accent` and
  `brand`, no new colour. Rule lives in `LearnStreak` (core).

- **First-run tutorial** (`Sources/GRASP/Shared/Tutorial/`, shared by the Mac and iPhone).
  It points at the real controls and never draws a copy. Three parts:
  - **Dim.** The window goes to black at 62% with a rounded hole over the control
    (`SpotlightShape`, even-odd fill) and a 2 pt cream ring (`textPrimary`) 6 pt
    outside it. The dim swallows every tap, so nothing behind it can change. Only
    on a step that waits for a real tap (the deck tabs) is the lit area left open,
    and only for navigation. The hole moves at `Motion.thumb` and the dim fades at
    `Motion.base`, so under Reduce Motion both are instant.
  - **Coach card.** A `surface` card, 14 pt radius, hairline border, no shadow, at most
    360 pt wide. Top to bottom: "Step 3 of 8" (meta), title (title), one or two lines
    (body), the AI line with the sparkle only on the AI step, "Tap Cards." while a step
    waits, then buttons. Skip and Back are outlined (`GRASPQuietButton`); Next, Start
    and Done are the one filled yellow primary (`GRASPProminentButton`). Next is hidden
    while a step waits for a tap. The card goes in the largest open space beside the lit
    control, so it never covers it, and scrolls inside that space if the text is long.
  - **Fallback.** When the control is not on screen (a first-time user has no course, so
    no deck page, or it has scrolled off), the step is a plain card with the real icon
    in a small `inset` tile and "Once you add a course you'll see this." It never waits.
  A control opts in with `.tutorialTarget(_)`. On the iPhone the Import Notes and Add
  buttons live in the navigation bar, which reports no position, so
  `.tutorialTrailingBarTarget(_, width:)` points at the bar's right edge instead.
  The steps are data (`TutorialSteps`), with the wording in one place. The tour only
  navigates and highlights: it never imports, generates or writes, and the one thing it
  saves is its own "seen" flag in the profile's preferences. Mac keys: Return or Right
  arrow is Next, Left arrow is Back, Escape is Skip. VoiceOver focuses the card and reads
  the step; the lit control keeps its own label.

- **Send feedback** (`Sources/GRASP/Shared/Feedback/`, Mac and iPhone). A `GRASPSheet`
  opened from the footer of the sidebar, just above the profile button (Mac), the top right of Settings (iPhone), Help > Send feedback (Mac) and the soft asks. Top to bottom: what
  kind (Bug, Confusing, Idea, Love it, in a `GRASPSegmented`), an optional 1 to 5 rating
  in round pills (tap again to clear), the message with a counter that appears at 3,600 of
  4,000, "Send anonymously" (on by default; off adds an optional Name and Email with "So
  Tyler can ask you a follow-up."), an optional screenshot (Choose image and Capture this
  window on the Mac, Photos on the iPhone) with a preview, Remove, and one plain warning
  that a screenshot can show notes and cards, and a collapsible "What gets sent" listing
  exactly the seven facts attached. Cancel is outlined, Send is the one yellow button,
  and there is no sparkle. A Mac sheet scrolls inside 350 pt so it fits a short window.
  After sending the sheet says "Thanks. Your feedback was sent." or, when the network is
  down, "Saved. It will send when you're online." with Done as the yellow button. At 5
  sends a day Send is disabled and the footer says so.
- **Soft asks.** A small `surface` card with one line and three outlined buttons (Send
  feedback, Not now, Don't ask again). It floats at the bottom right on the Mac and sits
  just above the tab bar on the iPhone. It is non-blocking, never uses yellow, never
  appears during Study, Learn, a Test or the tutorial, and never over a sheet. Two asks
  only, each shown once ever per device: after the first finished Test, and 7 days after
  first launch. Any choice ends that ask for good; "Don't ask again" ends both.

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
