import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Send feedback to the maintainer: a kind, an optional rating, a message,
/// whether to give a name, an optional screenshot, and a plain list of what
/// is attached. Used on the Mac and the iPhone.
struct SendFeedbackSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let service = FeedbackService.shared

    @State private var draft = FeedbackDraft()
    /// Read when the sheet opens, so it names the screen the person came from.
    @State private var context: FeedbackContext?
    @State private var showsDetails = false
    @State private var phase: Phase = .form
    @State private var error: String?
    @State private var importing = false
    #if os(iOS)
    @State private var pickedPhoto: PhotosPickerItem?
    #endif

    private enum Phase: Equatable { case form, sending, done(String) }

    private var isDone: Bool { if case .done = phase { return true } else { return false } }
    private var count: Int { draft.message.count }

    var body: some View {
        GRASPSheet(eyebrow: "Feedback", title: "Send feedback",
                   message: isDone ? nil : "What's working, what's confusing, what you wish it did.",
                   icon: "bubble.left.and.text.bubble.right", width: 520) {
            if case .done(let text) = phase {
                doneView(text)
            } else {
                formArea
            }
        } footer: {
            footer
        }
        .task { prepare() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { attach(contentsOf: url) }
        }
        #if os(iOS)
        .onChange(of: pickedPhoto) { _, item in loadPhoto(item) }
        #endif
    }

    // MARK: Form

    /// The form, scrolling to a part when it opens: "What gets sent", a
    /// picture, or the name and email fields.
    private var formArea: some View {
        ScrollViewReader { proxy in
            #if os(macOS)
            // A Mac sheet does not scroll by itself, and this one is taller
            // than a short window.
            ScrollView { form.padding(.vertical, 2) }
                .frame(maxHeight: 350)
                .modifier(RevealOnChange(showsDetails: showsDetails, hasShot: draft.screenshot != nil,
                                         anonymous: draft.anonymous, proxy: proxy))
            #else
            // A phone sheet already scrolls.
            form
                .modifier(RevealOnChange(showsDetails: showsDetails, hasShot: draft.screenshot != nil,
                                         anonymous: draft.anonymous, proxy: proxy))
            #endif
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("What kind of feedback is it?")
                GRASPSegmented(
                    selection: $draft.type,
                    options: FeedbackType.allCases.map { (Optional($0), $0.title) },
                    fillsWidth: true
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Rating (optional)")
                ratingRow
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Message")
                TextEditor(text: $draft.message)
                    .graspEditorChrome(minHeight: 72)
                    .accessibilityLabel("Message")
                if count >= FeedbackLimits.counterStart {
                    Text("\(count) of \(FeedbackLimits.messageMax)")
                        .graspType(.meta).monospacedDigit()
                        .foregroundStyle(count > FeedbackLimits.messageMax ? GRASPColor.rejected : GRASPColor.textTertiary)
                }
            }

            anonymousSection
            screenshotSection.id("shot")
            detailsSection.id("details")

            if let error {
                Text(error).graspType(.meta).foregroundStyle(GRASPColor.rejected)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.snappy, value: draft.anonymous)
        .animation(Motion.snappy, value: showsDetails)
        .animation(Motion.fade, value: draft.screenshot == nil)
    }

    private var ratingRow: some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { value in
                let on = draft.rating == value
                Button {
                    draft.rating = on ? nil : value
                } label: {
                    Text("\(value)")
                        .font(.graspUI(size: 13, weight: on ? .semibold : .medium)).monospacedDigit()
                        .foregroundStyle(on ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                        .frame(width: 40, height: 32)
                        .background(on ? GRASPColor.surfaceRaised : GRASPColor.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? GRASPColor.hairlineStrong : GRASPColor.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rating \(value) of 5")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Text("1 is poor, 5 is great").graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
        }
    }

    private var anonymousSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Send anonymously", isOn: $draft.anonymous)
                .toggleStyle(GRASPSwitchStyle())
            if draft.anonymous {
                Text("No name or email is sent.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Name (optional)")
                    TextField("Your name", text: $draft.name)
                    FieldLabel("Email (optional)").padding(.top, 4)
                    TextField("you@example.com", text: $draft.email)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Text("So Tyler can ask you a follow-up.")
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                }
                .id("contact")
                .transition(.opacity)
            }
        }
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Screenshot (optional)")
            if let data = draft.screenshot, let image = Self.image(from: data) {
                image
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 150)
                    .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                    .accessibilityLabel("Screenshot preview")
                HStack(spacing: 8) {
                    Text("\(data.count / 1000) KB").graspType(.meta).monospacedDigit()
                        .foregroundStyle(GRASPColor.textTertiary)
                    Spacer()
                    Button("Remove") { draft.screenshot = nil }
                }
                Text("A screenshot can show your notes and cards. Look it over before you send.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    #if os(iOS)
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo")
                    }
                    .buttonStyle(GRASPQuietButton())
                    #else
                    Button { importing = true } label: { Label("Choose image", systemImage: "photo") }
                    Button { captureWindow() } label: { Label("Capture this window", systemImage: "macwindow") }
                    #endif
                }
                Text("Nothing is attached unless you add it.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showsDetails.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.graspUI(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text("What gets sent").font(.graspUI(size: 13, weight: .semibold))
                }
                .foregroundStyle(GRASPColor.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsDetails ? "Hide what gets sent" : "Show what gets sent")

            if showsDetails, let context {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(context.disclosure.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                                .frame(width: 130, alignment: .leading)
                            Text(row.value).graspType(.meta).foregroundStyle(GRASPColor.textPrimary)
                                .lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    Text("Plus what you wrote above. Never your notes, cards, questions, answers or course names.")
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .popupGroup(padding: 12)
                .transition(.opacity)
            }
        }
    }

    // MARK: Done and footer

    private func doneView(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(GRASPColor.success)
            Text(text).graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var footer: some View {
        if isDone {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
        } else {
            if service.rateLimitReached {
                Text(FeedbackService.rateLimitMessage).graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary).lineLimit(2)
            } else if let problem = draft.problem, !draft.message.isEmpty || draft.type != nil {
                Text(problem).graspType(.meta).foregroundStyle(GRASPColor.textTertiary).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(phase == .sending ? "Sending" : "Send") { Task { await send() } }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil || phase == .sending || service.rateLimitReached)
        }
    }

    // MARK: Actions


    private func prepare() {
        if context == nil { context = store.feedbackContext() }
        #if DEBUG
        FeedbackDebug.apply(to: &draft, showsDetails: &showsDetails)
        #if os(macOS)
        if StubHooks.enabled("GRASP_FEEDBACK_CAPTURE") { captureWindow() }
        #endif
        if FeedbackDebug.autoSend { Task { await send() } }
        #endif
    }

    private func send() async {
        guard let context = context ?? Optional(store.feedbackContext()) else { return }
        error = nil
        phase = .sending
        switch await service.send(draft: draft, context: context) {
        case .sent:
            draft = FeedbackDraft()
            phase = .done("Thanks. Your feedback was sent.")
        case .queued(let offline, let message):
            draft = FeedbackDraft()
            phase = .done(offline ? "Saved. It will send when you're online." : "\(message) It's saved and will try again.")
        case .rateLimited:
            phase = .form
            error = FeedbackService.rateLimitMessage
        case .invalid(let text):
            phase = .form
            error = text
        case .notConfigured:
            phase = .form
            error = "Feedback isn't set up in this copy of GRASP yet."
        }
    }

    private func attach(contentsOf url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let prepared = FeedbackImage.prepare(data) else {
            error = "Couldn't read that image. Try a different one."
            return
        }
        error = nil
        draft.screenshot = prepared
    }

    #if os(iOS)
    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let prepared = FeedbackImage.prepare(data) {
                error = nil
                draft.screenshot = prepared
            } else {
                error = "Couldn't read that photo. Try a different one."
            }
            pickedPhoto = nil
        }
    }
    #endif

    #if os(macOS)
    private func captureWindow() {
        if let data = FeedbackLauncher.captureMainWindow() {
            error = nil
            draft.screenshot = data
        } else {
            error = "Couldn't capture the window. Choose an image instead."
        }
    }
    #endif

    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

#if DEBUG
/// Debug launch flags (debug builds with `-GRASPAllowStubs 1`): sample
/// content so the sheet can be photographed without typing.
///   GRASP_FEEDBACK=1            open the sheet at launch
///   GRASP_FEEDBACK_FILL=1       a sample type, rating and message
///   GRASP_FEEDBACK_ANON=0       turn anonymous off, with a sample name and email
///   GRASP_FEEDBACK_SHOT_FILE=p  attach this image
///   GRASP_FEEDBACK_DETAILS=1    open "What gets sent"
///   GRASP_FEEDBACK_CAPTURE=1    (Mac) press "Capture this window"
///   GRASP_FEEDBACK_SEND=1       press Send once the sheet is up
///   GRASP_FEEDBACK_ASK=test|week  show a soft ask
///   GRASP_FEEDBACK_STATE=fresh|ratelimit  start clean, or with today's limit reached
///   GRASP_STUB_FEEDBACK=ok|offline|reject  answer instead of the server
enum FeedbackDebug {
    static var opensSheet: Bool { StubHooks.enabled("GRASP_FEEDBACK") }
    static var autoSend: Bool { StubHooks.enabled("GRASP_FEEDBACK_SEND") }
    static var ask: FeedbackAsk? {
        switch StubHooks.value("GRASP_FEEDBACK_ASK") {
        case "test": return .firstTest
        case "week": return .week
        default: return nil
        }
    }

    static func apply(to draft: inout FeedbackDraft, showsDetails: inout Bool) {
        if StubHooks.enabled("GRASP_FEEDBACK_FILL") {
            draft.type = .confusing
            draft.rating = 4
            draft.message = "I wasn't sure where to add my notes the first time. The tour helped, but I looked for an Import button on the course page."
        }
        if StubHooks.value("GRASP_FEEDBACK_ANON") == "0" {
            draft.anonymous = false
            draft.name = "Sam"
            draft.email = "sam@example.com"
        }
        if let path = StubHooks.value("GRASP_FEEDBACK_SHOT_FILE"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let prepared = FeedbackImage.prepare(data) {
            draft.screenshot = prepared
        }
        if StubHooks.enabled("GRASP_FEEDBACK_DETAILS") { showsDetails = true }
    }
}
#endif

/// Brings a part of the form into view when it appears: "What gets sent"
/// opening, a screenshot being added, or anonymous turning off.
private struct RevealOnChange: ViewModifier {
    let showsDetails: Bool
    let hasShot: Bool
    let anonymous: Bool
    let proxy: ScrollViewProxy

    private func reveal(_ id: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(Motion.snappy) { proxy.scrollTo(id, anchor: .bottom) }
        }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: showsDetails) { _, open in if open { reveal("details") } }
            .onChange(of: hasShot) { _, has in if has { reveal("shot") } }
            .onChange(of: anonymous) { _, on in if !on { reveal("contact") } }
    }
}
