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
    /// False when pushed inside a stack that already exists (the iPhone's
    /// Courses tab), so there is no second stack nested in the first.
    var standalone = true
    /// Set on the Mac, which has no navigation stack here: rows call this
    /// instead of pushing.
    var onOpen: ((StudyGuideHubTarget) -> Void)? = nil
    @ViewBuilder let destination: (StudyGuideHubTarget) -> Destination

    @State private var courses: [StudyGuideActions.HubCourse] = []
    @State private var openTarget: StudyGuideHubTarget?
    @State private var showingGenerator = false
    /// Courses whose full list of upcoming exams is showing.
    @State private var expandedCourses: Set<String> = []
    /// Set when "Make a study guide" is pressed on an exam row.
    @State private var generatorPreset: (courseId: String, examId: String)?

    private var job: AppStore.AIJob? { store.aiJob(AppStore.studyGuideJobKey) }

    var body: some View {
        if standalone {
            NavigationStack { page }
        } else {
            page
        }
    }

    private var page: some View {
        Group {
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
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        generatorPreset = nil
                        showingGenerator = true
                    } label: {
                        Label("New Study Guide…", systemImage: "wand.and.stars")
                    }
                    .disabled(job != nil)
                    .help("Write a practice guide from your decks' notes")
                }
            }
            #endif
            .navigationDestination(for: StudyGuideHubTarget.self) { destination($0) }
            .navigationDestination(item: $openTarget) { destination($0) }
        }
        .sheet(isPresented: $showingGenerator) {
            GenerateStudyGuideSheet(presetCourseId: generatorPreset?.courseId, presetExamId: generatorPreset?.examId)
        }
        .task { load() }
        .onChange(of: store.revision) { load() }
    }

    /// Every upcoming exam is listed, guide or not, so the page never reads
    /// as a void while an exam is ahead. A past exam without a guide has
    /// nothing to offer and is left off.
    private func load() {
        let kept = store.studyGuideHub().filter { course in
            course.exams.contains { !$0.guides.isEmpty || !$0.isPast } || !course.practiceSets.isEmpty
        }
        // The course with the nearest exam first; courses with none ahead
        // keep their order after them.
        func soonest(_ course: StudyGuideActions.HubCourse) -> Date {
            course.exams.filter { !$0.isPast }.map(\.exam.startsAt).min() ?? .distantFuture
        }
        courses = kept.enumerated().sorted { a, b in
            let (x, y) = (soonest(a.element), soonest(b.element))
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if courses.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                pageHeader(showsAction: false)
                #endif
                ContentUnavailableView {
                    Label("No study guides yet", systemImage: "graduationcap")
                } description: {
                    Text("Add a professor's or your own exam guide from a course's Add Guide button, "
                         + "or have GRASP write a practice guide from your lecture decks.")
                } actions: {
                    Button("Create guide") { generatorPreset = nil; showingGenerator = true }
                        .buttonStyle(GRASPProminentButton())
                        .disabled(job != nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    #if os(macOS)
                    pageHeader(showsAction: true)
                    #endif
                    ForEach(Array(courses.enumerated()), id: \.element.id) { index, course in
                        courseBlock(course).revealOnAppear(index: index)
                    }
                }
                #if os(macOS)
                // The same column as Home and Library: it starts and ends
                // where they do, so the New study guide button sits at the
                // right edge.
                .padding(.horizontal, 40)
                .padding(.vertical, 32)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                #else
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                #endif
            }
        }
    }

    /// The Mac page's title and its one action (the window has no toolbar).
    private func pageHeader(showsAction: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Study guides")
                .graspType(.display)
                .foregroundStyle(GRASPColor.textPrimary)
            Spacer(minLength: GRASPSpace.m)
            if showsAction {
                Button {
                    generatorPreset = nil
                    showingGenerator = true
                } label: {
                    Label("New study guide", systemImage: "wand.and.stars")
                }
                .buttonStyle(GRASPProminentButton())
                .disabled(job != nil)
                .help("Write a practice guide from your decks' notes")
            }
        }
        .padding(.horizontal, showsAction ? 0 : 24)
        .padding(.top, showsAction ? 0 : 24)
    }

    private func courseBlock(_ course: StudyGuideActions.HubCourse) -> some View {
        let upcoming = course.exams.filter { !$0.isPast }
        let past = course.exams.filter { $0.isPast && !$0.guides.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            Text(course.course.name)
                .font(.graspDisplay(22))
                .tracking(-0.3)
                .foregroundStyle(GRASPColor.textPrimary)
            if !upcoming.isEmpty {
                let limit = 3
                let expanded = expandedCourses.contains(course.id)
                let shown = expanded ? upcoming : Array(upcoming.prefix(limit))
                group("Upcoming exams", shown.map { examRow($0, in: course.course) })
                if upcoming.count > limit {
                    Button(expanded ? "Show fewer" : "Show \(upcoming.count - limit) more") {
                        withAnimation(Motion.fade) {
                            if expanded { expandedCourses.remove(course.id) } else { expandedCourses.insert(course.id) }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.graspUI(size: 13, weight: .medium))
                    .foregroundStyle(GRASPColor.textSecondary)
                    .padding(.top, 2)
                }
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
            SectionLabel(title)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                    row
                }
            }
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous).strokeBorder(GRASPColor.hairline))
        }
    }

    private func examRow(_ entry: StudyGuideActions.HubExam, in course: Course) -> AnyView {
        let date = entry.exam.startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let when = entry.isPast ? "\(date) · past" : "\(date) · \(entry.exam.countdownText())"
        if entry.guides.isEmpty {
            return AnyView(missingGuideRow(entry, when: when, in: course))
        }
        return AnyView(row(
            icon: "graduationcap" + (entry.isPast ? "" : ".fill"),
            title: entry.exam.title,
            subtitle: "\(when) · \(entry.guides.count) guide\(entry.guides.count == 1 ? "" : "s")",
            target: .exam(courseId: course.id, examEventId: entry.exam.id),
            dimmed: entry.isPast
        ))
    }

    /// An exam with no guide: a muted line saying so and one outlined AI
    /// action. Not a link; there is nothing to open yet.
    private func missingGuideRow(_ entry: StudyGuideActions.HubExam, when: String, in course: Course) -> some View {
        let action = Button {
            generatorPreset = (course.id, entry.exam.id)
            showingGenerator = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: AIGlyph.symbol)
                    .font(.graspUI(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
                Text("Make a study guide")
            }
        }
        .buttonStyle(GRASPQuietButton())
        .disabled(job != nil)
        .help("Write a practice guide for this exam from your decks' notes")
        let text = VStack(alignment: .leading, spacing: 2) {
            Text(entry.exam.title)
                .graspType(.rowTitle)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(1)
            Text(when)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(1)
            Text("No study guide yet")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(1)
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "graduationcap")
                .font(.graspUI(size: 14))
                .foregroundStyle(GRASPColor.textTertiary)
                .frame(width: 22)
                .padding(.top, 2)
            #if os(macOS)
            text
            Spacer(minLength: 8)
            action.alignmentGuide(.top) { _ in 0 }
            #else
            VStack(alignment: .leading, spacing: 10) {
                text
                action
            }
            Spacer(minLength: 0)
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

    @ViewBuilder
    private func row(icon: String, title: String, subtitle: String, target: StudyGuideHubTarget,
                     dimmed: Bool) -> some View {
        if let onOpen {
            Button { onOpen(target) } label: {
                rowLabel(icon: icon, title: title, subtitle: subtitle, dimmed: dimmed)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: target) {
                rowLabel(icon: icon, title: title, subtitle: subtitle, dimmed: dimmed)
            }
            .buttonStyle(.plain)
        }
    }

    private func rowLabel(icon: String, title: String, subtitle: String, dimmed: Bool) -> some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.graspUI(size: 14))
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
                    .font(.graspUI(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
    }

    // MARK: - After a run

    private func resultBanner(_ run: AppStore.StudyGuideRunResult) -> some View {
        let failed = run.failure != nil
        return HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.graspUI(size: 12))
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
                    if let onOpen { onOpen(target) } else { openTarget = target }
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
