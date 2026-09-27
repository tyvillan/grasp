import SwiftUI
import PDFKit
import GRASPCore

/// One exam's study page: its study guides read together, part by part,
/// beside a Study tab that runs flashcards, Learn and tests over just the
/// lecture decks the exam covers.
///
/// A guide cuts across the course's decks, which is why it gets its own
/// page instead of living in one of them: each part says how much of the
/// exam it is, which lectures it draws on, what you should be able to do,
/// and what the wrong answers are built to catch.
struct ExamStudyView: View {
    @Environment(AppStore.self) private var store
    let courseId: String
    let examEventId: String

    enum Tab: String, CaseIterable, Identifiable {
        case guide = "Guide"
        case study = "Study"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .guide
    @State private var page: StudyGuideActions.ExamPage?
    @State private var decks: [Deck] = []
    @State private var openPage: PDFPageTarget?
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if importing {
                    ProgressView().controlSize(.small)
                    Text("Reading guide…")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
                Button("Add Study Guide…", action: addGuide)
                    .buttonStyle(GRASPQuietButton())
                    .disabled(importing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)

            switch tab {
            case .guide:
                guideTab
            case .study:
                if page?.deckIds.isEmpty ?? true {
                    ContentUnavailableView(
                        "No lecture decks yet",
                        systemImage: "rectangle.stack",
                        description: Text("None of this exam's parts is matched to a lecture deck. Pick decks for a part on the Guide tab.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DeckDetailView(scope: .exam(courseId: courseId, examEventId: examEventId), onAddFiles: addGuide)
                }
            }
        }
        .sheet(item: $openPage) { target in
            GuidePageSheet(target: target)
        }
        .task(id: examEventId) { load() }
        .onChange(of: store.revision) { load() }
    }

    private func load() {
        page = store.examPage(examEventId: examEventId)
        decks = (try? store.decks(inCourse: courseId)) ?? []
    }

    private func addGuide() {
        let urls = ImportPanel.pickFilesOrFolders(message: "Choose study guides for this exam")
        guard !urls.isEmpty else { return }
        importing = true
        Task {
            await store.importStudyGuides(urls, intoCourse: courseId, examEventId: examEventId)
            importing = false
            load()
        }
    }

    // MARK: - Guide tab

    @ViewBuilder
    private var guideTab: some View {
        if let page {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ExamHeader(page: page, fileURL: { store.fileURL(ofGuide: $0) },
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
                                openPage = PDFPageTarget(url: url, page: pageNumber, title: guide.title)
                            }
                        )
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("Exam not found", systemImage: "calendar.badge.exclamationmark")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Header

private struct ExamHeader: View {
    let page: StudyGuideActions.ExamPage
    let fileURL: (StudyGuide) -> URL?
    let onRemove: (StudyGuide) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(page.exam.startsAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · \(page.exam.countdownText())")
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
                            Button("Open") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link)
                        }
                        Menu {
                            Button("Remove from This Exam", role: .destructive) { onRemove(guide) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
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
            if !part.examples.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Practice")
                    ForEach(part.examples) { item in
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
            .menuStyle(.borderlessButton)
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
                        .buttonStyle(.link)
                        .help("Open the guide at this page, for its tables and figures")
                }
            }
            Text(example.question)
                .graspType(.prose)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
                            Text(answer)
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
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
    var id: String { "\(url.path)#\(page)" }
}

/// The guide's own page, for what its text can't carry: tables of worths,
/// demand schedules, figures.
private struct GuidePageSheet: View {
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
        .frame(minWidth: 760, minHeight: 620)
    }
}

private struct PDFPageView: NSViewRepresentable {
    let url: URL
    let page: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        if let target = view.document?.page(at: max(0, page - 1)) {
            view.go(to: target)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
