import SwiftUI
import UniformTypeIdentifiers
import GRASPCore
#if os(iOS)
import PhotosUI
#endif

/// A picture from picture data, on either platform.
struct DataImage: View {
    let data: Data
    var contentMode: ContentMode = .fit

    var body: some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
        } else { Color.clear }
        #else
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        } else { Color.clear }
        #endif
    }
}

private struct SourceLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, _ symbol: String) { self.title = title; self.symbol = symbol }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.graspUI(size: 12))
            Text(title).font(.graspUI(size: 13, weight: .semibold))
        }
        .foregroundStyle(GRASPColor.textPrimary)
        .padding(.horizontal, 12).frame(height: 32)
        .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong))
        .contentShape(Capsule())
    }
}

/// "From a photo": choose pictures of an exam, a worksheet or a page of
/// questions. They are read on this device; what they hold lands as drafts on
/// the Questions tab, beside the picture they came from.
struct PhotoImportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let decks: [Deck]
    let defaultDeckId: String?
    let courseId: String?

    private struct Picked: Identifiable {
        let id = UUID()
        let data: Data
    }

    @State private var picked: [Picked] = []
    @State private var deckId: String?
    @State private var choosingFiles = false
    @State private var problem: String?
    #if os(iOS)
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showingCamera = false
    #endif

    private var running: Bool { store.aiJob(store.photoImportJobKey(courseId: courseId)) != nil }
    private var canStart: Bool { !picked.isEmpty && deckId != nil && !running }
    private static let maxPhotos = 10

    var body: some View {
        GRASPSheet(
            eyebrow: "Questions", title: "Questions from a Photo",
            message: "Photos are read on this device. The questions they hold wait under To review, next to their photo, until you approve them.",
            icon: "camera", width: 480
        ) {
            VStack(alignment: .leading, spacing: 14) {
                notices
                if decks.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel("Add to deck")
                        GRASPPicker(selection: $deckId, options: decks.map { ($0.id as String?, $0.name) })
                    }
                    .popupGroup()
                }
                photosGroup
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .graspType(.meta).foregroundStyle(GRASPColor.rejected)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button {
                start()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AIGlyph.symbol).font(.graspUI(size: 11, weight: .semibold))
                    Text("Read questions")
                }
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
        .task {
            if deckId == nil { deckId = defaultDeckId ?? decks.first?.id }
            #if DEBUG
            await debugAutoImport()
            #endif
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { add(data) }
            }
        }
        #if os(iOS)
        .onChange(of: libraryItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { add(data) }
                }
                libraryItems = []
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { data in
                showingCamera = false
                if let data { add(data) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    // MARK: Pieces

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.isGeneratorAvailable {
                Label("No AI model is set up. Only questions whose answers are printed on the photo can be kept. Settings has the setup.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(GRASPColor.rejected)
            } else {
                Text("Answers the page prints are kept as printed. For the rest, \(store.generatorStatus) writes the answer and marks it Check the answer.")
                if store.aiMode.usesCloud, store.hasCloudKey {
                    Label("The text read from your photos is sent to Google Gemini. The photos themselves stay on this device. "
                          + "Its free tier may use what you send to improve Google's products.", systemImage: "cloud")
                }
            }
        }
        .graspType(.meta)
        .foregroundStyle(GRASPColor.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var photosGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FieldLabel("Photos")
                Spacer()
                if !picked.isEmpty {
                    Text("\(picked.count)").graspType(.meta).foregroundStyle(GRASPColor.textTertiary).monospacedDigit()
                }
            }
            if !picked.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(picked) { item in
                            DataImage(data: item.data, contentMode: .fill)
                                .frame(width: 84, height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { picked.removeAll { $0.id == item.id } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.graspUI(size: 16))
                                            .foregroundStyle(GRASPColor.textPrimary, GRASPColor.surface)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(4)
                                    .accessibilityLabel("Remove photo")
                                }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                #if os(iOS)
                PhotosPicker(selection: $libraryItems, maxSelectionCount: Self.maxPhotos, matching: .images) {
                    SourceLabel("Choose from Library", "photo.on.rectangle")
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showingCamera = true } label: { SourceLabel("Take Photo", "camera") }.buttonStyle(.plain)
                }
                #else
                Button { choosingFiles = true } label: { SourceLabel("Choose Images…", "photo.on.rectangle") }.buttonStyle(.plain)
                Button { pasteImage() } label: { SourceLabel("Paste", "doc.on.clipboard") }
                    .buttonStyle(.plain)
                    .help("Paste an image you copied, such as a screenshot")
                #endif
            }
            if picked.isEmpty {
                Text("Pictures of a page of numbered questions read best: sharp, flat and well lit.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .popupGroup()
    }

    // MARK: Actions

    private func add(_ data: Data) {
        guard picked.count < Self.maxPhotos else { problem = "Up to \(Self.maxPhotos) photos at a time."; return }
        guard PhotoSupport.prepare(data) != nil else { problem = "That file is not a picture GRASP can read."; return }
        problem = nil
        picked.append(Picked(data: data))
    }

    #if os(macOS)
    private func pasteImage() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { add(data) } else {
            problem = "There is no image on the clipboard."
        }
    }
    #endif

    private func start() {
        guard let deckId else { return }
        store.importPhotoQuestions(picked.map(\.data), deckId: deckId, courseId: courseId)
        dismiss()
    }

    #if DEBUG
    /// Screenshots only, with the canned writer on: `GRASP_PHOTO_FILE` is a picture to
    /// import, and `GRASP_AUTO_IMPORT=1` starts the import without a click.
    private func debugAutoImport() async {
        let environment = ProcessInfo.processInfo.environment
        guard StubHooks.enabled("GRASP_STUB_QUESTIONS"), let path = environment["GRASP_PHOTO_FILE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        add(data)
        if environment["GRASP_AUTO_IMPORT"] == "1" {
            try? await Task.sleep(for: .milliseconds(900))
            start()
        }
    }
    #endif
}

#if os(iOS)
/// The camera, for a photo taken now.
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
#endif
