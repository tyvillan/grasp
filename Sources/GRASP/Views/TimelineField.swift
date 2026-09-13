import SwiftUI
import GRASPCore

/// A course's timeline as freeform text with autocomplete, not a fixed
/// term/year dropdown -- "Fall 2026", "2026-2027", "Quarter 1" are all
/// valid. The binding is plain text, not a semester id: resolving it to an
/// actual `Semester` row (reusing one with a matching name, or creating a
/// new one) only happens once, when the caller saves -- see
/// `AppStore.findOrCreateSemester(name:)`, and `CourseEditSheet` /
/// `AddCourseSheet` for where that resolution runs. Resolving on every
/// keystroke would mean an abandoned partial edit could still leave behind
/// an orphan semester row.
struct TimelineField: View {
    @Environment(AppStore.self) private var store
    @Binding var text: String
    /// When false, the "No Timeline" quick-clear isn't offered -- used by
    /// `AddCourseSheet`, which requires picking a timeline up front.
    var allowsNoTimeline: Bool = true

    @FocusState private var isFocused: Bool

    private var suggestions: [Semester] {
        guard isFocused else { return [] }
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        return store.semesters.reversed().filter { semester in
            query.isEmpty || semester.name.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Timeline (e.g. Fall 2026)", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                if allowsNoTimeline, !text.isEmpty {
                    Button("No Timeline") { text = "" }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if isFocused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions.prefix(6)) { semester in
                        Button {
                            text = semester.name
                            isFocused = false
                        } label: {
                            Text(semester.name)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(GRASPColor.hairline)
                )
            }
        }
    }
}
