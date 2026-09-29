import Foundation
import GRASPCore
import GRDB
import SwiftCrossUI

// MARK: - Library

extension Library {
    /// Exams in a course with at least one study guide, from yesterday on,
    /// so a guide is still there the day of the exam.
    func guidedExams(courseId: String, now: Date = Date()) -> [CalendarEvent] {
        let key = "\(revision)#\(courseId)"
        if let cached = guidedExamsCache, cached.key == key { return cached.value }
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let value = (try? database.queue.read {
            try StudyGuideActions.guidedExams(courseId: courseId, since: since, db: $0)
        }) ?? []
        guidedExamsCache = (key, value)
        return value
    }

    /// Where an exam's Study link goes: its study page when it has a guide,
    /// else the deck it names (nil is All Cards).
    func studyTarget(for event: CalendarEvent) -> String? {
        hasStudyGuide(examEventId: event.id) ? DeckScope.examId(event.id) : event.deckId
    }

    func hasStudyGuide(examEventId: String) -> Bool {
        ((try? database.queue.read {
            try StudyGuide.filter(Column("examEventId") == examEventId).fetchCount($0)
        }) ?? 0) > 0
    }

    func examPage(examEventId: String) -> StudyGuideActions.ExamPage? {
        let key = "\(revision)#\(examEventId)"
        if let cached = examPageCache, cached.key == key { return cached.value }
        let value = (try? database.queue.read { try StudyGuideActions.examPage(examEventId: examEventId, db: $0) }) ?? nil
        examPageCache = (key, value)
        return value
    }

    /// The file a guide was imported from, when it's on this PC.
    func fileURL(ofGuide guide: StudyGuide) -> URL? {
        guard let materialId = guide.materialId,
              let material = (try? database.queue.read { try Material.fetchOne($0, key: materialId) }) ?? nil,
              let url = fileURL(for: material),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    func setGuideDecks(_ part: StudyGuideActions.PagePart, deckIds: [String]) {
        try? database.queue.write { db in
            for source in part.sources {
                try StudyGuideActions.setDecks(guideId: source.guideId, partIndex: source.partIndex,
                                               deckIds: deckIds, db: db)
            }
        }
        overviewsChanged()
    }

    func rateSkill(_ skill: StudyGuideActions.Skill, rating: SkillConfidence?) {
        try? database.queue.write {
            try StudyGuideActions.rate(guideId: skill.guideId, skillId: skill.skillId, rating: rating, db: $0)
        }
        overviewsChanged()
    }

    func deleteStudyGuide(_ guideId: String) {
        try? database.queue.write { try StudyGuideActions.delete(guideId: guideId, db: $0) }
        overviewsChanged()
    }

    /// Imports guide files into a course (they become guides, not cards,
    /// because of their names) and, given an exam, links every guide the
    /// import touched to it, as the Mac does. Returns how many were read.
    func importStudyGuides(_ urls: [URL], intoCourse courseId: String, examEventId: String? = nil) async -> Int {
        guard !isImporting else { return 0 }
        isImporting = true
        defer { isImporting = false }
        let paths = vaultPaths()
        let existing = (try? await database.queue.read { try StudyGuideActions.guides(forCourse: courseId, db: $0) }) ?? []
        let before = Set(existing.map(\.id))
        let summary: ImportSummary
        do {
            summary = try await VaultScanner(database: database, paths: paths).importPaths(urls, intoCourse: courseId)
        } catch {
            status = "Import failed: \(error.localizedDescription)"
            return 0
        }
        if let examEventId {
            let picked = Set(urls.map { paths.stored(forLocal: $0.path) })
            try? await database.queue.write { db in
                for guide in try StudyGuideActions.guides(forCourse: courseId, db: db) {
                    guard let materialId = guide.materialId,
                          let material = try Material.fetchOne(db, key: materialId),
                          picked.contains(material.relativePath) || !before.contains(guide.id)
                    else { continue }
                    try StudyGuideActions.setExam(guideId: guide.id, examEventId: examEventId, db: db)
                }
            }
        }
        overviewsChanged()
        return summary.studyGuidesImported
    }
}

// MARK: - The exam page

/// One exam's study page, after the Mac's `ExamStudyView`: its study guides
/// read together, part by part, beside a Study tab that runs flashcards,
/// Learn and tests over just the lecture decks the exam covers.
struct ExamStudyView: View {
    let library: Library
    let course: Course
    let exam: CalendarEvent
    let organize: (OrganizeSheet) -> Void
    @State var tab: Tab = .guide
    @State var message: String?
    @Environment(\.chooseFile) var chooseFile
    @Environment(\.chooseFileSaveDestination) var chooseSaveDestination

    enum Tab: String, CaseIterable {
        case guide = "Guide"
        case study = "Study"
    }

    var body: some View {
        let page = library.examPage(examEventId: exam.id)
        let decks = library.decks(inCourse: course.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SegmentedChoice(options: Tab.allCases, selection: tab, label: \.rawValue) { tab = $0 }
                Spacer()
                if library.isImporting {
                    Text("Reading guide…").font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary).fixedSize()
                }
                if let page, !page.parts.isEmpty {
                    Menu("Download") {
                        ForEach(DocumentExport.Format.allCases, id: \.self) { format in
                            Button("Study Guide with Answer Key (\(format.label))") {
                                download(page, decks: decks, answerKey: true, format: format)
                            }
                        }
                        ForEach(DocumentExport.Format.allCases, id: \.self) { format in
                            Button("Practice Sheet, No Answers (\(format.label))") {
                                download(page, decks: decks, answerKey: false, format: format)
                            }
                        }
                    }
                    .fixedSize()
                }
                Button("Add Study Guide…") { addGuide() }
                    .disabled(library.isImporting)
                    .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
            if let message {
                HStack(spacing: 10) {
                    Text(message).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                    Spacer()
                    Button("Dismiss") { self.message = nil }.fixedSize()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(GRASPColor.accentSoft)
            }
            switch tab {
            case .guide:
                if let page {
                    guideTab(page, decks: decks)
                } else {
                    Text("This exam isn't in the library any more.")
                        .foregroundColor(GRASPColor.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .study:
                studyTab(page, decks: decks)
            }
        }
    }

    private func guideTab(_ page: StudyGuideActions.ExamPage, decks: [DeckRow]) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width.isFinite && proxy.size.width > 0 ? proxy.size.width : 820
            let column = min(760, width - 64)
            ScrollView {
                ExamGuideContent(library: library, page: page, decks: decks)
                    .frame(width: column, alignment: .leading)
                    .padding(.leading, Int(max(32, (width - column) / 2)))
                    .padding(.vertical, 28)
            }
        }
    }

    @ViewBuilder
    private func studyTab(_ page: StudyGuideActions.ExamPage?, decks: [DeckRow]) -> some View {
        let ids = Set(page?.deckIds ?? [])
        let covered = decks.filter { ids.contains($0.id) }
        if covered.isEmpty {
            VStack(spacing: 8) {
                Text("No lecture decks yet").font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
                Text("None of this exam's parts is matched to a lecture deck. Pick decks for a part on the Guide tab.")
                    .foregroundColor(GRASPColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DeckView(library: library,
                     scope: DeckScope(exam: exam, decks: covered, courseId: course.id, courseName: course.name),
                     deck: nil, organize: organize)
        }
    }

    private func addGuide() {
        Task {
            guard let url = await chooseFile(
                title: "Choose a study guide for \(exam.title)",
                defaultButtonLabel: "Add",
                allowSelectingFiles: true,
                allowSelectingDirectories: false
            ) else { return }
            let read = await library.importStudyGuides([url], intoCourse: course.id, examEventId: exam.id)
            message = read == 0
                ? "That file didn't read as a study guide. Guides are recognised by name, like \"Exam 1 Study Guide\" or \"Midterm Review\"."
                : nil
        }
    }

    private func download(_ page: StudyGuideActions.ExamPage, decks: [DeckRow], answerKey: Bool,
                          format: DocumentExport.Format) {
        let names = Dictionary(decks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let document = StudyGuideExport.document(page: page, deckNames: names, answerKey: answerKey)
        let name = document.fileName + (answerKey ? "" : " - Practice Sheet") + "." + format.fileExtension
        Task {
            guard let url = await chooseSaveDestination(title: "Save \(format.label)", defaultFileName: name) else { return }
            do {
                try await DocumentExport.write(document, as: format, to: url)
                message = "Saved \(url.lastPathComponent)."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - The guide

/// The exam's header, then each part: its share of the exam, lecture
/// decks, skills to rate, traps, terms, formulas and practice problems.
private struct ExamGuideContent: View {
    let library: Library
    let page: StudyGuideActions.ExamPage
    let decks: [DeckRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ExamHeader(library: library, page: page)
            if page.parts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No parts found").font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
                    Text("GRASP couldn't find parts like \"Part 1 · Title\" in this exam's guides yet.")
                        .font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                }
            }
            ForEach(page.parts, id: \.id) { part in
                PartSection(library: library, page: page, part: part, total: page.questionCount, decks: decks)
            }
        }
    }
}

private struct ExamHeader: View {
    let library: Library
    let page: StudyGuideActions.ExamPage
    @State var showsNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Self.date(page.exam.startsAt)) · \(page.exam.countdownText())".uppercased())
                .font(GRASPFont.eyebrow)
                .foregroundColor(GRASPColor.accent)
            Text(page.exam.title)
                .font(GRASPFont.display)
                .foregroundColor(GRASPColor.textPrimary)
            if !page.format.isEmpty {
                Text(page.format.joined(separator: " · "))
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
            }
            if !page.notes.isEmpty {
                Text(showsNotes ? "▾ About this exam" : "▸ About this exam")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .onTapGesture { showsNotes.toggle() }
                if showsNotes {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(page.notes.enumerated()), id: \.offset) { item in
                            Text(item.element).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(page.guides, id: \.id) { guide in
                    GuideRow(library: library, guide: guide,
                             unread: page.unreadGuides.contains { $0.id == guide.id })
                }
            }
            .padding(.top, 6)
        }
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }
}

private struct GuideRow: View {
    let library: Library
    let guide: StudyGuide
    let unread: Bool

    var body: some View {
        let url = library.fileURL(ofGuide: guide)
        HStack(spacing: 8) {
            Text("GUIDE").font(GRASPFont.badge).foregroundColor(GRASPColor.textTertiary).fixedSize()
            Text(guide.title).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary).lineLimit(1)
            if unread {
                Text("No parts found").font(GRASPFont.meta).foregroundColor(GRASPColor.rejected).fixedSize()
            }
            Spacer()
            Menu("•••") {
                if let url {
                    Button("Open") { ExternalLink.openFile(url) }
                    Button("Show in Explorer") { ExternalLink.showInExplorer(url) }
                }
                Button("Remove from This Exam") { library.deleteStudyGuide(guide.id) }
            }
            .fixedSize()
        }
    }
}

// MARK: - A part

private struct PartSection: View {
    let library: Library
    let page: StudyGuideActions.ExamPage
    let part: StudyGuideActions.PagePart
    let total: Int?
    let decks: [DeckRow]

    var body: some View {
        let practice = part.examples.filter { $0.example.isPractice }
        let illustrations = part.examples.filter { !$0.example.isPractice }
        VStack(alignment: .leading, spacing: 16) {
            PartHeader(part: part, total: total)
            coverage
            if !part.skills.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("You should be able to")
                    ForEach(part.skills, id: \.id) { skill in
                        SkillRow(skill: skill) { library.rateSkill(skill, rating: $0) }
                    }
                }
            }
            if !part.traps.isEmpty {
                GuideCallout(label: "Traps the wrong answers are built on", tint: GRASPColor.rejected) {
                    BulletList(items: part.traps)
                }
            }
            if !part.terms.isEmpty {
                GuideCallout(label: "Key terms", tint: GRASPColor.accent) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(part.terms.enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.term).font(GRASPFont.body.weight(.semibold))
                                    .foregroundColor(GRASPColor.textPrimary)
                                if !item.element.definition.isEmpty {
                                    Text(item.element.definition).font(GRASPFont.body)
                                        .foregroundColor(GRASPColor.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            if !part.formulas.isEmpty {
                GuideCallout(label: "Formulas", tint: GRASPColor.textSecondary) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(part.formulas.enumerated()), id: \.offset) { item in
                            Text(item.element).font(LessonFont.formula).foregroundColor(GRASPColor.textPrimary)
                        }
                    }
                }
            }
            if !part.remember.isEmpty {
                GuideCallout(label: "Remember", tint: GRASPColor.success) {
                    BulletList(items: part.remember)
                }
            }
            ForEach(Array(part.notes.enumerated()), id: \.offset) { item in
                Text(item.element).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
            }
            // Problems to try first; then the guide's illustrations, which
            // ask nothing, so they don't read as questions missing answers.
            if !practice.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Practice")
                    ForEach(practice, id: \.id) { item in
                        PracticeProblem(item: item, openPage: openPage)
                    }
                }
            }
            if !illustrations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Examples")
                    ForEach(illustrations, id: \.id) { item in
                        PracticeProblem(item: item, openPage: openPage)
                    }
                }
            }
        }
        .padding(20)
        .background(GRASPColor.surface)
        .cornerRadius(10)
    }

    private func openPage(_ guideId: String, _ number: Int) {
        guard let guide = page.guides.first(where: { $0.id == guideId }),
              let url = library.fileURL(ofGuide: guide)
        else { return }
        ExternalLink.openFile(url, page: number)
    }

    /// Which lecture decks the part draws on, and a menu to change them.
    private var coverage: some View {
        let covered = decks.filter { part.deckIds.contains($0.id) }
        return HStack(spacing: 8) {
            Text(covered.isEmpty
                 ? "No lecture deck yet -- this guide is the only source for this part."
                 : covered.map(\.name).joined(separator: ", "))
                .font(GRASPFont.meta)
                .foregroundColor(covered.isEmpty ? GRASPColor.textTertiary : GRASPColor.textSecondary)
            Menu("Lectures") {
                ForEach(decks, id: \.id) { deck in
                    let isOn = part.deckIds.contains(deck.id)
                    Button(isOn ? "✓ \(deck.name)" : deck.name) {
                        var ids = part.deckIds
                        if isOn { ids.removeAll { $0 == deck.id } } else { ids.append(deck.id) }
                        library.setGuideDecks(part, deckIds: ids)
                    }
                }
            }
            .fixedSize()
        }
    }
}

private struct PartHeader: View {
    let part: StudyGuideActions.PagePart
    let total: Int?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let number = part.number {
                    SectionLabel("Part \(number)")
                }
                Text(part.title).font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
            }
            Spacer()
            if let count = part.questionCount {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(total.map { "\(count) of \($0) questions" } ?? "\(count) questions")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textSecondary)
                        .fixedSize()
                    if let weight = part.weight(of: total) {
                        ProgressBar(fraction: weight).frame(width: 110.0)
                    }
                }
            }
        }
    }
}

private struct GuideCallout<Content: View>: View {
    let label: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(tint).frame(width: 3.0)
            VStack(alignment: .leading, spacing: 8) {
                Text(label.uppercased()).font(GRASPFont.eyebrow).foregroundColor(tint)
                content()
            }
            .padding(12)
            Spacer()
        }
        .background(GRASPColor.canvas)
        .cornerRadius(6)
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundColor(GRASPColor.textTertiary)
                    Text(item.element.hasPrefix("• ") ? String(item.element.dropFirst(2)) : item.element)
                        .foregroundColor(GRASPColor.textPrimary)
                }
                .font(GRASPFont.body)
            }
        }
    }
}

// MARK: - Skills

/// A skill, with Can do / Shaky / Can't yet under it; tapping the chosen
/// one again clears it.
private struct SkillRow: View {
    let skill: StudyGuideActions.Skill
    let rate: (SkillConfidence?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.text).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
            HStack(spacing: 4) {
                ForEach(SkillConfidence.allCases, id: \.self) { rating in
                    let selected = skill.rating == rating
                    Text(Self.label(rating))
                        .font(Font.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? Self.tint(rating) : GRASPColor.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selected ? Self.soft(rating) : GRASPColor.inset)
                        .cornerRadius(10)
                        .fixedSize()
                        .onTapGesture { rate(selected ? nil : rating) }
                }
            }
        }
    }

    static func label(_ rating: SkillConfidence) -> String {
        switch rating {
        case .canDoCold: return "Can do"
        case .shaky: return "Shaky"
        case .cantYet: return "Can't yet"
        }
    }

    static func tint(_ rating: SkillConfidence) -> Color {
        switch rating {
        case .canDoCold: return GRASPColor.success
        case .shaky: return GRASPColor.accent
        case .cantYet: return GRASPColor.rejected
        }
    }

    static func soft(_ rating: SkillConfidence) -> Color {
        switch rating {
        case .canDoCold: return GRASPColor.successSoft
        case .shaky: return GRASPColor.accentSoft
        case .cantYet: return GRASPColor.rejectedSoft
        }
    }
}

// MARK: - Practice problems

/// Question first; the working and the answer only when asked for, so it
/// can be tried cold.
private struct PracticeProblem: View {
    let item: StudyGuideActions.PageExample
    let openPage: (String, Int) -> Void
    @State var revealed = false

    var body: some View {
        let example = item.example
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(example.label ?? (example.isPractice ? "Try it" : "Example"))
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(GRASPColor.textSecondary)
                Spacer()
                if let page = example.page {
                    Button("Page \(page)") { openPage(item.guideId, page) }.fixedSize()
                }
            }
            if example.usesFigure == true, let page = example.page {
                Text("Uses a table or figure from page \(page). Open it alongside.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.accent)
                    .onTapGesture { openPage(item.guideId, page) }
            }
            Text(example.question).font(LessonFont.prose).foregroundColor(GRASPColor.textPrimary)
            if example.isPractice {
                if revealed {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(example.steps.enumerated()), id: \.offset) { step in
                            Text(step.element).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                        }
                        if let answer = example.answer {
                            Text(answer).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.successSoft)
                    .cornerRadius(6)
                    Button("Hide Answer") { revealed = false }.fixedSize()
                } else {
                    Button("Show Answer") { revealed = true }.fixedSize()
                }
            }
        }
        .padding(14)
        .background(GRASPColor.canvas)
        .cornerRadius(8)
    }
}

// MARK: - The deck column's exam row

/// An exam with a study guide, pinned under All Cards: what to study for
/// next, as on the Mac.
struct ExamColumnRow: View {
    let exam: CalendarEvent
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("EXAM").font(GRASPFont.badge).foregroundColor(GRASPColor.accent).fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(exam.title)
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(isSelected ? GRASPColor.accent : GRASPColor.textPrimary)
                    .lineLimit(1)
                Text("\(Self.date(exam.startsAt)) · \(exam.countdownText())")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? GRASPColor.accentSoft : Color.clear)
        .cornerRadius(6)
        .onTapGesture(perform: action)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
