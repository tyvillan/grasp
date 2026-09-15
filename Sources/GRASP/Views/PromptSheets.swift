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
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(isDestructive ? GRASPColor.rejected : GRASPColor.accent)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
            }
            Text(message)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(confirmTitle) {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(GRASPProminentButton(tint: isDestructive ? GRASPColor.rejected : GRASPColor.accent))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(GRASPColor.canvas)
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(GRASPColor.accent)
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
                if let leadText {
                    Text(leadText)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !sections.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: section.icon)
                                        .font(.system(size: 11, weight: .semibold))
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
                .padding(14)
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                Spacer()
                Button(doneTitle) { dismiss() }
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(GRASPColor.canvas)
    }
}
