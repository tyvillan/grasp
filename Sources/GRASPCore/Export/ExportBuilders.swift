import Foundation

/// An exam's study page as a document to print or share.
public enum StudyGuideExport {
    /// The page as the app shows it: guides merged, each shared problem
    /// once. Practice problems are numbered through the whole document;
    /// with `answerKey`, their answers follow at the end, after a rule, so
    /// working the problems doesn't show them.
    public static func document(page: StudyGuideActions.ExamPage, deckNames: [String: String],
                                answerKey: Bool, calendar: Calendar = .current) -> ExportDocument {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        var facts = [formatter.string(from: page.exam.startsAt)]
        facts += page.format.isEmpty ? page.questionCount.map { ["\($0) questions"] } ?? [] : page.format

        var document = ExportDocument(title: page.exam.title, subtitle: facts.joined(separator: " · "))
        var answers: [ExportDocument.Block] = []
        var number = 0

        for part in page.parts {
            let heading = [part.number.map { "Part \($0)" }, part.title].compactMap { $0 }.joined(separator: " · ")
            document.blocks.append(.heading(heading, level: 1))
            var facts: [String] = []
            if let count = part.questionCount {
                facts.append(page.questionCount.map { "\(count) of \($0) questions" } ?? "\(count) questions")
            }
            let decks = part.deckIds.compactMap { deckNames[$0] }
            if !decks.isEmpty { facts.append("Covers " + decks.joined(separator: ", ")) }
            if !facts.isEmpty { document.blocks.append(.note(facts.joined(separator: " · "))) }

            if !part.skills.isEmpty {
                document.blocks.append(.heading("You should be able to", level: 2))
                document.blocks.append(.bullets(part.skills.map { skill in
                    unbulleted(skill.text) + (skill.rating.map { " *(\(ratingName($0)))*" } ?? "")
                }))
            }
            if !part.traps.isEmpty {
                document.blocks.append(.callout(label: "Traps the wrong answers are built on",
                                                lines: part.traps.map(unbulleted)))
            }
            if !part.terms.isEmpty {
                document.blocks.append(.heading("Key terms", level: 2))
                document.blocks.append(.bullets(part.terms.map { "**\($0.term):** \($0.definition)" }))
            }
            if !part.formulas.isEmpty {
                document.blocks.append(.heading("Formulas", level: 2))
                document.blocks.append(.bullets(part.formulas))
            }
            if !part.remember.isEmpty {
                document.blocks.append(.callout(label: "Remember", lines: part.remember.map(unbulleted)))
            }
            document.blocks += part.notes.map { .paragraph($0) }

            if part.examples.contains(where: \.example.isPractice) {
                document.blocks.append(.heading("Practice", level: 2))
                // Numbered through the document; the guides' own "Example
                // N" labels would be a second, clashing numbering.
                for item in part.examples where item.example.isPractice {
                    let example = item.example
                    number += 1
                    let guide = page.guides.first { $0.id == item.guideId }?.title
                    let hint = example.usesFigure == true
                        ? example.page.map { page in
                            "Uses a table or figure on page \(page)" + (guide.map { " of “\($0)”" } ?? "") + "."
                        }
                        : nil
                    document.blocks.append(.problem(number: number, label: nil,
                                                    question: example.question, hint: hint))
                    if answerKey {
                        answers.append(.answer(number: number, label: nil,
                                               steps: example.steps.map(unbulleted), answer: example.answer))
                    }
                }
            }
            let illustrations = part.examples.map(\.example).filter { !$0.isPractice }
            if !illustrations.isEmpty {
                document.blocks.append(.heading("Examples", level: 2))
                document.blocks += illustrations.map { .paragraph($0.question) }
            }
        }

        if !answers.isEmpty {
            document.blocks.append(.pageBreak)
            document.blocks.append(.heading("Answer key", level: 1))
            document.blocks += answers
        }
        return document
    }

    /// A list item without the bullet the guide's text already had.
    static func unbulleted(_ text: String) -> String {
        text.hasPrefix("• ") ? String(text.dropFirst(2)) : text
    }

    static func ratingName(_ rating: SkillConfidence) -> String {
        switch rating {
        case .canDoCold: return "can do cold"
        case .shaky: return "shaky"
        case .cantYet: return "can't yet"
        }
    }
}

/// A deck's overview, or one lesson of it, as a document.
public enum OverviewExport {
    /// One lesson reads as the document itself; several get a heading each
    /// under the deck's name.
    public static func document(entries: [RenderedOverview], title: String) -> ExportDocument {
        if entries.count == 1, let only = entries.first {
            var document = ExportDocument(title: only.title, subtitle: only.kicker)
            document.blocks = lesson(only, level: 1)
            return document
        }
        var document = ExportDocument(title: title, subtitle: "\(entries.count) lessons")
        for entry in entries {
            if let kicker = entry.kicker { document.blocks.append(.note(kicker)) }
            document.blocks.append(.heading(entry.title, level: 1))
            document.blocks += lesson(entry, level: 2)
        }
        return document
    }

    static func lesson(_ overview: RenderedOverview, level: Int) -> [ExportDocument.Block] {
        var blocks: [ExportDocument.Block] = []
        if let hook = overview.hook { blocks.append(.paragraph(hook)) }
        if !overview.objectives.isEmpty {
            blocks.append(.callout(label: "By the end you should be able to", lines: overview.objectives))
        }
        for section in overview.sections {
            func text(_ string: String) -> String { section.isMath ? MathNotation.prettify(string) : string }
            blocks.append(.heading(text(section.heading), level: level))
            blocks += section.paragraphs.map { .paragraph(text($0)) }
            if let code = section.code { blocks.append(.code(code.code, language: code.language)) }
            if !section.terms.isEmpty {
                blocks.append(.callout(label: "Key terms", lines: section.terms.map { term in
                    var line = "**\(term.term)**: \(text(term.text))"
                    if let example = term.example { line += " *Is:* \(text(example))." }
                    if let nonExample = term.nonExample { line += " *Isn't:* \(text(nonExample))." }
                    return line
                }))
            }
            if let figure = section.figure { blocks += self.figure(figure) }
            if let example = section.example {
                blocks.append(.heading("Worked example" + (example.title.map { ": \(text($0))" } ?? ""), level: level + 1))
                if let setup = example.setup { blocks.append(.paragraph(text(setup))) }
                blocks.append(.numbered(example.steps.map { step in
                    text(step.action) + (step.result.map { " → `\(text($0))`" } ?? "")
                        + (step.why.map { " (\(text($0)))" } ?? "")
                }))
                if let outcome = example.outcome { blocks.append(.paragraph(text(outcome))) }
            }
            if let check = section.check {
                blocks.append(.callout(label: "Pause and check",
                                       lines: [text(check.question), "*Answer:* " + text(check.answer)]))
            }
        }
        if !overview.formulas.isEmpty {
            blocks.append(.heading("Formulas", level: level))
            blocks.append(.bullets(overview.formulas.map { formula in
                "**\(formula.name):** \(formula.plain)" + (formula.meaning.map { " (\($0))" } ?? "")
            }))
        }
        if !overview.takeaways.isEmpty {
            blocks.append(.heading("Key takeaways", level: level))
            blocks.append(.bullets(overview.takeaways))
        }
        // Obsidian draws a Mermaid block as the diagram; a PDF shows it as
        // text, which still reads as the map's links.
        if let mermaid = overview.mermaidSource, !mermaid.isEmpty {
            blocks.append(.heading("Concept map", level: level))
            blocks.append(.code(mermaid, language: "mermaid"))
        }
        return blocks
    }

    /// Figures as what text can carry: a row reduction step by step with
    /// each matrix as a table, two lines as their equations, a transform as
    /// its matrix. The drawn versions stay in the app.
    static func figure(_ figure: RenderedFigure) -> [ExportDocument.Block] {
        var blocks: [ExportDocument.Block] = []
        if let caption = figure.caption { blocks.append(.note(caption)) }
        switch figure {
        case .rowReduction(let walk):
            for (index, state) in walk.states.enumerated() {
                if index > 0 { blocks.append(.paragraph(OverviewFigures.label(walk.steps[index - 1]))) }
                let bar = state.augmentedColumns > 0 ? state.coefficientColumns : nil
                blocks.append(.table(rows: state.rows.map { $0.map(\.description) }, bar: bar))
            }
        case .lines(let lines):
            for (index, state) in lines.states.enumerated() {
                if index > 0 { blocks.append(.paragraph(OverviewFigures.label(lines.steps[index - 1]))) }
                blocks.append(.bullets(state.rows.map(equation)))
            }
        case .transform(let transform):
            blocks.append(.table(rows: transform.matrix.rows.map { $0.map(OverviewFigures.format) }, bar: nil))
        }
        return blocks
    }

    /// `2x − y = 3` from `[2, -1, 3]`.
    static func equation(_ row: [Double]) -> String {
        guard row.count == 3 else { return row.map(OverviewFigures.format).joined(separator: " ") }
        func term(_ value: Double, _ variable: String, first: Bool) -> String? {
            guard abs(value) > 1e-9 else { return nil }
            let magnitude = abs(abs(value) - 1) < 1e-9 ? "" : OverviewFigures.format(abs(value))
            let sign = value < 0 ? (first ? "−" : " − ") : (first ? "" : " + ")
            return sign + magnitude + variable
        }
        let x = term(row[0], "x", first: true)
        let y = term(row[1], "y", first: x == nil)
        return (x ?? "") + (y ?? "") + " = " + OverviewFigures.format(row[2])
    }
}
