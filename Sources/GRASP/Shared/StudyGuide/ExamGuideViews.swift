import SwiftUI
import PDFKit
import GRASPCore

// The exam study page's guide, shared by the Mac (`ExamStudyView`) and the
// iPhone (`ExamScreen`): the header, then each part with its skills, traps,
// terms and practice problems. Each app puts it in its own scroll view and
// supplies how to open a file.

/// Everything on the Guide tab below the app's own toolbar.
struct ExamGuideContent: View {
    @Environment(AppStore.self) private var store
    let page: StudyGuideActions.ExamPage
    let decks: [Deck]
    /// Opens a guide's file at a page, for the tables and figures its text
    /// can't carry.
    let onOpenPage: (PDFPageTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ExamHeader(page: page, fileURL: { store.fileURL(ofGuide: $0) },
                       onOpen: { guide, url in onOpenPage(PDFPageTarget(url: url, page: 1, title: guide.title, wholeFile: true)) },
                       onRemove: { store.deleteStudyGuide($0.id) })
            if page.parts.isEmpty {
                ContentUnavailableView(
                    "No parts found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("GRASP couldn't find parts like \"Part 1 · Title\" in this exam's guides yet.")
                )
            }
            ForEach(page.parts) { part in
                PartSection(
                    part: part,
                    total: page.questionCount,
                    decks: decks,
                    onSetDecks: { deckIds in
                        for source in part.sources {
                            store.setGuideDecks(guideId: source.guideId, partIndex: source.partIndex, deckIds: deckIds)
                        }
                    },
                    onRate: { skill, rating in
                        store.rateSkill(guideId: skill.guideId, skillId: skill.skillId, rating: rating)
                    },
                    onOpenPage: { guideId, pageNumber in
                        guard let guide = page.guides.first(where: { $0.id == guideId }),
                              let url = store.fileURL(ofGuide: guide)
                        else { return }
                        onOpenPage(PDFPageTarget(url: url, page: pageNumber, title: guide.title))
                    }
                )
            }
        }
    }
}

// MARK: - Header

private struct ExamHeader: View {
    let page: StudyGuideActions.ExamPage
    let fileURL: (StudyGuide) -> URL?
    let onOpen: (StudyGuide, URL) -> Void
    let onRemove: (StudyGuide) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(page.isPracticeSet
                 ? "Practice set · \(page.exam.startsAt.formatted(.dateTime.month(.abbreviated).day()))"
                 : "\(page.exam.startsAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · \(page.exam.countdownText())")
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.accent)
            Text(page.exam.title)
                .graspType(.display)
                .foregroundStyle(GRASPColor.textPrimary)
            if !page.format.isEmpty {
                Text(page.format.joined(separator: " · "))
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            // How the exam works and how to use the guide: worth reading
            // once, not worth pushing every part below the fold for.
            if !page.notes.isEmpty {
                DisclosureGroup("About this exam") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(page.notes, id: \.self) { note in
                            Text(note)
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                }
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(page.guides) { guide in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(GRASPColor.textTertiary)
                        Text(guide.title)
                            .graspType(.rowTitle)
                            .foregroundStyle(GRASPColor.textPrimary)
                        if page.unreadGuides.contains(where: { $0.id == guide.id }) {
                            Text("No parts found")
                                .graspType(.meta)
                                .foregroundStyle(GRASPColor.rejected)
                        }
                        Spacer(minLength: 0)
                        if let url = fileURL(guide) {
                            Button("Open") { onOpen(guide, url) }
                                .buttonStyle(.borderless)
                                .graspType(.meta)
                        }
                        Menu {
                            Button(page.isPracticeSet ? "Delete This Practice Set" : "Remove from This Exam",
                                   role: .destructive) { onRemove(guide) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .borderlessMenu()
                        .fixedSize()
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - A part

private struct PartSection: View {
    let part: StudyGuideActions.PagePart
    let total: Int?
    let decks: [Deck]
    let onSetDecks: ([String]) -> Void
    let onRate: (StudyGuideActions.Skill, SkillConfidence?) -> Void
    let onOpenPage: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            coverage
            if !part.skills.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("You should be able to")
                    ForEach(part.skills) { skill in
                        SkillRow(skill: skill, onRate: { onRate(skill, $0) })
                    }
                }
            }
            if !part.traps.isEmpty {
                Callout(label: "Traps the wrong answers are built on", tint: GRASPColor.rejected) {
                    BulletList(items: part.traps)
                }
            }
            if !part.terms.isEmpty {
                Callout(label: "Key terms", tint: GRASPColor.accent) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(part.terms.enumerated()), id: \.offset) { _, term in
                            (Text(term.term).fontWeight(.semibold) + Text(term.definition.isEmpty ? "" : ": " + term.definition))
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !part.formulas.isEmpty {
                Callout(label: "Formulas", tint: GRASPColor.textSecondary) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(part.formulas, id: \.self) { formula in
                            Text(formula)
                                .graspType(.mono)
                                .foregroundStyle(GRASPColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !part.remember.isEmpty {
                Callout(label: "Remember", tint: GRASPColor.success) {
                    BulletList(items: part.remember)
                }
            }
            ForEach(part.notes, id: \.self) { note in
                Text(note)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // Problems to try first; then the guide's illustrations, which
            // ask nothing, so they don't read as questions missing answers.
            let practice = part.examples.filter { $0.example.isPractice }
            let illustrations = part.examples.filter { !$0.example.isPractice }
            if !practice.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Practice")
                    ForEach(practice) { item in
                        PracticeProblem(item: item, onOpenPage: onOpenPage)
                    }
                }
            }
            if !illustrations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Examples")
                    ForEach(illustrations) { item in
                        PracticeProblem(item: item, onOpenPage: onOpenPage)
                    }
                }
            }
        }
        .padding(20)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GRASPColor.hairline))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let number = part.number {
                    Text("Part \(number)")
                        .graspType(.eyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                Text(part.title)
                    .graspType(.title)
                    .foregroundStyle(GRASPColor.textPrimary)
            }
            Spacer()
            if let count = part.questionCount {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(total.map { "\(count) of \($0) questions" } ?? "\(count) questions")
                        .graspType(.meta)
                        .monospacedDigit()
                        .foregroundStyle(GRASPColor.textSecondary)
                    if let weight = part.weight(of: total) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(GRASPColor.inset)
                                Capsule().fill(GRASPColor.accent).frame(width: geo.size.width * weight)
                            }
                        }
                        .frame(width: 110, height: 4)
                    }
                }
            }
        }
    }

    private var coverage: some View {
        let covered = decks.filter { part.deckIds.contains($0.id) }
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 11))
                .foregroundStyle(GRASPColor.textTertiary)
            if covered.isEmpty {
                Text("No lecture deck yet — this guide is the only source for this part.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            } else {
                Text(covered.map(\.name).joined(separator: ", "))
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            Menu("Lectures") {
                ForEach(decks) { deck in
                    let isOn = part.deckIds.contains(deck.id)
                    Button {
                        var ids = part.deckIds
                        if isOn { ids.removeAll { $0 == deck.id } } else { ids.append(deck.id) }
                        onSetDecks(ids)
                    } label: {
                        if isOn { Label(deck.name, systemImage: "checkmark") } else { Text(deck.name) }
                    }
                }
            }
            .borderlessMenu()
            .graspType(.meta)
            .fixedSize()
            .help("Choose which lecture decks this part covers")
        }
    }
}

private struct BulletList: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(GRASPColor.textTertiary)
                    Text(item.hasPrefix("• ") ? String(item.dropFirst(2)) : item)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
            }
        }
    }
}

// MARK: - Skills

private struct SkillRow: View {
    let skill: StudyGuideActions.Skill
    let onRate: (SkillConfidence?) -> Void

    // The rating sits under the skill, not beside it: beside it, a narrow
    // window squeezed the skill itself into a column a few words wide.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.text)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(SkillConfidence.allCases, id: \.self) { rating in
                    let selected = skill.rating == rating
                    Button(rating.label) { onRate(selected ? nil : rating) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? rating.tint : GRASPColor.textTertiary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(selected ? rating.tint.opacity(0.14) : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(selected ? rating.tint.opacity(0.5) : GRASPColor.hairline))
                }
            }
            .fixedSize()
        }
    }
}

private extension SkillConfidence {
    var label: String {
        switch self {
        case .canDoCold: return "Can do"
        case .shaky: return "Shaky"
        case .cantYet: return "Can't yet"
        }
    }

    var tint: Color {
        switch self {
        case .canDoCold: return GRASPColor.success
        case .shaky: return GRASPColor.accent
        case .cantYet: return GRASPColor.rejected
        }
    }
}

// MARK: - Practice problems

/// Question first; the working and the answer only when asked for, so it
/// can be tried cold -- the way both guides say to use their examples.
private struct PracticeProblem: View {
    let item: StudyGuideActions.PageExample
    let onOpenPage: (String, Int) -> Void
    @State private var revealed = false

    private var example: StudyGuideDocument.Example { item.example }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(example.label ?? (example.isPractice ? "Try it" : "Example"))
                    .graspType(.rowTitle)
                    .foregroundStyle(GRASPColor.textSecondary)
                Spacer()
                if let page = example.page {
                    Button("Page \(page)") { onOpenPage(item.guideId, page) }
                        .buttonStyle(.borderless)
                        .graspType(.meta)
                        .help("Open the guide at this page, for its tables and figures")
                }
            }
            if example.usesFigure == true, let page = example.page {
                Button { onOpenPage(item.guideId, page) } label: {
                    Label("Uses a table or figure from page \(page). Open it alongside.",
                          systemImage: "tablecells")
                        .graspType(.body)
                }
                .buttonStyle(.borderless)
            }
            GuideText(text: example.question, style: .prose, color: GRASPColor.textPrimary)
            if example.isPractice {
                if revealed {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(example.steps.enumerated()), id: \.offset) { _, step in
                            Text(step)
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let answer = example.answer {
                            GuideText(text: answer, style: .body, color: GRASPColor.textPrimary)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.successSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button("Hide Answer") { revealed = false }
                        .buttonStyle(GRASPQuietButton())
                } else {
                    Button("Show Answer") { revealed = true }
                        .buttonStyle(GRASPQuietButton())
                }
            }
        }
        .padding(14)
        .background(GRASPColor.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - The original page

struct PDFPageTarget: Identifiable {
    let url: URL
    let page: Int
    let title: String
    /// The guide itself, from its header, rather than one page for a
    /// problem: the Mac opens it in Preview.
    var wholeFile = false
    var id: String { "\(url.path)#\(page)" }
}

/// The guide's own page, for what its text can't carry: tables of worths,
/// demand schedules, figures.
struct GuidePageSheet: View {
    let target: PDFPageTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(target.title) · page \(target.page)")
                    .graspType(.rowTitle)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            PDFPageView(url: target.url, page: target.page)
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 620)
        #endif
    }
}

private func makePDFView(url: URL, page: Int) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.document = PDFDocument(url: url)
    if let target = view.document?.page(at: max(0, page - 1)) {
        view.go(to: target)
    }
    return view
}

#if os(macOS)
private struct PDFPageView: NSViewRepresentable {
    let url: URL
    let page: Int
    func makeNSView(context: Context) -> PDFView { makePDFView(url: url, page: page) }
    func updateNSView(_ view: PDFView, context: Context) {}
}
#else
private struct PDFPageView: UIViewRepresentable {
    let url: URL
    let page: Int
    func makeUIView(context: Context) -> PDFView { makePDFView(url: url, page: page) }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#endif


// MARK: - Text with code in it

/// A question or answer that may hold C++ (or any code): prose lines are set
/// as text, runs of code lines in a monospaced block with their line
/// breaks kept, so a function reads as a function.
struct GuideText: View {
    let text: String
    let style: GRASPType
    let color: Color

    private struct Segment: Identifiable {
        let id: Int
        let isCode: Bool
        let text: String
        var matrix: RationalMatrix?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.segments(text)) { segment in
                if let matrix = segment.matrix {
                    ScrollView(.horizontal, showsIndicators: false) {
                        MatrixGrid(matrix: matrix, compact: true)
                    }
                    .padding(.vertical, 2)
                } else if segment.isCode {
                    Text(segment.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(segment.text)
                        .graspType(style)
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private static let codeStarts = ["//", "#include", "#define", "if ", "if(", "for ", "for(", "while ", "while(",
                                     "else", "do", "return", "cout", "cin", "int ", "double ", "string ", "bool ",
                                     "char ", "void ", "class ", "struct ", "public:", "private:", "using ",
                                     "ifstream", "ofstream", "const ", "}", "{"]

    static func isCode(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t == "{" || t == "}" || t.hasPrefix("}") { return true }
        // A matrix row: "[ 1  2 ]" or "| 3 4 |", entries only.
        if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("|") && t.hasSuffix("|")),
           t.allSatisfy({ "[]|()0123456789.,/+- ".contains($0) || $0.isLetter && t.count < 40 }) { return true }
        if t.hasPrefix("A = [") || t.hasPrefix("B = [") || t.hasPrefix("M = [") { return true }
        let startsLikeCode = codeStarts.contains { t.hasPrefix($0) }
        let hasCodeShape = t.contains(";") || t.contains("{") || t.contains("<<") || t.contains(">>")
            || t.hasSuffix(")") || t.contains("==") || t.contains("+=")
        return startsLikeCode && hasCodeShape || t.hasPrefix("//") || t.hasSuffix(";")
    }

    /// One row of a plain-notation matrix, "[ 1  2/3  -4 ]", as numbers; nil
    /// for anything else.
    private static func matrixRow(_ line: String) -> [Rational]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let entries = t.dropFirst().dropLast().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
        guard !entries.isEmpty, entries.count <= 8 else { return nil }
        var row: [Rational] = []
        for entry in entries {
            if let n = Int(entry) { row.append(Rational(n)); continue }
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), let r = Rational(n, d) { row.append(r); continue }
            if let d = Double(entry), let r = Rational(approximating: d) { row.append(r); continue }
            return nil
        }
        return row
    }

    /// Prose with any plain-notation matrices cut out: text pieces carry a nil
    /// matrix, matrix pieces an empty string.
    static func splitMatrices(_ text: String) -> [(text: String, matrix: RationalMatrix?)] {
        var pieces: [(text: String, matrix: RationalMatrix?)] = []
        var prose: [String] = []
        var rows: [[Rational]] = []
        var rowLines: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { pieces.append((joined, nil)) }
            prose = []
        }
        func flushRows() {
            if let matrix = RationalMatrix(rows: rows), matrix.rowCount > 1 || matrix.columnCount > 1 {
                flushProse()
                pieces.append(("", matrix))
            } else {
                prose.append(contentsOf: rowLines)
            }
            rows = []; rowLines = []
        }
        for line in text.components(separatedBy: "\n") {
            if let row = matrixRow(line), rows.isEmpty || rows[0].count == row.count {
                rows.append(row); rowLines.append(line)
            } else {
                if !rows.isEmpty { flushRows() }
                prose.append(line)
            }
        }
        if !rows.isEmpty { flushRows() }
        flushProse()
        return pieces
    }

    private static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var lines: [String] = []
        var code = false
        var matrixRows: [[Rational]] = []
        var matrixLines: [String] = []
        func flush() {
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append(Segment(id: result.count, isCode: code, text: joined)) }
            lines = []
        }
        func flushMatrix() {
            defer { matrixRows = []; matrixLines = [] }
            guard !matrixRows.isEmpty else { return }
            if let matrix = RationalMatrix(rows: matrixRows), matrix.rowCount > 1 || matrix.columnCount > 1 {
                result.append(Segment(id: result.count, isCode: false, text: "", matrix: matrix))
            } else {
                // A lone "[ 5 ]" is just text.
                code = false
                lines = matrixLines
            }
        }
        for line in text.components(separatedBy: "\n") {
            if let row = matrixRow(line), matrixRows.isEmpty || matrixRows[0].count == row.count {
                if matrixRows.isEmpty { flush() }
                matrixRows.append(row)
                matrixLines.append(line)
                continue
            }
            if !matrixRows.isEmpty { flushMatrix() }
            let lineIsCode = isCode(line) || (code && line.trimmingCharacters(in: .whitespaces).isEmpty)
            if lineIsCode != code { flush(); code = lineIsCode }
            lines.append(line)
        }
        flushMatrix()
        flush()
        return result
    }
}
