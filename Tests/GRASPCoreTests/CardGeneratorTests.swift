import Testing
import Foundation
@testable import GRASPCore


/// Nothing listens here, so every call fails the way it would with Ollama
/// stopped. (The tests used the default address and failed whenever Ollama
/// was actually running.)
private let unreachableServer = URL(string: "http://127.0.0.1:9")!

@Suite("CardGenerator")
struct CardGeneratorTests {
    @Test("NoGenerator is never available")
    func noGeneratorUnavailable() async {
        #expect(await NoGenerator().isAvailable == false)
    }

    @Test("NoGenerator's refine passes candidates through untouched")
    func noGeneratorPassesThrough() async {
        let candidates = [CandidatePair(front: "Permeability", back: "Ability to transmit fluids", sourceLine: 1)]
        let result = await NoGenerator().refine(candidates, noteContext: "")
        #expect(result == [GeneratedCard(front: "Permeability", back: "Ability to transmit fluids")])
    }

    @Test("NoGenerator's distractors exclude the correct answer")
    func noGeneratorDistractorsExcludeCorrect() async {
        let deck = ["A", "B", "C", "D", "Correct"]
        let picked = await NoGenerator().distractors(for: "Correct", deckContext: deck, count: 3)
        #expect(picked.count == 3)
        #expect(!picked.contains("Correct"))
    }

    @Test("Ollama reports unavailable when no server is running on this machine")
    func ollamaUnavailableWithoutServer() async {
        // A real, non-mocked check that the unavailable path is graceful,
        // against a port nothing listens on -- so it holds whether or not
        // this machine happens to be running Ollama.
        let generator = OllamaGenerator(baseURL: unreachableServer)
        #expect(await generator.isAvailable == false)
    }

    @Test("Ollama's installedModels returns no models when the server is unreachable")
    func ollamaInstalledModelsEmptyWithoutServer() async {
        let models = await OllamaGenerator(baseURL: unreachableServer).installedModels()
        #expect(models.isEmpty)
    }

    @Test("Ollama's refine falls back to untouched candidates when the server is unreachable")
    func ollamaRefineFallsBackWithoutServer() async {
        let candidates = [
            CandidatePair(front: "Porosity", back: "Percentage of open space in a rock sample", sourceLine: 1),
        ]
        let result = await OllamaGenerator(baseURL: unreachableServer).refine(candidates, noteContext: "Some geology notes.")
        #expect(result == [GeneratedCard(front: "Porosity", back: "Percentage of open space in a rock sample")])
    }

    @Test("Ollama's refine prompt asks for exactly the input count, in order")
    func ollamaRefinePromptShape() {
        let candidates = [
            CandidatePair(front: "A", back: "definition a", sourceLine: 1),
            CandidatePair(front: "B", back: "definition b", sourceLine: 2),
        ]
        let prompt = OllamaGenerator.refinePrompt(candidates: candidates, noteContext: "context")
        #expect(prompt.contains("exactly 2 objects"))
        #expect(prompt.contains("front: \"A\""))
        #expect(prompt.contains("front: \"B\""))
    }

    /// A garbled or mislabeled front (extraction noise, or a term that
    /// doesn't match its own back) should be replaceable outright, not
    /// just lightly reworded -- otherwise "Refine with AI" can never
    /// actually fix a wrong term, only polish it.
    @Test("Ollama's refine prompt allows replacing a garbled or mislabeled front entirely")
    func ollamaRefinePromptAllowsFullFrontRename() {
        let prompt = OllamaGenerator.refinePrompt(
            candidates: [CandidatePair(front: "A", back: "definition a", sourceLine: 1)],
            noteContext: "context"
        )
        #expect(prompt.contains("replace it entirely"))
        #expect(prompt.contains("mislabeled"))
    }

    @Test("Ollama's distractor prompt asks for exactly the requested count")
    func ollamaDistractorPromptShape() {
        let prompt = OllamaGenerator.distractorPrompt(correctAnswer: "Permeability", deckContext: ["X", "Y"], count: 3)
        #expect(prompt.contains("Generate 3 plausible"))
        #expect(prompt.contains("Permeability"))
    }

    @Test("NoGenerator proposes no additional cards")
    func noGeneratorGeneratesNothingAdditional() async {
        let candidates = [CandidatePair(front: "Permeability", back: "Ability to transmit fluids", sourceLine: 1)]
        let result = await NoGenerator().generateAdditional(
            existing: candidates, noteContext: "context", maxCount: 3, topic: nil
        )
        #expect(result.isEmpty)
    }

    @Test("Ollama's generateAdditional falls back to an empty array when the server is unreachable")
    func ollamaGenerateAdditionalFallsBackWithoutServer() async {
        let candidates = [CandidatePair(front: "Porosity", back: "Percentage of open space", sourceLine: 1)]
        let result = await OllamaGenerator(baseURL: unreachableServer).generateAdditional(
            existing: candidates, noteContext: "Some geology notes.", maxCount: 3, topic: nil
        )
        #expect(result.isEmpty)
    }

    @Test("Ollama's generateAdditional prompt stays grounded and caps the count")
    func ollamaGenerateAdditionalPromptShape() {
        let existing = [CandidatePair(front: "Porosity", back: "Open space fraction", sourceLine: 1)]
        let prompt = OllamaGenerator.generateAdditionalPrompt(existing: existing, noteContext: "context", maxCount: 2)
        #expect(prompt.contains("at most 2"))
        #expect(prompt.contains("Do not add outside knowledge"))
        #expect(prompt.contains("Porosity: Open space fraction"))
        #expect(prompt.contains("Return {\"items\": []} if there is nothing worth adding"))
    }

    @Test("Ollama's generateAdditional prompt notes when no cards exist yet for this note")
    func ollamaGenerateAdditionalPromptEmptyExisting() {
        let prompt = OllamaGenerator.generateAdditionalPrompt(existing: [], noteContext: "context", maxCount: 3)
        #expect(prompt.contains("(none yet)"))
    }

    @Test("Ollama's generateAdditional prompt steers toward a given topic without dropping the grounding rule")
    func ollamaGenerateAdditionalPromptWithTopic() {
        let existing = [CandidatePair(front: "Porosity", back: "Open space fraction", sourceLine: 1)]
        let prompt = OllamaGenerator.generateAdditionalPrompt(
            existing: existing, noteContext: "context", maxCount: 2, topic: "permeability"
        )
        #expect(prompt.contains("Focus especially on: permeability"))
        #expect(prompt.contains("Do not add outside knowledge"))
    }

    @Test("Ollama's generateAdditional prompt omits the focus line when the topic is blank")
    func ollamaGenerateAdditionalPromptBlankTopic() {
        let prompt = OllamaGenerator.generateAdditionalPrompt(
            existing: [], noteContext: "context", maxCount: 3, topic: "   "
        )
        #expect(!prompt.contains("Focus especially on"))
    }

    @Test("NoGenerator proposes no test questions")
    func noGeneratorGeneratesNoTestQuestions() async {
        let candidates = [CandidatePair(front: "Permeability", back: "Ability to transmit fluids", sourceLine: 1)]
        let result = await NoGenerator().generateTestQuestions(existing: candidates, noteContext: "context", maxCount: 3)
        #expect(result.isEmpty)
    }

    @Test("Ollama's generateTestQuestions falls back to an empty array when the server is unreachable")
    func ollamaGenerateTestQuestionsFallsBackWithoutServer() async {
        let candidates = [CandidatePair(front: "Porosity", back: "Percentage of open space", sourceLine: 1)]
        let result = await OllamaGenerator(baseURL: unreachableServer).generateTestQuestions(
            existing: candidates, noteContext: "Some geology notes.", maxCount: 3
        )
        #expect(result.isEmpty)
    }

    @Test("Ollama's generateTestQuestions prompt stays grounded and caps the count")
    func ollamaGenerateTestQuestionsPromptShape() {
        let existing = [CandidatePair(front: "Porosity", back: "Open space fraction", sourceLine: 1)]
        let prompt = OllamaGenerator.generateTestQuestionsPrompt(existing: existing, noteContext: "context", maxCount: 2)
        #expect(prompt.contains("at most 2"))
        #expect(prompt.contains("Do not add outside knowledge"))
        #expect(prompt.contains("Porosity: Open space fraction"))
        #expect(prompt.contains("prompt\": \"...\", \"answer\": \"...\""))
        #expect(prompt.contains("Return {\"items\": []} if there is nothing worth asking"))
    }

    @Test("Ollama's generateTestQuestions prompt notes when no cards exist yet for this note")
    func ollamaGenerateTestQuestionsPromptEmptyExisting() {
        let prompt = OllamaGenerator.generateTestQuestionsPrompt(existing: [], noteContext: "context", maxCount: 3)
        #expect(prompt.contains("(none yet)"))
    }

    @Test("NoGenerator always calls a definition valid")
    func noGeneratorAlwaysValid() async {
        let result = await NoGenerator().validateContext(
            front: "Abstraction", back: "Submit your answer as a PDF by Friday.",
            noteContext: "Abstraction hides implementation details.", courseName: "Intro to Software Design"
        )
        #expect(result.verdict == .valid)
    }

    @Test("Ollama's validateContext falls back to valid when the server is unreachable")
    func ollamaValidateContextFallsBackWithoutServer() async {
        let result = await OllamaGenerator(baseURL: unreachableServer).validateContext(
            front: "Abstraction", back: "Submit your answer as a PDF by Friday.",
            noteContext: "Abstraction hides implementation details.", courseName: "Intro to Software Design"
        )
        #expect(result.verdict == .valid)
    }

    @Test("Ollama's validateContext prompt names the course and asks for a brand-new definition, not a summary")
    func ollamaValidateContextPromptShape() {
        let prompt = OllamaGenerator.validateContextPrompt(
            front: "Abstraction", back: "See rubric on page 3.",
            noteContext: "Abstraction hides implementation details behind a simple interface.",
            courseName: "Intro to Software Design"
        )
        #expect(prompt.contains("Intro to Software Design"))
        #expect(prompt.contains("See rubric on page 3."))
        #expect(prompt.contains("Do NOT summarize, paraphrase, or shorten"))
        #expect(prompt.contains("\"verdict\": \"reject\""))
        #expect(prompt.contains("Judge the TERM itself, not the quality of its extracted definition"))
    }

    @Test("Foundation Models availability check completes without throwing, regardless of Apple Intelligence state")
    func foundationModelsAvailabilityIsSafeToCheck() async {
        if #available(macOS 26.0, *) {
            let generator = FoundationModelsGenerator()
            _ = await generator.isAvailable // must not crash either way
        }
    }

    @Test("selecting a generator on this machine falls back to NoGenerator or an honestly-available one")
    func selectReturnsAnAvailableOrNoGenerator() async {
        let generator = await CardGenerators.select()
        // Whatever was selected must itself report consistently: either
        // it's the explicit no-op, or it claims to actually be available.
        if generator is NoGenerator {
            #expect(Bool(true))
        } else {
            #expect(await generator.isAvailable)
        }
    }

    // MARK: - Overview generation

    @Test("no generator means no overview and no diagram, never a fabricated one")
    func noGeneratorProducesNothing() async {
        let generator = NoGenerator()
        let overview = await generator.generateOverview(
            noteTitle: "L", courseName: "Biology", noteContext: "text",
            includeFormulas: true, partLabel: nil
        )
        #expect(overview == .empty)
        #expect(await generator.generateDiagram(
            noteTitle: "L", courseName: "Biology", conceptOutline: "outline"
        ) == "")
    }

    @Test("Ollama returns an empty overview rather than throwing when no server is running")
    func ollamaOverviewIsSafeWithoutAServer() async {
        let generator = OllamaGenerator(baseURL: URL(string: "http://127.0.0.1:1")!)
        let overview = await generator.generateOverview(
            noteTitle: "L", courseName: "Biology", noteContext: "text",
            includeFormulas: false, partLabel: nil
        )
        #expect(overview == .empty)
    }

    @Test("the overview prompt asks the model to teach, not to summarise")
    func overviewPromptShape() {
        let prompt = OllamaGenerator.overviewPrompt(
            noteTitle: "Cell Cycle", courseName: "Biology 101",
            noteContext: "Mitosis has four phases.", includeFormulas: true, partLabel: nil
        )
        #expect(prompt.contains("Biology 101"))
        #expect(prompt.contains("Cell Cycle"))
        #expect(prompt.contains("single line of plain text"))
        #expect(prompt.contains("No other text."))
    }

    @Test("the overview prompt licenses explanation and forbids restating the notes")
    func overviewPromptTeaches() {
        // The first version of this shipped with the flashcard prompts'
        // grounding rules, which are right for a card you memorise and
        // exactly wrong for an overview you read: the result was a
        // reformatted copy of the student's own notes. These are the two
        // halves of the boundary that replaced it -- free to explain, not
        // free to wander onto new topics.
        let prompt = OllamaGenerator.overviewPrompt(
            noteTitle: "L", courseName: "Biology", noteContext: "text",
            includeFormulas: false, partLabel: nil
        )
        #expect(prompt.contains("You may draw on what you know about the subject"))
        #expect(prompt.contains("Do not introduce concepts the note never raises"))
        #expect(prompt.contains("could be pasted into the notes without anyone noticing"))
        // The grounding phrasing carried over from the card prompts must
        // not creep back in.
        #expect(!prompt.contains("Do not add outside knowledge"))
    }

    @Test("the overview prompt carries the whole note, never a truncated slice")
    func overviewPromptIsNotTruncated() {
        // A regression guard, not a style check. Every other prompt here
        // caps its context with `.prefix(N)`; doing that to a whole-note
        // overview would silently summarise the first third of a lecture
        // and present it as the lecture. `OverviewChunker` is what keeps
        // the input small, and it has to stay that way.
        let context = String(repeating: "word ", count: 4_000)
        let prompt = OllamaGenerator.overviewPrompt(
            noteTitle: "L", courseName: "Biology", noteContext: context,
            includeFormulas: false, partLabel: nil
        )
        #expect(prompt.contains(context))
    }

    @Test("the overview prompt hides the formulas section for a note with no math")
    func overviewPromptOmitsFormulas() {
        let without = OllamaGenerator.overviewPrompt(
            noteTitle: "L", courseName: "Biology", noteContext: "text",
            includeFormulas: false, partLabel: nil
        )
        #expect(!without.contains("formulas"))

        let with = OllamaGenerator.overviewPrompt(
            noteTitle: "L", courseName: "Biology", noteContext: "text",
            includeFormulas: true, partLabel: nil
        )
        #expect(with.contains("formulas"))
    }

    @Test("the overview prompt says which piece of a long note it is showing, only when it is one")
    func overviewPromptPartLabel() {
        let part = OllamaGenerator.overviewPrompt(
            noteTitle: "L", courseName: "Biology", noteContext: "text",
            includeFormulas: false, partLabel: "part 2 of 5"
        )
        #expect(part.contains("part 2 of 5"))
        #expect(part.contains("do not try to cover the whole note here"))

        let whole = OllamaGenerator.overviewPrompt(
            noteTitle: "L", courseName: "Biology", noteContext: "text",
            includeFormulas: false, partLabel: nil
        )
        #expect(!whole.contains("one piece of it"))
    }

    @Test("the diagram prompt constrains the model to the subset the parser reads")
    func diagramPromptShape() {
        let prompt = OllamaGenerator.diagramPrompt(
            noteTitle: "Cell Cycle", courseName: "Biology 101", conceptOutline: "- Mitosis"
        )
        #expect(prompt.contains("graph TD"))
        #expect(prompt.contains("graph LR"))
        #expect(prompt.contains("mindmap"))
        #expect(prompt.contains("Do not write subgraph"))
        #expect(prompt.contains("between 4 and 12 boxes"))
        #expect(prompt.contains("NONE"))
        #expect(prompt.contains("No other text."))
    }

    @Test("the diagram prompt never shows a placeholder a model could copy literally")
    func diagramPromptHasNoCopyablePlaceholder() {
        // A real 7B read "A node is written id[Label]" and used `id` as the
        // actual name of every box. They all collapsed into one node, every
        // edge became a self-loop, and the concept map rendered as a single
        // rectangle in an empty frame. The fix is a worked example with
        // distinct, meaningful names and an explicit ban.
        let prompt = OllamaGenerator.diagramPrompt(
            noteTitle: "L", courseName: "Biology", conceptOutline: "- A"
        )
        #expect(!prompt.contains("id[Label]"))
        #expect(prompt.contains("never use the word \"id\" as a name"))
        #expect(prompt.contains("Give every box a different name"))
        #expect(prompt.contains("Never link a box to itself"))
        // A complete, correct example the model can pattern-match against.
        #expect(prompt.contains("scarcity[Wants exceed resources]"))
    }

    @Test("salvages JSON out of a fence or a preamble, and leaves clean JSON alone")
    func salvageJSON() {
        #expect(OllamaGenerator.salvageJSON("{\"a\": 1}") == "{\"a\": 1}")
        #expect(OllamaGenerator.salvageJSON("```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
        #expect(OllamaGenerator.salvageJSON("```\n[1, 2]\n```") == "[1, 2]")
        #expect(OllamaGenerator.salvageJSON("Here is the JSON: {\"a\": 1}") == "{\"a\": 1}")
        #expect(OllamaGenerator.salvageJSON("  [{\"a\": 1}]  ") == "[{\"a\": 1}]")
    }

    @Test("returns unsalvageable text untouched so it fails the decode exactly as before")
    func salvageJSONLeavesGarbageAlone() {
        #expect(OllamaGenerator.salvageJSON("") == "")
        #expect(OllamaGenerator.salvageJSON("no json here") == "no json here")
        #expect(OllamaGenerator.salvageJSON("{unclosed") == "{unclosed")
    }

    @Test("salvages Mermaid from a fence, a preamble, or not at all")
    func salvageMermaid() {
        #expect(OllamaGenerator.salvageMermaid("graph TD\nA-->B") == "graph TD\nA-->B")
        #expect(OllamaGenerator.salvageMermaid("```mermaid\ngraph TD\nA-->B\n```") == "graph TD\nA-->B")
        #expect(OllamaGenerator.salvageMermaid("Sure! Here you go:\ngraph TD\nA-->B") == "graph TD\nA-->B")
        #expect(OllamaGenerator.salvageMermaid("mindmap\n  Root") == "mindmap\n  Root")
        // The explicit "nothing worth drawing" answer, and an apology with
        // no diagram in it, both mean the same thing to a caller.
        #expect(OllamaGenerator.salvageMermaid("NONE") == "")
        #expect(OllamaGenerator.salvageMermaid("I'm sorry, I can't do that.") == "")
        #expect(OllamaGenerator.salvageMermaid("") == "")
    }

    @Test("an unreadable overview response is empty, not a crash")
    func parseOverviewResponseFailure() {
        #expect(OllamaGenerator.parseOverviewResponse("not json") == .empty)
        #expect(OllamaGenerator.parseOverviewResponse("") == .empty)
    }

    // MARK: - Lesson shape

    @Test("the overview prompt asks for the 3Blue1Brown voice and claim headings")
    func overviewPromptVoice() {
        let prompt = OllamaGenerator.overviewPrompt(
            noteTitle: "L", courseName: "Linear Algebra", noteContext: "text",
            includeFormulas: false, partLabel: nil
        )
        #expect(prompt.contains("3Blue1Brown"))
        #expect(prompt.contains("concrete case with real numbers before the general rule"))
        #expect(prompt.contains("Every section heading is a full claim"))
        // The in-prompt example must be from a different course, or a 7B
        // copies it into every lesson regardless of subject.
        #expect(prompt.contains("A free parking pass still has a price"))
    }

    @Test("reads a lesson response through the whole tolerance path")
    func parseLessonResponse() {
        let document = OllamaGenerator.parseOverviewResponse("""
            ```json
            {"title": "Row operations never move the answer",
             "hook": "Why can we rewrite a system and still trust it?",
             "objectives": ["Perform a row replacement."],
             "sections": [{"heading": "Swapping equations cannot change the answer",
                           "paragraphs": ["Try it.", "Nothing moved."],
                           "terms": [{"term": "Interchange", "definition": "Swap two rows."}],
                           "check": {"question": "Why?", "answer": "Same facts."}}],
             "takeaways": ["Row operations preserve solutions."]}
            ```
            """)
        #expect(document.title == "Row operations never move the answer")
        #expect(document.hook == "Why can we rewrite a system and still trust it?")
        #expect(document.objectives == ["Perform a row replacement."])
        #expect(document.sections.first?.paragraphs.count == 2)
        #expect(document.sections.first?.terms.first?.term == "Interchange")
        #expect(document.sections.first?.check?.answer == "Same facts.")
        #expect(document.takeaways.count == 1)
        #expect(document.formulas.isEmpty)
    }

    @Test("drops a section missing its heading or its prose, not the whole lesson")
    func parseLessonTolerance() {
        let document = OllamaGenerator.parseOverviewResponse("""
            {"sections": [{"heading": "Good", "paragraphs": ["Explained."]},
                          {"heading": "No body", "paragraphs": []},
                          {"paragraphs": ["No heading"]}]}
            """)
        #expect(document.sections.map(\.heading) == ["Good"])
    }

    @Test("drops a check whose answer is missing, rather than showing a bare question")
    func checkNeedsAnAnswer() {
        let document = OllamaGenerator.parseOverviewResponse("""
            {"sections": [{"heading": "A", "paragraphs": ["B"], "check": {"question": "Why?"}}]}
            """)
        #expect(document.sections.first?.check == nil)
        #expect(document.sections.count == 1)
    }

    @Test("collapses a newline the model slipped in despite being told not to")
    func parseLessonCollapsesNewlines() {
        let document = OllamaGenerator.parseOverviewResponse(
            "{\"sections\": [{\"heading\": \"A\", \"paragraphs\": [\"First.\\nSecond.\"]}]}"
        )
        #expect(document.sections.first?.paragraphs.first == "First. Second.")
    }

    // MARK: - Figures pass

    @Test("the figures prompt asks for numbers only, with an example from a different system")
    func figuresPromptShape() {
        let prompt = OllamaGenerator.figuresPrompt(
            noteTitle: "L", courseName: "Linear Algebra",
            noteContext: "x + 5y = 7 and 2x + y = 5", sectionHeadings: ["First claim", "Second claim"]
        )
        #expect(prompt.contains("1. First claim"))
        #expect(prompt.contains("2. Second claim"))
        #expect(prompt.contains("systemOfLines"))
        #expect(prompt.contains("linearTransform"))
        #expect(prompt.contains("do not invent them"))
        #expect(prompt.contains("never these"))
        #expect(prompt.contains("No other text."))
    }

    @Test("reads a figure, including fractions written as strings")
    func parseFigures() {
        let figures = OllamaGenerator.parseFiguresResponse("""
            {"figures": [{"section": 2, "kind": "systemOfLines", "caption": "Watch it.",
              "equations": [[1, 5, 7], [2, 1, 5]],
              "steps": [{"op": "replace", "target": 2, "source": 1, "multiplier": -2},
                        {"op": "scale", "target": 2, "multiplier": "-1/9"}]}]}
            """, sectionCount: 3)
        #expect(figures.count == 1)
        let figure = try! #require(figures.first)
        #expect(figure.sectionIndex == 1)
        #expect(figure.figure.steps?.count == 2)
        #expect(abs((figure.figure.steps?[1].multiplier ?? 0) - (-1.0 / 9)) < 1e-9)
    }

    @Test("drops figures that point at a missing section, use an unknown kind, or double up")
    func parseFiguresRejects() {
        let figures = OllamaGenerator.parseFiguresResponse("""
            {"figures": [
              {"section": 9, "kind": "systemOfLines", "equations": [[1, 1, 3], [1, -1, 1]]},
              {"section": 1, "kind": "pieChart"},
              {"section": 1, "kind": "linearTransform", "matrix": [[2, 1], [0, 1]]},
              {"section": 1, "kind": "linearTransform", "matrix": [[1, 0], [0, 1]]}
            ]}
            """, sectionCount: 2)
        #expect(figures.count == 1)
        #expect(figures.first?.figure.kind == .linearTransform)
    }

    @Test("drops a figure whose numbers aren't drawable")
    func parseFiguresValidates() {
        let figures = OllamaGenerator.parseFiguresResponse("""
            {"figures": [{"section": 1, "kind": "systemOfLines", "equations": [[1, 1, 3]]}]}
            """, sectionCount: 1)
        #expect(figures.isEmpty)
    }

    @Test("an unreadable figures response is empty, not a crash")
    func parseFiguresFailure() {
        #expect(OllamaGenerator.parseFiguresResponse("nope", sectionCount: 3).isEmpty)
        #expect(OllamaGenerator.parseFiguresResponse("{\"figures\": []}", sectionCount: 3).isEmpty)
    }

    @Test("no generator means no figures")
    func noGeneratorNoFigures() async {
        let figures = await NoGenerator().generateFigures(
            noteTitle: "L", courseName: "C", noteContext: "x", sectionHeadings: ["A"]
        )
        #expect(figures.isEmpty)
    }

    // MARK: - Model choice

    @Test("uses the student's chosen model when it's installed")
    func modelChoiceHonoursPreference() {
        #expect(OllamaModelChoice.resolve(
            preferred: "qwen2.5:7b-instruct", installed: ["qwen3.5:9b", "qwen2.5:7b-instruct"]
        ) == "qwen2.5:7b-instruct")
    }

    @Test("falls back to the best recommended model when the choice was removed")
    func modelChoiceFallsBack() {
        #expect(OllamaModelChoice.resolve(
            preferred: "gone:1b", installed: ["qwen2.5:7b-instruct", "qwen3.5:9b"]
        ) == "qwen3.5:9b")
    }

    @Test("uses whatever is installed when nothing recommended is")
    func modelChoiceUsesAnything() {
        #expect(OllamaModelChoice.resolve(preferred: nil, installed: ["llama3.1:8b"]) == "llama3.1:8b")
        #expect(OllamaModelChoice.resolve(preferred: nil, installed: []) == nil)
    }

    @Test("a heading reads as a claim only when it states something")
    func readsAsClaim() {
        #expect(OllamaGenerator.readsAsClaim("Three moves rewrite a system without changing its answer.")
            == "Three moves rewrite a system without changing its answer")
        #expect(OllamaGenerator.readsAsClaim("Augmented Matrices") == nil)
        #expect(OllamaGenerator.readsAsClaim("What is a system of linear equations?") == nil)
        #expect(OllamaGenerator.readsAsClaim("The power of row operations in practice") == nil)
    }

    @Test("reads a list whatever shape it arrives in")
    func decodesListShapes() {
        struct Pair: Decodable, Equatable { let front: String; let back: String }
        let wrapped = #"{"items": [{"front": "A", "back": "1"}, {"front": "B", "back": "2"}]}"#
        let bare = #"[{"front": "A", "back": "1"}]"#
        // What JSON mode actually returns when asked for an array: one element.
        let lone = #"{"front": "A", "back": "1"}"#
        let otherKey = #"{"cards": [{"front": "A", "back": "1"}]}"#
        #expect(OllamaGenerator.decodeList(Pair.self, from: wrapped)?.count == 2)
        #expect(OllamaGenerator.decodeList(Pair.self, from: bare) == [Pair(front: "A", back: "1")])
        #expect(OllamaGenerator.decodeList(Pair.self, from: lone) == [Pair(front: "A", back: "1")])
        #expect(OllamaGenerator.decodeList(Pair.self, from: otherKey) == [Pair(front: "A", back: "1")])
        #expect(OllamaGenerator.decodeList(String.self, from: #"{"items": ["x", "y"]}"#) == ["x", "y"])
        #expect(OllamaGenerator.decodeList(Pair.self, from: "not json") == nil)
    }
}
