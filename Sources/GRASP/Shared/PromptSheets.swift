import SwiftUI

/// GRASP's own replacement for a system `.alert`/`.confirmationDialog`,
/// used everywhere a prompt needs more than one line to explain itself --
/// an icon, a real title, and body copy set in the app's own type and
/// color tokens instead of the generic system bubble. Two shapes cover
/// every prompt in the app: `ConfirmationSheet` (are you sure?) and
/// `ResultSheet` (here's what happened).
struct ConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let icon: String
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive: Bool = true
    var cancelTitle: String = "Cancel"
    /// On iPhone, a short sheet sized to its content rather than the medium
    /// detent.
    var isCompact: Bool = false
    let onConfirm: () -> Void

    var body: some View {
        GRASPSheet(
            title: title, message: message, icon: icon,
            tone: isDestructive ? .destructive : .accent, width: 420
        ) {
            EmptyView()
        } footer: {
            Button(cancelTitle) { dismiss() }
            Button(confirmTitle) {
                onConfirm()
                dismiss()
            }
            .buttonStyle(GRASPProminentButton(tint: isDestructive ? GRASPColor.rejected : GRASPColor.brand))
            .keyboardShortcut(.defaultAction)
        }
        #if os(iOS)
        .presentationDetents(isCompact ? [.height(280)] : [.medium])
        #endif
    }
}

/// A report shown after an action completes -- an import, a bulk AI pass,
/// anything with a real result worth more than "Done". `sections` renders
/// each as an icon-labeled group of line items inside a raised card
/// (scrollable past a modest height, for a vault-wide sweep's longer
/// lists); omit them entirely for a plain one-line result.
struct ResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let icon: String
    let title: String
    var leadText: String?
    var sections: [Section] = []
    var doneTitle: String = "OK"

    struct Section: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let items: [String]
    }

    var body: some View {
        GRASPSheet(title: title, message: leadText, icon: icon, width: 460) {
            if !sections.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: section.icon)
                                        .font(.graspUI(size: 11, weight: .semibold))
                                        .foregroundStyle(section.tint)
                                    Text("\(section.title) (\(section.items.count))")
                                        .graspType(.meta)
                                        .foregroundStyle(GRASPColor.textPrimary)
                                }
                                ForEach(section.items, id: \.self) { item in
                                    Text("•  \(item)")
                                        .graspType(.body)
                                        .foregroundStyle(GRASPColor.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .popupGroup(padding: 14)
            }
        } footer: {
            Button(doneTitle) { dismiss() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
        }
        #if os(iOS)
        .presentationDetents(sections.isEmpty ? [.medium] : [.medium, .large])
        #endif
    }
}
