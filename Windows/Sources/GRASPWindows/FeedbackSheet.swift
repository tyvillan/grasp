import Foundation
import SwiftCrossUI

/// Send feedback, after the Mac's `SendFeedbackSheet`: a kind, an optional
/// rating, a message, whether to give a name, an optional picture, and a
/// plain list of what is attached.
struct SendFeedbackSheet: View {
    let close: () -> Void
    @Environment(\.chooseFile) var chooseFile

    private let service = FeedbackService.shared

    @State var draft = FeedbackDraft()
    /// Taken when the sheet opens, so it names the screen the person came from.
    @State var context = FeedbackFacts.context()
    @State var showsDetails = false
    @State var phase: Phase = .form
    @State var error: String?
    /// The attached picture, as a JPEG file for the preview.
    @State var preview: URL?
    @State var preparing = false

    enum Phase: Equatable { case form, sending, done(String) }

    private var count: Int { draft.message.count }

    var body: some View {
        GRASPSheet(eyebrow: "Feedback", title: "Send feedback",
                   message: phase.isDone ? nil : "What's working, what's confusing, what you wish it did.",
                   width: 560) {
            if case .done(let text) = phase {
                HStack(spacing: 10) {
                    Text("\u{2713}").font(GRASPFont.rowTitle.weight(.bold)).foregroundColor(GRASPColor.success)
                    Text(text).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                }
            } else {
                ScrollView {
                    form
                        .frame(width: 490.0, alignment: .leading)
                        .padding(.trailing, 14)
                }
                .frame(height: 420.0)
            }
        } footer: {
            footer
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("What kind of feedback is it?")
                SegmentedChoice(options: FeedbackType.allCases.map { Optional($0) }, selection: draft.type,
                                label: { $0?.title ?? "" }) { choice in
                    if draft.type != choice { draft.type = choice }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Rating (optional)")
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { value in
                        let on = draft.rating == value
                        Text("\(value)")
                            .font(Font.system(size: 13, weight: on ? .semibold : .medium))
                            .foregroundColor(on ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                            .frame(width: 40.0, height: 30.0)
                            .edged(fill: on ? GRASPColor.surfaceRaised : GRASPColor.surface,
                                   edge: on ? GRASPColor.hairlineStrong : GRASPColor.hairline, radius: 15)
                            .onTapGesture { draft.rating = on ? nil : value }
                    }
                    Spacer()
                    Text("1 is poor, 5 is great").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Message")
                // WinUI draws the editor's edge only while it has focus; the
                // Mac's field sits on a hairline edge all the time.
                TextEditor(text: Binding(get: { draft.message }, set: { draft.message = $0 }).changesOnly())
                    .frame(height: 96.0)
                    .padding(1)
                    .edged(fill: GRASPColor.inset, edge: GRASPColor.hairlineStrong, radius: 6)
                if count >= FeedbackLimits.counterStart {
                    Text("\(count) of \(FeedbackLimits.messageMax)")
                        .font(GRASPFont.meta)
                        .foregroundColor(count > FeedbackLimits.messageMax ? GRASPColor.rejected : GRASPColor.textTertiary)
                }
            }
            anonymousSection
            screenshotSection
            detailsSection
            if let error {
                Text(error).font(GRASPFont.meta).foregroundColor(GRASPColor.rejected)
            }
        }
    }

    private var anonymousSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A pill, not WinUI's toggle, which draws in Windows' accent colour.
            Pill(title: "Send anonymously", isOn: draft.anonymous) { draft.anonymous.toggle() }
            if draft.anonymous {
                Text("No name or email is sent.").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Name (optional)")
                    TextField("Your name", text: Binding(get: { draft.name }, set: { draft.name = $0 }).changesOnly())
                    FieldLabel("Email (optional)").padding(.top, 4)
                    TextField("you@example.com", text: Binding(get: { draft.email }, set: { draft.email = $0 }).changesOnly())
                    Text("So Tyler can ask you a follow-up.").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                }
            }
        }
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Screenshot (optional)")
            if let data = draft.screenshot, let preview {
                Image(preview)
                    .resizable()
                    .frame(width: 266.0, height: 150.0)
                    .cornerRadius(GRASPRadius.inner)
                HStack(spacing: 8) {
                    Text("\(data.count / 1000) KB").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    Spacer()
                    GRASPButton("Remove") {
                        draft.screenshot = nil
                        self.preview = nil
                    }
                }
                Text("A screenshot can show your notes and cards. Look it over before you send.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
            } else if preparing {
                Text("Preparing the picture\u{2026}").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            } else {
                HStack(spacing: 8) {
                    GRASPButton("Choose image\u{2026}") { chooseImage() }
                    if let snapshot = service.windowSnapshot {
                        GRASPButton("Attach this window") { attach(snapshot) }
                    }
                }
                Text("Nothing is attached unless you add it.").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((showsDetails ? "\u{2304}  " : "\u{203A}  ") + "What gets sent")
                .font(Font.system(size: 13, weight: .semibold))
                .foregroundColor(GRASPColor.textSecondary)
                .onTapGesture { showsDetails.toggle() }
            if showsDetails {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(context.disclosure.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.label).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                                .frame(width: 130.0, alignment: .leading)
                            Text(row.value).font(GRASPFont.meta).foregroundColor(GRASPColor.textPrimary)
                                .lineLimit(2)
                            Spacer()
                        }
                    }
                    Text("Plus what you wrote above. Never your notes, cards, questions, answers or course names.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                        .padding(.top, 4)
                }
                .padding(12)
                .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if phase.isDone {
            Spacer()
            GRASPButton("Done", kind: .primary) { close() }
        } else {
            if service.rateLimitReached {
                footerNote(FeedbackService.rateLimitMessage)
            } else if let problem = draft.problem, !draft.message.isEmpty || draft.type != nil {
                footerNote(problem)
            }
            Spacer()
            GRASPButton("Cancel") { close() }
            GRASPButton(phase == .sending ? "Sending" : "Send", kind: .primary) { Task { await send() } }
                .disabled(draft.problem != nil || phase == .sending || preparing || service.rateLimitReached)
        }
    }

    /// Up to two lines beside the buttons, as on the Mac, never cut to "...".
    private func footerNote(_ text: String) -> some View {
        Text(text)
            .font(GRASPFont.meta)
            .foregroundColor(GRASPColor.textTertiary)
            .frame(width: 300.0, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func send() async {
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
        }
    }

    private func chooseImage() {
        Task {
            guard let url = await chooseFile(title: "Choose an image", defaultButtonLabel: "Attach",
                                             allowSelectingFiles: true, allowSelectingDirectories: false) else { return }
            attach(url)
        }
    }

    /// Scales and squeezes the picture to a JPEG under 500 KB, then shows it.
    private func attach(_ url: URL) {
        preparing = true
        error = nil
        Task {
            let data = await FeedbackImage.prepare(url)
            preparing = false
            guard let data else {
                error = "Couldn't read that image. Try a different one."
                return
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-feedback-preview-\(UUID().uuidString.prefix(8)).jpg")
            try? data.write(to: file)
            preview = file
            draft.screenshot = data
        }
    }
}

private extension SendFeedbackSheet.Phase {
    var isDone: Bool { if case .done = self { return true } else { return false } }
}

/// The small card for a soft ask: one line and three ways out, at the bottom
/// right of the window. All three are outlined: the screen's one yellow
/// button stays where it was.
struct FeedbackAskCard: View {
    let ask: FeedbackAsk
    private let service = FeedbackService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ask.message).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
            HStack(spacing: 8) {
                GRASPButton("Send feedback") { service.open() }
                GRASPButton("Not now") { service.dismissAsk() }
                GRASPButton("Don't ask again") { service.neverAskAgain() }
            }
        }
        .padding(16)
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairlineStrong, radius: GRASPRadius.card)
        .fixedSize()
        .padding(16)
    }
}
