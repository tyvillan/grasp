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
            let buckets = ExamLayout.bucketSkills(page.parts)
            if let buckets {
                SkillsByTopic(buckets: buckets, terms: page.parts.flatMap(\.terms), subject: page.exam.title, onRate: { skill, rating in
                    store.rateSkill(guideId: skill.guideId, skillId: skill.skillId, rating: rating)
                })
            }
            ForEach(ExamLayout.Band.allCases, id: \.self) { band in
                let parts = page.parts.filter { ExamLayout.band(for: $0) == band }
                if !parts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(band == .topics && buckets != nil ? "Details by part" : band.label)
                        ForEach(parts) { part in partView(part, showsSkills: buckets == nil) }
                    }
                }
            }
        }
        // Write the skills' explanations in the background, so "What is this?" is instant.
        .task(id: page.exam.id) {
            store.prefetchSkillExplanations(skills: page.parts.flatMap(\.skills),
                                            terms: page.parts.flatMap(\.terms), subject: page.exam.title)
        }
    }

    private func partView(_ part: StudyGuideActions.PagePart, showsSkills: Bool) -> some View {
        PartSection(
            part: part,
            total: page.questionCount,
            decks: decks,
            showsSkills: showsSkills,
            allTerms: page.parts.flatMap(\.terms),
            subject: page.exam.title,
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

// MARK: - Skills by topic

/// Every skill once, grouped by topic, with progress -- the page's
/// at-a-glance answer to "what do I still need to learn".
private struct SkillsByTopic: View {
    let buckets: [ExamLayout.Bucket]
    let terms: [StudyGuideDocument.Term]
    let subject: String
    let onRate: (StudyGuideActions.Skill, SkillConfidence?) -> Void
    @State private var open: Set<ExamLayout.Topic> = []

    private var all: [StudyGuideActions.Skill] { buckets.flatMap(\.skills) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Skills")
                Spacer()
                Text("\(all.filter { $0.rating == .canDoCold }.count) of \(all.count) ready")
                    .graspType(.meta).monospacedDigit()
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            VStack(spacing: 8) {
                ForEach(buckets, id: \.topic) { bucket in
                    let ready = bucket.skills.filter { $0.rating == .canDoCold }.count
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            if open.contains(bucket.topic) { open.remove(bucket.topic) } else { open.insert(bucket.topic) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: open.contains(bucket.topic) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(GRASPColor.textTertiary)
                                    .frame(width: 12)
                                Text(bucket.topic.label)
                                    .graspType(.rowTitle)
                                    .foregroundStyle(GRASPColor.textPrimary)
                                Spacer()
                                ProgressBar(value: ready, total: bucket.skills.count, tint: GRASPColor.success)
                                    .frame(width: 70)
                                Text("\(ready)/\(bucket.skills.count)")
                                    .graspType(.meta).monospacedDigit()
                                    .foregroundStyle(GRASPColor.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if open.contains(bucket.topic) {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(bucket.skills) { skill in
                                    SkillRow(skill: skill, terms: terms, subject: subject, onRate: { onRate(skill, $0) })
                                }
                            }
                            .padding(.top, 14).padding(.leading, 22)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GRASPColor.hairline))
                }
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
    let showsSkills: Bool
    let allTerms: [StudyGuideDocument.Term]
    let subject: String
    let onSetDecks: ([String]) -> Void
    let onRate: (StudyGuideActions.Skill, SkillConfidence?) -> Void
    let onOpenPage: (String, Int) -> Void
    @State private var isOpen = false

    /// One line saying what's inside, so a closed part still tells you
    /// whether it's worth opening.
    private var summary: String {
        var pieces: [String] = []
        let practice = part.examples.filter { $0.example.isPractice }.count
        if practice > 0 { pieces.append("\(practice) practice") }
        let examples = part.examples.count - practice
        if examples > 0 { pieces.append("\(examples) example\(examples == 1 ? "" : "s")") }
        if showsSkills, !part.skills.isEmpty { pieces.append("\(part.skills.count) skills") }
        if !part.terms.isEmpty { pieces.append("\(part.terms.count) terms") }
        if !part.traps.isEmpty { pieces.append("\(part.traps.count) traps") }
        if !part.formulas.isEmpty { pieces.append("\(part.formulas.count) formulas") }
        if pieces.isEmpty, !part.notes.isEmpty { pieces.append("notes") }
        return pieces.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() } } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GRASPColor.textTertiary)
                        .frame(width: 12)
                    header
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isOpen, !summary.isEmpty {
                Text(summary).graspType(.meta).foregroundStyle(GRASPColor.textTertiary).padding(.leading, 22)
            }
            if isOpen { details }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GRASPColor.hairline))
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            coverage
            if showsSkills, !part.skills.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("You should be able to")
                    ForEach(part.skills) { skill in
                        SkillRow(skill: skill, terms: allTerms, subject: subject, onRate: { onRate(skill, $0) })
                    }
                }
            }
            if !part.traps.isEmpty {
                QuietBlock(label: "Traps the wrong answers are built on") {
                    BulletList(items: part.traps)
                }
            }
            if !part.terms.isEmpty {
                QuietBlock(label: "Key terms") {
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
                QuietBlock(label: "Formulas") {
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
                QuietBlock(label: "Remember") {
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

/// One calm style for the small blocks inside a part, instead of a colour
/// per kind.
private struct QuietBlock<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textTertiary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @Environment(AppStore.self) private var store
    let skill: StudyGuideActions.Skill
    let terms: [StudyGuideDocument.Term]
    let subject: String
    let onRate: (SkillConfidence?) -> Void

    private enum Meaning { case none, loading, found(String, fromGuide: Bool), unavailable }
    @State private var shown = false
    @State private var meaning: Meaning = .none

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
                Button(shown ? "Hide meaning" : "What is this?") { toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(GRASPColor.accent)
                    .padding(.leading, 8)
            }
            .fixedSize()
            if shown { meaningView }
        }
    }

    @ViewBuilder
    private var meaningView: some View {
        Group {
            switch meaning {
            case .none, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing a short explanation…").graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                }
            case .found(let text, let fromGuide):
                VStack(alignment: .leading, spacing: 4) {
                    Text(text)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(fromGuide ? "From the guide" : "Written by AI")
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                }
            case .unavailable:
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.isGeneratorAvailable
                         ? "That took too long or failed. The model may be busy or slow."
                         : "No AI model is set up to explain this. Settings → AI has the setup.")
                        .graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                    if store.isGeneratorAvailable {
                        Button("Try Again") { generate() }.buttonStyle(GRASPQuietButton())
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func toggle() {
        shown.toggle()
        guard shown, case .none = meaning else { return }
        if let term = ExamLayout.definition(for: skill.text, terms: terms) {
            meaning = .found(term.term + ": " + term.definition, fromGuide: true)
            return
        }
        generate()
    }

    /// Asks the model, giving up after a minute and a half so a stuck
    /// model shows a message and a retry instead of spinning for ever.
    private func generate() {
        meaning = .loading
        let context = terms.prefix(12).map { "\($0.term): \($0.definition)" }.joined(separator: "\n")
        let (store, skill, subject) = (self.store, self.skill, self.subject)
        Task {
            let text: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    await store.skillExplanation(guideId: skill.guideId, skillId: skill.skillId,
                                                 skill: skill.text, subject: subject, context: context)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            meaning = text.map { .found($0, fromGuide: false) } ?? .unavailable
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
        var matrix: TextMatrix?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.segments(text)) { segment in
                if let matrix = segment.matrix {
                    TextMatrixView(matrix: matrix).padding(.vertical, 2)
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

    /// One row of a plain-notation matrix, "[ 1  2/3  -4 ]" or "A = [ 1 2 h ]":
    /// an optional name, then the entries. Entries may be numbers or short
    /// symbols like h or 2x; nil for anything else.
    private static func matrixRow(_ line: String) -> (label: String?, entries: [String])? {
        var t = line.trimmingCharacters(in: .whitespaces)
        var label: String?
        if let eq = t.range(of: " = [") ?? t.range(of: "=[") {
            let name = t[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 3, name.allSatisfy({ $0.isLetter }) else { return nil }
            label = name
            t = "[" + t[eq.upperBound...]
        }
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let entries = t.dropFirst().dropLast().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
        guard !entries.isEmpty, entries.count <= 8 else { return nil }
        for entry in entries {
            guard entry.count <= 8, entry.allSatisfy({ $0.isNumber || $0.isLetter || "+-*/.^_()".contains($0) }) else { return nil }
        }
        return (label, entries)
    }

    /// Prose with any plain-notation matrices cut out: text pieces carry a nil
    /// matrix, matrix pieces an empty string.
    static func splitMatrices(_ text: String) -> [(text: String, matrix: TextMatrix?)] {
        var pieces: [(text: String, matrix: TextMatrix?)] = []
        var prose: [String] = []
        var rows: [[String]] = []
        var label: String?
        var rowLines: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { pieces.append((joined, nil)) }
            prose = []
        }
        func flushRows() {
            if rows.count > 1 || (rows.first?.count ?? 0) > 1 {
                flushProse()
                pieces.append(("", TextMatrix(label: label, rows: rows)))
            } else {
                prose.append(contentsOf: rowLines)
            }
            rows = []; rowLines = []; label = nil
        }
        for line in text.components(separatedBy: "\n") {
            if let row = matrixRow(line), rows.isEmpty || (rows[0].count == row.entries.count && row.label == nil) {
                if rows.isEmpty { label = row.label }
                rows.append(row.entries); rowLines.append(line)
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
        func flush() {
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append(Segment(id: result.count, isCode: code, text: joined)) }
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            let lineIsCode = isCode(line) || (code && line.trimmingCharacters(in: .whitespaces).isEmpty)
            if lineIsCode != code { flush(); code = lineIsCode }
            lines.append(line)
        }
        flush()
        return result
    }
}

/// A matrix as plain text entries, kept as written -- numbers, fractions
/// or symbols like h -- with an optional name ("A =") in front.
struct TextMatrix: Equatable {
    var label: String?
    var rows: [[String]]
}

/// Draws a `TextMatrix` with brackets, columns lined up.
struct TextMatrixView: View {
    let matrix: TextMatrix

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let label = matrix.label {
                Text(label + " =").font(.system(size: 15, design: .serif)).foregroundStyle(GRASPColor.textPrimary)
            }
            HStack(spacing: 6) {
                bracket(open: true)
                Grid(horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(matrix.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(size: 15, design: .serif)).monospacedDigit()
                                    .foregroundStyle(GRASPColor.textPrimary)
                                    .frame(minWidth: 18)
                            }
                        }
                    }
                }
                bracket(open: false)
            }
            .fixedSize()
        }
        .fixedSize()
    }

    private func bracket(open: Bool) -> some View {
        BracketShape(open: open)
            .stroke(GRASPColor.textSecondary, lineWidth: 1.4)
            .frame(width: 7)
    }
}

private nonisolated struct BracketShape: Shape {
    let open: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let near = open ? rect.maxX : rect.minX
        let far = open ? rect.minX : rect.maxX
        path.move(to: CGPoint(x: near, y: rect.minY))
        path.addLine(to: CGPoint(x: far, y: rect.minY))
        path.addLine(to: CGPoint(x: far, y: rect.maxY))
        path.addLine(to: CGPoint(x: near, y: rect.maxY))
        return path
    }
}
