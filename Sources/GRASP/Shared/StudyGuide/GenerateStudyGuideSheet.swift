import SwiftUI
import GRASPCore

/// "New Study Guide": pick courses, pick decks within them, and GRASP
/// writes a practice guide -- skills, worked practice problems with
/// answers, sample test questions and key terms -- one part per deck,
/// from that deck's notes. It can be attached to an exam, so it shows up
/// on that exam's page beside any guide you imported.
struct GenerateStudyGuideSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Opened from an exam row: that course is ticked and the guide is
    /// attached to that exam.
    var presetCourseId: String? = nil
    var presetExamId: String? = nil

    @State private var courses: [Course] = []
    @State private var decksByCourse: [String: [Deck]] = [:]
    @State private var kickers: [String: String] = [:]
    @State private var selectedCourses: Set<String> = []
    @State private var selectedDecks: Set<String> = []
    @State private var problemsPerDeck = 5
    @State private var examId = ""
    @State private var exams: [CalendarEvent] = []

    private var orderedSelectedCourseIds: [String] { courses.map(\.id).filter(selectedCourses.contains) }
    private var requestEstimate: Int { AIQuotaEstimate.studyGuideRequests(decks: selectedDecks.count) }
    /// "6 decks · about 6 requests · roughly 8 min": a local model takes
    /// well over a minute a deck (measured: 78 s on a 9B model); the cloud
    /// takes seconds, paced by the free tier's request limit.
    private var summary: String {
        let decks = selectedDecks.count
        let seconds = decks * (store.aiMode.usesCloud && store.hasCloudKey ? 15 : 80)
        let time = seconds < 90 ? "under 2 min" : "roughly \(Int((Double(seconds) / 60).rounded())) min"
        return "\(decks) deck\(decks == 1 ? "" : "s") · about \(requestEstimate) request\(requestEstimate == 1 ? "" : "s") · \(time)"
    }

    private var canWrite: Bool { store.isGeneratorAvailable && !selectedDecks.isEmpty }

    var body: some View {
        GRASPSheet(
            eyebrow: "Study guide", title: "New study guide",
            message: "Pick the courses and decks to practice. GRASP writes practice problems with worked answers, "
                + "sample test questions and key terms from each deck's notes.",
            icon: AIGlyph.symbol, width: 560, height: 660
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    coursesSection
                    ForEach(courses.filter { selectedCourses.contains($0.id) }) { course in
                        decksSection(course)
                    }
                    optionsSection
                    notices
                }
            }
        } footer: {
            Text(selectedDecks.isEmpty ? "Nothing selected" : summary)
                .graspType(.meta)
                .monospacedDigit()
                .foregroundStyle(GRASPColor.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                store.generateStudyGuides(
                    courseIds: orderedSelectedCourseIds, deckIds: Array(selectedDecks),
                    problemsPerDeck: problemsPerDeck, examEventId: examId.isEmpty ? nil : examId
                )
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AIGlyph.symbol).font(.graspUI(size: 11, weight: .semibold))
                    Text("Write guide")
                }
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(!canWrite)
        }
        .task { load() }
    }

    // MARK: - Sections

    private func checkRow(_ title: String, subtitle: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).graspType(.body)
                if let subtitle {
                    Text(subtitle).font(.graspUI(size: 11.5, weight: .semibold)).foregroundStyle(GRASPColor.accent)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private var coursesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Courses")
                .padding(.bottom, 2)
            if courses.isEmpty {
                Text("No courses have decks yet.").graspType(.body).foregroundStyle(GRASPColor.textSecondary)
            }
            ForEach(courses) { course in
                checkRow(course.name, isOn: selectedCourses.contains(course.id)) { toggle(course) }
            }
        }
        .popupGroup()
    }

    private func decksSection(_ course: Course) -> some View {
        let decks = decksByCourse[course.id] ?? []
        let allOn = decks.allSatisfy { selectedDecks.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Decks · \(course.name)")
                Spacer()
                Button(allOn ? "Select none" : "Select all") {
                    if allOn { decks.forEach { selectedDecks.remove($0.id) } } else { decks.forEach { selectedDecks.insert($0.id) } }
                }
                .buttonStyle(.plain)
                .font(.graspUI(size: 12, weight: .semibold))
                .foregroundStyle(GRASPColor.accent)
            }
            .padding(.bottom, 2)
            ForEach(decks) { deck in
                checkRow(deck.name, subtitle: kickers[deck.id], isOn: selectedDecks.contains(deck.id)) {
                    if selectedDecks.contains(deck.id) { selectedDecks.remove(deck.id) } else { selectedDecks.insert(deck.id) }
                }
            }
        }
        .popupGroup()
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Options")
            HStack {
                Text("Practice problems per deck").graspType(.body)
                Spacer()
                GRASPSegmented(selection: $problemsPerDeck, options: [3, 5, 8].map { ($0, "\($0)") })
            }
            if !exams.isEmpty {
                HStack {
                    Text("Attach to an exam").graspType(.body)
                    Spacer()
                    GRASPPicker(
                        selection: $examId,
                        options: [("", "None, a practice set")] + exams.map {
                            ($0.id, "\($0.title) · \($0.startsAt.formatted(.dateTime.month(.abbreviated).day()))")
                        }
                    )
                    .frame(maxWidth: 260)
                }
            }
        }
        .popupGroup()
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.isGeneratorAvailable {
                Label("No AI model is set up. Settings → AI has the setup.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(GRASPColor.rejected)
            } else {
                Text("Written by \(store.generatorStatus).")
                if store.aiMode.usesCloud, store.hasCloudKey {
                    Label("Your notes for these decks are sent to Google Gemini. Its free tier may use what you send "
                          + "to improve Google's products.", systemImage: "cloud")
                    if let warning = AIQuotaEstimate.warning(needed: requestEstimate, mode: store.aiMode) {
                        Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
            }
        }
        .graspType(.meta)
        .foregroundStyle(GRASPColor.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - State

    private func load() {
        let ordered = store.semesters.reversed().flatMap { store.courses(inSemester: $0.id) } + store.unfiledCourses
        courses = ordered.filter { store.hasDecks(inCourse: $0.id) }
        for course in courses {
            let decks = (try? store.decks(inCourse: course.id)) ?? []
            decksByCourse[course.id] = decks
            kickers.merge(store.deckKickers(for: decks)) { first, _ in first }
        }
        if let presetCourseId, let preset = courses.first(where: { $0.id == presetCourseId }) {
            toggle(preset)
            if let presetExamId, exams.contains(where: { $0.id == presetExamId }) { examId = presetExamId }
        } else if courses.count == 1, let only = courses.first {
            toggle(only)
        }
    }

    private func toggle(_ course: Course) {
        let decks = decksByCourse[course.id] ?? []
        if selectedCourses.contains(course.id) {
            selectedCourses.remove(course.id)
            decks.forEach { selectedDecks.remove($0.id) }
        } else {
            selectedCourses.insert(course.id)
            decks.forEach { selectedDecks.insert($0.id) }
        }
        exams = store.examEvents(inCourses: orderedSelectedCourseIds)
        if !exams.contains(where: { $0.id == examId }) { examId = "" }
    }
}
