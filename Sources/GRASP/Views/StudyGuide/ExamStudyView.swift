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
    /// Set for a guide with no exam (a practice set): the page is that
    /// one guide, with no Study tab and nothing to add to.
    var practiceGuideId: String? = nil

    private var isPracticeSet: Bool { practiceGuideId != nil }

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
    @State private var testPhase: TestPhase?

    private var testScopeKey: String { "guide:" + (practiceGuideId ?? examEventId) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !isPracticeSet {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                if importing {
                    ProgressView().controlSize(.small)
                    Text("Reading guide…")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
                if let page, !page.parts.isEmpty {
                    Button { testPhase = .setup } label: {
                        Label("Test", systemImage: "checklist")
                    }
                    .buttonStyle(GRASPQuietButton())
                    .help("A graded quiz on this study guide: its terms and AI-written questions about each part")
                    Menu {
                        // Flat: each format is one click away, grouped by
                        // which version of the guide it saves.
                        ForEach([true, false], id: \.self) { answerKey in
                            Section(answerKey ? "Study Guide with Answer Key" : "Practice Sheet, No Answers") {
                                ForEach(ExportFormat.allCases) { format in
                                    Button {
                                        if let document = exportDocument(answerKey: answerKey) {
                                            DocumentExporter.save(document, as: format)
                                        }
                                    } label: {
                                        Label(format.rawValue, systemImage: format.systemImage)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Download", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Save this exam's guide as a PDF, Word document or Markdown file")
                }
                if !isPracticeSet {
                    Button("Add Study Guide…", action: addGuide)
                        .buttonStyle(GRASPQuietButton())
                        .disabled(importing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)

            switch isPracticeSet ? .guide : tab {
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
        .sheet(item: $testPhase, onDismiss: load) { phase in
            if let page { testSheet(phase, page: page) }
        }
        .task(id: practiceGuideId ?? examEventId) { load() }
        .onChange(of: store.revision) { load() }
    }

    @ViewBuilder
    private func testSheet(_ phase: TestPhase, page: StudyGuideActions.ExamPage) -> some View {
        switch phase {
        case .setup:
            TestSetupSheet(deckIds: page.deckIds, deckName: page.exam.title,
                           onResume: { id in testPhase = TestPhase.resuming(id, store: store) },
                           guide: (page, testScopeKey)) { attemptId, questions, aiWarning in
                testPhase = .running(attemptId: attemptId, questions: questions, aiWarning: aiWarning)
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

    private func exportDocument(answerKey: Bool) -> ExportDocument? {
        guard let page else { return nil }
        let names = Dictionary(decks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return StudyGuideExport.document(page: page, deckNames: names, answerKey: answerKey)
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
                ExamGuideContent(page: page, decks: decks) { target in
                    // The whole file opens in the Mac's own viewer; a page
                    // opens in the sheet, beside the problem that needs it.
                    if target.wholeFile { NSWorkspace.shared.open(target.url) } else { openPage = target }
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

