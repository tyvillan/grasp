import SwiftUI
import UniformTypeIdentifiers
import GRASPCore

/// Bring notes into a course from the Files app -- Markdown, PDFs, Word,
/// PowerPoint, notebooks, photos of notes, or a whole folder -- through the
/// same import pipeline as the Mac.
///
/// Picked files are copied into GRASP's own storage first. Files from the
/// Files app come with temporary access only; a copy stays readable for
/// re-imports later, and the copy is what syncs its cards everywhere.
struct ImportScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var courseId: String?
    @State private var newCourseName = ""
    @State private var creatingCourse = false
    @State private var choosingFiles = false
    @State private var isImporting = false
    @State private var result: String?

    private static let types: [UTType] = [
        UTType(filenameExtension: "md") ?? .plainText, .plainText, .pdf,
        UTType(filenameExtension: "docx") ?? .data, UTType(filenameExtension: "pptx") ?? .data,
        UTType(filenameExtension: "ipynb") ?? .json, .png, .jpeg, .folder,
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if creatingCourse {
                        TextField("New course name", text: $newCourseName)
                    } else {
                        Picker("Course", selection: $courseId) {
                            Text("Choose…").tag(String?.none)
                            ForEach(store.coursePickerGroups(), id: \.title) { group in
                                Section(group.title) {
                                    ForEach(group.courses) { Text($0.name).tag(Optional($0.id)) }
                                }
                            }
                        }
                    }
                    Button(creatingCourse ? "Pick an existing course instead" : "New course…") {
                        creatingCourse.toggle()
                    }
                } header: {
                    Text("Import into")
                }
                .graspSection()

                Section {
                    Button {
                        choosingFiles = true
                    } label: {
                        HStack {
                            Label("Choose Files or a Folder", systemImage: "folder")
                            Spacer()
                            if isImporting { ProgressView() }
                        }
                    }
                    .disabled(!hasCourse || isImporting)
                } footer: {
                    Text("Markdown, PDF, Word, PowerPoint, Jupyter notebooks, and photos of notes. Cards are made as drafts for you to review, and sync to your other devices.")
                }
                .graspSection()

                if let result {
                    Section("Result") { Text(result).graspType(.body) }
                        .graspSection()
                }
            }
            .graspList()
            .navigationTitle("Import Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: Self.types,
                          allowsMultipleSelection: true) { outcome in
                if case .success(let urls) = outcome { run(urls) }
            }
        }
    }

    private var hasCourse: Bool {
        creatingCourse ? !newCourseName.trimmingCharacters(in: .whitespaces).isEmpty : courseId != nil
    }

    private func run(_ picked: [URL]) {
        isImporting = true
        result = nil
        Task {
            defer { isImporting = false }
            do {
                let targetCourse = try resolveCourse()
                let copies = try copyIntoLibrary(picked, courseId: targetCourse)
                let summary = await store.importFiles(copies, intoCourse: targetCourse)
                result = describe(summary)
            } catch {
                result = "Couldn't import: \(error.localizedDescription)"
            }
        }
    }

    private func resolveCourse() throws -> String {
        if !creatingCourse, let courseId { return courseId }
        let name = newCourseName.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.addManualCourse(name: name, code: nil)
        guard let created = store.coursesBySemester.values.joined().first(where: { $0.name == name }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        courseId = created.id
        creatingCourse = false
        return created.id
    }

    /// Copies each picked file or folder into `Documents/Imported/<course>/`.
    private func copyIntoLibrary(_ urls: [URL], courseId: String) throws -> [URL] {
        let fm = FileManager.default
        let folder = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(courseId, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var copies: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: url, to: destination)
            copies.append(destination)
        }
        return copies
    }

    private func describe(_ summary: ImportSummary) -> String {
        var parts = ["Read \(summary.filesScanned) file\(summary.filesScanned == 1 ? "" : "s")."]
        parts.append(summary.cardsCreated == 0 ? "No new cards." : "Made \(summary.cardsCreated) draft card\(summary.cardsCreated == 1 ? "" : "s").")
        if summary.duplicatesSkipped > 0 { parts.append("Skipped \(summary.duplicatesSkipped) duplicates.") }
        if let error = summary.errors.first { parts.append(error) }
        return parts.joined(separator: " ")
    }
}
