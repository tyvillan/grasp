import SwiftUI
import UniformTypeIdentifiers
import GRASPCore

/// One exam's study page on the iPhone: its guides read together, part by
/// part (the same `ExamGuideContent` the Mac shows), and a way into
/// flashcards, Learn and tests over only the lecture decks the exam covers.
struct ExamScreen: View {
    @Environment(AppStore.self) private var store
    let courseId: String
    let examEventId: String
    /// Set for a guide with no exam (a practice set): just that guide.
    var practiceGuideId: String? = nil

    private var isPracticeSet: Bool { practiceGuideId != nil }

    @State private var page: StudyGuideActions.ExamPage?
    @State private var decks: [Deck] = []
    @State private var openPage: PDFPageTarget?
    @State private var choosingFiles = false
    @State private var importing = false
    @State private var message: String?
    @State private var testPhase: TestPhase?

    private var testScopeKey: String { "guide:" + (practiceGuideId ?? examEventId) }

    var body: some View {
        ScrollView {
            if let page {
                VStack(alignment: .leading, spacing: 20) {
                    if !isPracticeSet { studyButton(page) }
                    if !page.parts.isEmpty {
                        Button { testPhase = .setup } label: {
                            Label("Test Yourself on This Guide", systemImage: "checklist")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GRASPQuietButton())
                    }
                    if importing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Reading guide…").graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                        }
                    }
                    if let message {
                        Text(message).graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                    }
                    ExamGuideContent(page: page, decks: decks) { openPage = $0 }
                }
                .padding(16)
            } else {
                ContentUnavailableView("Exam not found", systemImage: "calendar.badge.exclamationmark")
                    .padding(.top, 80)
            }
        }
        .background(GRASPColor.canvas)
        .fullScreenCover(item: $testPhase, onDismiss: load) { phase in
            if let page { testView(phase, page: page) }
        }
        .navigationTitle(page?.exam.title ?? "Exam")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isPracticeSet {
                        Button { choosingFiles = true } label: {
                            Label("Add Study Guide…", systemImage: "doc.badge.plus")
                        }
                        .disabled(importing)
                    }
                    if let page, !page.parts.isEmpty {
                        ForEach([true, false], id: \.self) { answerKey in
                            Section(answerKey ? "Study Guide with Answer Key" : "Practice Sheet, No Answers") {
                                ForEach(ExportFormat.allCases) { format in
                                    Button {
                                        if let doc = document(answerKey: answerKey) {
                                            DocumentExporter.save(doc, as: format)
                                        }
                                    } label: {
                                        Label(format.rawValue, systemImage: format.systemImage)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $openPage) { GuidePageSheet(target: $0) }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: Self.guideTypes,
                      allowsMultipleSelection: true) { outcome in
            if case .success(let urls) = outcome { addGuides(urls) }
        }
        .task(id: practiceGuideId ?? examEventId) { load() }
        .onChange(of: store.revision) { load() }
    }

    static let guideTypes: [UTType] = [.pdf, .png, .jpeg, .plainText, UTType(filenameExtension: "md") ?? .plainText]

    @ViewBuilder
    private func studyButton(_ page: StudyGuideActions.ExamPage) -> some View {
        if page.deckIds.isEmpty {
            Text("None of this exam's parts is matched to a lecture deck yet. Pick decks for a part below.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        } else {
            NavigationLink {
                DeckScreen(route: DeckRoute(scope: .exam(courseId: courseId, examEventId: examEventId),
                                            name: page.exam.title))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Study for this exam").graspType(.rowTitle)
                        Text(decks.filter { page.deckIds.contains($0.id) }.map(\.name).joined(separator: ", "))
                            .graspType(.meta)
                            .lineLimit(1)
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(GRASPColor.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func testView(_ phase: TestPhase, page: StudyGuideActions.ExamPage) -> some View {
        switch phase {
        case .setup:
            ScrollView {
                TestSetupSheet(deckIds: page.deckIds, deckName: page.exam.title,
                               onResume: { id in testPhase = TestPhase.resuming(id, store: store) },
                               guide: (page, testScopeKey)) { attemptId, questions, aiWarning in
                    testPhase = .running(attemptId: attemptId, questions: questions, aiWarning: aiWarning)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            }
        case .running(let attemptId, let questions, let aiWarning, let answered):
            TestRunView(attemptId: attemptId, deckName: page.exam.title, questions: questions, aiWarning: aiWarning,
                        answered: answered) { graded in
                _ = try? store.finishTest(attemptId: attemptId)
                testPhase = .results(attemptId: attemptId, graded: graded)
            }
        case .results(let attemptId, let graded):
            TestResultsView(deckName: page.exam.title, attemptId: attemptId, graded: graded, deckIds: page.deckIds) { id, questions in
                testPhase = .running(attemptId: id, questions: questions, aiWarning: nil)
            }
        }
    }

    private func load() {
        if let practiceGuideId {
            page = store.practicePage(guideId: practiceGuideId)
        } else {
            page = store.examPage(examEventId: examEventId)
        }
        decks = (try? store.decks(inCourse: courseId)) ?? []
    }

    private func document(answerKey: Bool) -> ExportDocument? {
        guard let page else { return nil }
        let names = Dictionary(decks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return StudyGuideExport.document(page: page, deckNames: names, answerKey: answerKey)
    }

    private func addGuides(_ picked: [URL]) {
        importing = true
        message = nil
        Task {
            defer { importing = false }
            do {
                let copies = try ImportScreen.copyIntoLibrary(picked, courseId: courseId)
                let summary = await store.importStudyGuides(copies, intoCourse: courseId, examEventId: examEventId)
                if summary.studyGuidesImported == 0 {
                    message = "That file didn't read as a study guide. Guides are recognized by name, "
                        + "like \"Exam 1 Study Guide\" or \"Midterm Review\"."
                }
            } catch {
                message = "Couldn't add the guide: \(error.localizedDescription)"
            }
            load()
        }
    }
}

/// A course's exams that have study guides, for `CourseView`.
struct ExamRow: View {
    let exam: CalendarEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "graduationcap").foregroundStyle(GRASPColor.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(exam.title).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                Text("\(exam.startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(exam.countdownText())")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            }
        }
    }
}
