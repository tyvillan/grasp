import SwiftUI
import GRASPCore

/// The four places (Home, Calendar, Study guides, Library), then the current
/// term's courses with their full names and color dots, then catch-all
/// groups like Side Lectures, then every past term folded into one row.
/// The profile sits at the bottom.
///
/// Drawn by hand rather than as a `List` so selection can be GRASP's own: a
/// yellow bar that slides between rows (`matchedGeometryEffect`) and a bold
/// label, instead of the system's blue pill. Home, Calendar, Study guides
/// and Library share the one selection binding with the courses through
/// `ContentView`'s sentinel routes.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedCourseId: String?

    @State private var editingCourse: Course?
    @State private var deletingCourse: Course?
    @AppStorage("sidebarPastTermsOpen") private var pastTermsOpen = false
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    placeRow(.home, "Home", route: ContentView.homeRoute)
                    placeRow(.calendar, "Calendar", route: ContentView.calendarRoute)
                    placeRow(.studyGuides, "Study guides", route: ContentView.studyGuideRoute)
                    placeRow(.library, "Library", route: ContentView.libraryRoute)

                    if let term = store.currentTerm {
                        groupLabel(term.name)
                        ForEach(store.courses(inSemester: term.id)) { courseRow($0) }
                    }

                    ForEach(store.nonTermSemesters) { semester in
                        groupLabel(semester.name)
                        ForEach(store.courses(inSemester: semester.id)) { courseRow($0) }
                    }
                    if !store.unfiledCourses.isEmpty {
                        groupLabel("No timeline")
                        ForEach(store.unfiledCourses) { courseRow($0) }
                    }

                    pastTerms
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .animation(Motion.thumb, value: selectedCourseId)
                // `pastTermsOpen` is stored in defaults, which drops the
                // surrounding `withAnimation`, so the list animates here.
                .animation(Motion.glideInOut, value: pastTermsOpen)
            }
            .scrollIndicators(.never)

            Rectangle().fill(GRASPColor.hairline).frame(height: 1).padding(.horizontal, 16)
            FeedbackFooterButton()
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProfileMenuButton(showsName: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.surface)
        .task { store.assignCourseColorsIfNeeded() }
        .onChange(of: store.revision) { store.assignCourseColorsIfNeeded() }
        .sheet(item: $editingCourse) { course in
            CourseEditSheet(course: course)
        }
        .courseDeleteConfirmation($deletingCourse) { deletedId in
            if selectedCourseId == deletedId { selectedCourseId = ContentView.homeRoute }
        }
    }

    // MARK: - Rows

    private func placeRow(_ glyph: SidebarGlyph, _ title: String, route: String) -> some View {
        SidebarRow(isSelected: isSelected(route), namespace: selection) { hovering in
            SidebarIcon(glyph: glyph, isHovering: hovering)
            Text(title)
        } action: {
            selectedCourseId = route
        }
    }

    private func isSelected(_ id: String) -> Bool {
        (selectedCourseId ?? ContentView.homeRoute) == id
    }

    private func courseRow(_ course: Course) -> some View {
        SidebarRow(isSelected: isSelected(course.id), namespace: selection) { hovering in
            CourseDot(color: store.courseColor(course), size: 8)
                .scaleEffect(hovering && !Motion.isReduced ? 1.3 : 1)
                .animation(Motion.bouncy, value: hovering)
                .frame(width: 20)
            Text(course.name)
                .fixedSize(horizontal: false, vertical: true)
        } action: {
            selectedCourseId = course.id
        }
        .help(course.code.map { "\(course.name) (\($0))" } ?? course.name)
        .rowActions(inline: true) {
            CourseContextMenu(
                course: course,
                onEdit: { editingCourse = course },
                onArchive: {
                    // Archiving hides a course from the sidebar, so leaving
                    // it selected would strand the detail pane on a course
                    // with no row to show it as selected.
                    let isArchiving = !course.isArchived
                    try? store.setCourseArchived(course.id, archived: isArchiving)
                    if isArchiving, selectedCourseId == course.id {
                        selectedCourseId = ContentView.homeRoute
                    }
                },
                onDelete: { deletingCourse = course }
            )
        }
    }

    private func groupLabel(_ text: String) -> some View {
        SectionLabel(text)
            .padding(.leading, 10)
            .padding(.top, 22)
            .padding(.bottom, 6)
    }

    /// Every older term behind one row. Opens in place; a selected course
    /// inside it keeps it open.
    @ViewBuilder
    private var pastTerms: some View {
        let terms = store.pastTerms
        if !terms.isEmpty {
            let count = terms.reduce(0) { $0 + store.courses(inSemester: $1.id).count }
            let containsSelection = terms.contains { term in
                store.courses(inSemester: term.id).contains { $0.id == selectedCourseId }
            }
            let open = pastTermsOpen || containsSelection
            Button {
                withAnimation(Motion.snappy) { pastTermsOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.graspUI(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("Past terms")
                    Spacer(minLength: 6)
                    Text("\(count) course\(count == 1 ? "" : "s")")
                        .monospacedDigit()
                }
                .font(.graspUI(size: 13))
                .foregroundStyle(GRASPColor.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .accessibilityLabel(open ? "Hide past terms" : "Show past terms, \(count) courses")

            if open {
                // One container, so the whole list arrives as a single
                // fade-and-rise rather than row by row.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(terms) { term in
                        groupLabel(term.name)
                        ForEach(store.courses(inSemester: term.id)) { courseRow($0) }
                    }
                }
                .transition(Motion.slide(from: .top, distance: 8))
            }
        }
    }
}

/// One sidebar row: content on the left, the sliding yellow bar when
/// selected, a raised fill on hover.
private struct SidebarRow<Label: View>: View {
    let isSelected: Bool
    let namespace: Namespace.ID
    @ViewBuilder let label: (_ hovering: Bool) -> Label
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                label(hovering)
            }
            .font(.graspUI(size: 14, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? GRASPColor.textPrimary : GRASPColor.textSecondary)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && !isSelected ? GRASPColor.surfaceRaised : .clear)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(GRASPColor.brand)
                        .frame(width: 3, height: 20)
                        .offset(x: -6)
                        .matchedGeometryEffect(id: "sidebar-selection", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Send feedback", quiet, just above the profile button at the bottom of the sidebar.
private struct FeedbackFooterButton: View {
    @State private var hovering = false

    var body: some View {
        Button { FeedbackLauncher.open() } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.graspUI(size: 12.5, weight: .medium))
                Text("Send feedback")
                    .font(.graspUI(size: 13, weight: .medium))
            }
            .foregroundStyle(hovering ? GRASPColor.textPrimary : GRASPColor.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Tell us what's working, what's confusing, or what you wish it did")
        .accessibilityLabel("Send feedback")
    }
}
