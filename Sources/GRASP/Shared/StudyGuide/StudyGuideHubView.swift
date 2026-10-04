import SwiftUI
import GRASPCore

/// Where a row of the Study Guide page leads.
enum StudyGuideHubTarget: Hashable {
    case exam(courseId: String, examEventId: String)
    /// A guide with no exam, such as one GRASP wrote.
    case practice(courseId: String, guideId: String)
}

/// The Study Guide page: every course's guides in one place, upcoming
/// exams first and past ones kept below, plus practice sets GRASP wrote.
/// An exam's guide used to be reachable only while its exam was still
/// ahead of you; this is where it stays.
///
/// Shared by the Mac (a sidebar item beside Home and Calendar) and the
/// iPhone (a tab). Each app supplies the page a row opens.
struct StudyGuideHubView<Destination: View>: View {
    @Environment(AppStore.self) private var store
    @ViewBuilder let destination: (StudyGuideHubTarget) -> Destination

    @State private var courses: [StudyGuideActions.HubCourse] = []
    @State private var path: [StudyGuideHubTarget] = []
    @State private var showingGenerator = false

    private var job: AppStore.AIJob? { store.aiJob(AppStore.studyGuideJobKey) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if let job {
                    AIProgressStrip(
                        activity: job.activity,
                        onStop: { store.stopAIJob(AppStore.studyGuideJobKey) },
                        stopHelp: "Stops now. Guides already saved are kept."
                    )
                } else if let run = store.lastStudyGuideRun {
                    resultBanner(run)
                }
                content
            }
            .background(GRASPColor.canvas)
            .navigationTitle("Study Guides")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingGenerator = true
                    } label: {
                        Label("New Study Guide…", systemImage: "wand.and.stars")
                    }
                    .disabled(job != nil)
                    .help("Write a practice guide from your decks' notes")
                }
            }
            .navigationDestination(for: StudyGuideHubTarget.self) { destination($0) }
        }
        .sheet(isPresented: $showingGenerator) { GenerateStudyGuideSheet() }
        .task { load() }
        .onChange(of: store.revision) { load() }
    }

    private func load() { courses = store.studyGuideHub() }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if courses.isEmpty {
            ContentUnavailableView {
                Label("No study guides yet", systemImage: "graduationcap")
            } description: {
                Text("Add a professor's or your own exam guide from a course's Add Study Guide button, "
                     + "or have GRASP write a practice guide from your lecture decks.")
            } actions: {
                Button("New Study Guide…") { showingGenerator = true }
                    .buttonStyle(GRASPProminentButton())
                    .disabled(job != nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(courses) { course in courseBlock(course) }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func courseBlock(_ course: StudyGuideActions.HubCourse) -> some View {
        let upcoming = course.exams.filter { !$0.isPast }
        let past = course.exams.filter(\.isPast)
        return VStack(alignment: .leading, spacing: 10) {
            Text(course.course.name)
                .graspType(.display)
                .foregroundStyle(GRASPColor.textPrimary)
            if !upcoming.isEmpty {
                group("Upcoming exams", upcoming.map { examRow($0, in: course.course) })
            }
            if !course.practiceSets.isEmpty {
                group("Practice sets", course.practiceSets.map { practiceRow($0, in: course.course) })
            }
            if !past.isEmpty {
                group("Past exams", past.map { examRow($0, in: course.course) })
            }
        }
    }

    private func group(_ title: String, _ rows: [some View]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textTertiary)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                    row
                }
            }
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(GRASPColor.hairline))
        }
    }

    private func examRow(_ entry: StudyGuideActions.HubExam, in course: Course) -> some View {
        let date = entry.exam.startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let when = entry.isPast ? "\(date) · past" : "\(date) · \(entry.exam.countdownText())"
        return row(
            icon: "graduationcap" + (entry.isPast ? "" : ".fill"),
            title: entry.exam.title,
            subtitle: "\(when) · \(entry.guides.count) guide\(entry.guides.count == 1 ? "" : "s")",
            target: .exam(courseId: course.id, examEventId: entry.exam.id),
            dimmed: entry.isPast
        )
    }

    private func practiceRow(_ guide: StudyGuide, in course: Course) -> some View {
        let parts = guide.document()?.parts.count ?? 0
        let made = guide.createdAt.formatted(.dateTime.month(.abbreviated).day())
        return row(
            icon: guide.parser.hasPrefix("ai:") ? "wand.and.stars" : "doc.text",
            title: guide.title,
            subtitle: "\(parts) part\(parts == 1 ? "" : "s") · \(guide.parser.hasPrefix("ai:") ? "written" : "added") \(made)",
            target: .practice(courseId: course.id, guideId: guide.id),
            dimmed: false
        )
    }

    private func row(icon: String, title: String, subtitle: String, target: StudyGuideHubTarget,
                     dimmed: Bool) -> some View {
        NavigationLink(value: target) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(dimmed ? GRASPColor.textTertiary : GRASPColor.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .graspType(.rowTitle)
                        .foregroundStyle(dimmed ? GRASPColor.textSecondary : GRASPColor.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - After a run

    private func resultBanner(_ run: AppStore.StudyGuideRunResult) -> some View {
        let failed = run.failure != nil
        return HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(failed ? GRASPColor.rejected : GRASPColor.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.failure ?? (run.guideIds.isEmpty ? "Nothing was written."
                     : "Wrote \(run.guideIds.count) practice guide\(run.guideIds.count == 1 ? "" : "s")"
                       + (run.wasStopped ? " before you stopped it." : ".")))
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                if !run.skippedDecks.isEmpty, !failed {
                    Text("No usable practice for: \(run.skippedDecks.joined(separator: ", ")).")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if let first = run.guideIds.first, let target = target(forGuide: first) {
                Button("Open") {
                    store.dismissStudyGuideRun()
                    path.append(target)
                }
                .buttonStyle(GRASPQuietButton())
            }
            Button("Dismiss") { store.dismissStudyGuideRun() }
                .buttonStyle(GRASPQuietButton())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background((failed ? GRASPColor.rejectedSoft : GRASPColor.accentSoft).opacity(0.55))
        .background(alignment: .bottom) { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
    }

    private func target(forGuide id: String) -> StudyGuideHubTarget? {
        for course in courses {
            if let exam = course.exams.first(where: { $0.guides.contains { $0.id == id } }) {
                return .exam(courseId: course.course.id, examEventId: exam.exam.id)
            }
            if course.practiceSets.contains(where: { $0.id == id }) {
                return .practice(courseId: course.course.id, guideId: id)
            }
        }
        return nil
    }
}
