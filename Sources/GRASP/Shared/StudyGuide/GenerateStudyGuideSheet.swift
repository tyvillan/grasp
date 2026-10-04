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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Study Guide").font(.headline)
                Text("Pick the courses and decks to practice. GRASP writes practice problems with worked answers, "
                     + "sample test questions and key terms from each deck's notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    coursesSection
                    ForEach(courses.filter { selectedCourses.contains($0.id) }) { course in
                        decksSection(course)
                    }
                    optionsSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        #if os(macOS)
        .frame(width: 540, height: 640)
        #endif
        .task { load() }
    }

    // MARK: - Sections

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .graspType(.eyebrow)
            .textCase(.uppercase)
            .foregroundStyle(GRASPColor.textTertiary)
    }

    private func checkRow(_ title: String, subtitle: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? GRASPColor.accent : GRASPColor.textTertiary)
                Text(title).foregroundStyle(GRASPColor.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.caption.weight(.semibold)).foregroundStyle(GRASPColor.accent)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var coursesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Courses")
            if courses.isEmpty {
                Text("No courses have decks yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(courses) { course in
                checkRow(course.name, isOn: selectedCourses.contains(course.id)) { toggle(course) }
            }
        }
    }

    private func decksSection(_ course: Course) -> some View {
        let decks = decksByCourse[course.id] ?? []
        let allOn = decks.allSatisfy { selectedDecks.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Decks · \(course.name)")
                Spacer()
                Button(allOn ? "Select None" : "Select All") {
                    if allOn { decks.forEach { selectedDecks.remove($0.id) } } else { decks.forEach { selectedDecks.insert($0.id) } }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(GRASPColor.accent)
            }
            ForEach(decks) { deck in
                checkRow(deck.name, subtitle: kickers[deck.id], isOn: selectedDecks.contains(deck.id)) {
                    if selectedDecks.contains(deck.id) { selectedDecks.remove(deck.id) } else { selectedDecks.insert(deck.id) }
                }
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Options")
            Picker("Practice problems per deck", selection: $problemsPerDeck) {
                ForEach([3, 5, 8], id: \.self) { Text("\($0)").tag($0) }
            }
            if !exams.isEmpty {
                Picker("Attach to an exam", selection: $examId) {
                    Text("None -- a practice set").tag("")
                    ForEach(exams) { exam in
                        Text("\(exam.title) · \(exam.startsAt.formatted(.dateTime.month(.abbreviated).day()))")
                            .tag(exam.id)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.isGeneratorAvailable {
                Label("No AI model is set up. Settings → AI has the setup.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(GRASPColor.rejected)
            } else {
                Text("Written by \(store.generatorStatus).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.aiMode.usesCloud, store.hasCloudKey {
                    Label("Your notes for these decks are sent to Google Gemini. Its free tier may use what you send "
                          + "to improve Google's products.", systemImage: "cloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let warning = AIQuotaEstimate.warning(needed: requestEstimate, mode: store.aiMode) {
                        Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text(selectedDecks.isEmpty ? "Nothing selected" : summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Write Guide") {
                    store.generateStudyGuides(
                        courseIds: orderedSelectedCourseIds, deckIds: Array(selectedDecks),
                        problemsPerDeck: problemsPerDeck, examEventId: examId.isEmpty ? nil : examId
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canWrite)
            }
        }
        .padding(20)
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
        if courses.count == 1, let only = courses.first { toggle(only) }
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
