import Foundation
import GRASPCore
import SwiftCrossUI

/// What a course or deck sheet is open for.
enum OrganizeSheet {
    case editCourse(Course)
    /// Done at once, not a sheet; the course reappears from Settings.
    case archive(Course)
    case newCourse
    case deleteCourse(Course)
    case newDeck(courseId: String)
    case renameDeck(DeckRow)
    case deleteDeck(DeckRow)
}

/// The sheet for an `OrganizeSheet`.
struct OrganizeSheetView: View {
    let library: Library
    let sheet: OrganizeSheet
    /// Called with a new course's or deck's id, so the caller can open it.
    var onCreated: (String) -> Void = { _ in }
    /// Called after a course or deck is deleted.
    var onDeleted: () -> Void = {}
    let close: () -> Void

    var body: some View {
        switch sheet {
        case .editCourse(let course):
            CourseEditor(library: library, course: course, close: close)
        case .archive:
            EmptyView()
        case .newCourse:
            CourseEditor(library: library, course: nil, onCreated: onCreated, close: close)
        case .deleteCourse(let course):
            CourseDeleteConfirmation(library: library, course: course, onDeleted: onDeleted, close: close)
        case .newDeck(let courseId):
            DeckNameEditor(library: library, courseId: courseId, deck: nil, onCreated: onCreated, close: close)
        case .renameDeck(let deck):
            DeckNameEditor(library: library, courseId: deck.courseId, deck: deck, close: close)
        case .deleteDeck(let deck):
            DeckDeleteConfirmation(library: library, deck: deck, onDeleted: onDeleted, close: close)
        }
    }
}

// MARK: - Courses

/// Rename a course, give it a code, a colour and a timeline, after the
/// Mac's `CourseEditSheet` -- or add a course by hand. The vault folder is
/// shown read-only: it's what the importer matches on.
private struct CourseEditor: View {
    let library: Library
    let original: Course?
    var onCreated: (String) -> Void = { _ in }
    let close: () -> Void

    @State var name: String
    @State var code: String
    @State var colorHex: String?
    @State var timeline: String

    init(library: Library, course: Course?, onCreated: @escaping (String) -> Void = { _ in }, close: @escaping () -> Void) {
        self.library = library
        self.original = course
        self.onCreated = onCreated
        self.close = close
        _name = State(wrappedValue: course?.name ?? "")
        _code = State(wrappedValue: course?.code ?? "")
        _colorHex = State(wrappedValue: course?.colorHex)
        _timeline = State(wrappedValue: library.semesterName(course?.semesterId))
    }

    /// The Mac's palette.
    static let palette: [(name: String, hex: String)] = [
        ("Amber", "F2B84B"), ("Teal", "5FC9B5"), ("Rose", "E2725B"),
        ("Violet", "9B8BF4"), ("Sky", "5AA9E6"), ("Lime", "A3C644"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New Course" : "Edit Course")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            field("Name") { TextField("Course name", text: $name) }
            field("Course code") { TextField("e.g. COP 3014", text: $code) }
            field("Color") {
                HStack(spacing: 10) {
                    ForEach(Self.palette, id: \.hex) { swatch in
                        Circle()
                            .fill(Color(hex: swatch.hex))
                            .frame(width: colorHex == swatch.hex ? 26.0 : 20.0, height: colorHex == swatch.hex ? 26.0 : 20.0)
                            .onTapGesture { colorHex = colorHex == swatch.hex ? nil : swatch.hex }
                    }
                }
                .frame(height: 28.0)
            }
            field("Timeline") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g. Fall 2026 (leave empty for No Timeline)", text: $timeline)
                    if original?.folderPath != nil {
                        Text("Changing this here sticks -- importing again never overwrites a course's timeline once it's set.")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let original {
                Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
                VStack(alignment: .leading, spacing: 4) {
                    if let folder = original.folderPath {
                        SectionLabel("Source folder")
                        Text(folder).font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
                    } else {
                        Text("Added by hand -- no notes folder, so importing won't add notes to it.")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textSecondary)
                    }
                    let notes = library.materialCount(inCourse: original.id)
                    Text("\(notes) imported file\(notes == 1 ? "" : "s")")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { close() }.fixedSize()
                Button(original == nil ? "Add Course" : "Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 460.0)
        .background(GRASPColor.canvas)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(label)
            content()
        }
    }

    private func save() {
        let trimmedCode = code.trimmingCharacters(in: .whitespaces)
        if var course = original {
            course.name = name
            course.code = trimmedCode.isEmpty ? nil : trimmedCode
            course.colorHex = colorHex
            library.saveCourse(course, timeline: timeline)
            close()
        } else {
            let id = library.addCourse(name: name, code: trimmedCode.isEmpty ? nil : trimmedCode, timeline: timeline)
            if let id, let colorHex, var course = library.course(id) {
                course.colorHex = colorHex
                library.saveCourse(course, timeline: timeline)
            }
            close()
            if let id { onCreated(id) }
        }
    }
}

/// "Delete Biology?", with what it removes in numbers, as on the Mac. Every
/// delete also excludes the course's notes folder, so importing again
/// doesn't bring it back.
private struct CourseDeleteConfirmation: View {
    let library: Library
    let course: Course
    let onDeleted: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(course.name)?")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            Text(message)
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { close() }.fixedSize()
                Button("Delete") {
                    library.deleteCourse(course.id)
                    close()
                    onDeleted()
                }
                .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 440.0)
        .background(GRASPColor.canvas)
    }

    private var message: String {
        var message: String
        if let impact = library.courseDeletionImpact(course.id) {
            message = "Removes \(impact.cards) card\(impact.cards == 1 ? "" : "s")"
            if impact.reviews > 0 {
                message += " and \(impact.reviews) review\(impact.reviews == 1 ? "" : "s") of study history"
            }
        } else {
            message = "Removes its cards and any study history for it"
        }
        message += ". Your notes are never touched"
        if course.folderPath != nil {
            message += ", and importing your notes again won't bring this course back."
        } else {
            message += "."
        }
        message += " It also disappears from your Mac and iPhone at the next sync."
        return message
    }
}

// MARK: - Decks

/// A new deck ("a custom module or unit for cards you organise by hand"),
/// or a new name for one.
private struct DeckNameEditor: View {
    let library: Library
    let courseId: String
    let deck: DeckRow?
    var onCreated: (String) -> Void = { _ in }
    let close: () -> Void
    @State var name: String

    init(library: Library, courseId: String, deck: DeckRow?, onCreated: @escaping (String) -> Void = { _ in },
         close: @escaping () -> Void) {
        self.library = library
        self.courseId = courseId
        self.deck = deck
        self.onCreated = onCreated
        self.close = close
        _name = State(wrappedValue: deck?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(deck == nil ? "New Deck" : "Rename Deck")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            if deck == nil {
                Text("A custom module or unit for cards you organize by hand.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
            }
            TextField("Deck name (e.g. Midterm Review)", text: $name)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { close() }.fixedSize()
                Button(deck == nil ? "Create" : "Save") {
                    if let deck {
                        library.renameDeck(deck.id, to: name)
                        close()
                    } else {
                        let id = library.createDeck(courseId: courseId, name: name)
                        close()
                        if let id { onCreated(id) }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 400.0)
        .background(GRASPColor.canvas)
    }
}

/// Deleting a deck that has cards asks where they go: another deck in the
/// course, or away with the deck. An empty deck just goes.
private struct DeckDeleteConfirmation: View {
    let library: Library
    let deck: DeckRow
    let onDeleted: () -> Void
    let close: () -> Void
    @State var moveTo: String?
    @State var deleteCards = false

    var body: some View {
        let count = library.deckCardCount(deck.id)
        let siblings = library.decks(inCourse: deck.courseId).filter { $0.id != deck.id }
            .map { Choice(id: $0.id, description: $0.name) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \"\(deck.name)\"?")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            if count == 0 {
                Text("The deck is empty.").font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
            } else {
                Text("This deck has \(count) card\(count == 1 ? "" : "s"). Choose what happens to them.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                if !siblings.isEmpty {
                    Pill(title: "Move them to another deck", isOn: !deleteCards) { deleteCards = false }
                    if !deleteCards {
                        Picker(of: siblings, selection: Binding(
                            get: { siblings.first { $0.id == (moveTo ?? siblings.first?.id) } },
                            set: { moveTo = $0?.id }
                        ))
                    }
                }
                Pill(title: "Delete them too (their study history is kept)", isOn: deleteCards || siblings.isEmpty) {
                    deleteCards = true
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { close() }.fixedSize()
                Button("Delete Deck") {
                    let target = (count == 0 || deleteCards || siblings.isEmpty) ? nil : (moveTo ?? siblings.first?.id)
                    library.deleteDeck(deck.id, movingCardsTo: target)
                    close()
                    onDeleted()
                }
                .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 440.0)
        .background(GRASPColor.canvas)
    }
}
