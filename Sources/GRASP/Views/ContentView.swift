import SwiftUI
import GRASPCore

/// Root layout: sidebar (Home + semesters/courses) and a single wide
/// detail pane. Home gets the pane's full width, matching a dashboard's
/// proportions -- when a course is selected instead, that same pane
/// splits itself into a deck list and deck detail side by side, rather
/// than reserving a third `NavigationSplitView` column (and that column's
/// width) for every screen even when Home has no use for it.
struct ContentView: View {
    /// Sentinel selection value for "Home", sharing `selectedCourseId`'s
    /// single-selection binding with real course ids instead of a second
    /// piece of state that could disagree with it.
    static let homeRoute = "home"

    @Environment(AppStore.self) private var store
    @State private var selectedCourseId: String? = ContentView.homeRoute
    @State private var selectedDeckId: String?
    @State private var showingAddCourse = false
    @State private var showingSearch = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedCourseId: $selectedCourseId)
                .navigationSplitViewColumnWidth(min: 200, ideal: 255)
        } detail: {
            Group {
                if selectedCourseId == Self.homeRoute || selectedCourseId == nil {
                    HomeView(selectedCourseId: $selectedCourseId, selectedDeckId: $selectedDeckId)
                } else {
                    // Three tiers of ground, narrowest to widest: the
                    // vibrant sidebar, then the deck list on a lifted
                    // surface, then the card canvas on the app's darkest
                    // ground. Depth increases as the panes get wider, so
                    // the eye lands on the content pane rather than
                    // treating all three as equal columns.
                    HStack(spacing: 0) {
                        DeckListView(courseId: selectedCourseId!, selectedDeckId: $selectedDeckId)
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                            .background(GRASPColor.surface)
                        Rectangle()
                            .fill(GRASPColor.hairlineStrong)
                            .frame(width: 1)
                        if let deckId = selectedDeckId {
                            DeckDetailView(deckId: deckId)
                        } else {
                            ContentUnavailableView("Select a deck", systemImage: "rectangle.stack")
                        }
                    }
                }
            }
            .background(GRASPColor.canvas)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddCourse = true
                } label: {
                    Label("Add Course", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ImportButton()
            }
            ToolbarItem(placement: .primaryAction) {
                ProfileMenuButton()
            }
        }
        // Set at the window root rather than per-view: sidebar selection,
        // segmented controls, focus rings and every system control in the
        // window all draw from the tint, so one declaration here is what
        // keeps them from reverting to the OS accent (which is usually
        // blue, and reads as a stock app).
        .tint(GRASPColor.accent)
        .sheet(isPresented: $showingAddCourse) {
            AddCourseSheet()
        }
        .sheet(isPresented: $showingSearch) {
            SearchView()
        }
    }
}

private struct ImportButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            Task { await store.runImport() }
        } label: {
            if store.isImporting {
                ProgressView().controlSize(.small)
            } else {
                Label("Import Vault", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(store.isImporting)
        .help(importHelp)
    }

    private var importHelp: String {
        guard let summary = store.lastImportSummary else { return "Scan the vault for new or changed notes" }
        return "Last import: \(summary.filesImportedOrUpdated) updated, \(summary.cardsCreated) cards created"
    }
}

private struct AddCourseSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Course")
                .font(.headline)
            Text("For a current-semester class with no vault folder yet -- import its notes later once you write them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Course name (e.g. Intro to Software Design)", text: $name)
            TextField("Course code (optional, e.g. COP 3014)", text: $code)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    try? store.addManualCourse(name: name, code: code.isEmpty ? nil : code)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

#Preview {
    ContentView()
        .environment(AppStore(profile: .preview))
}
