import SwiftUI
import WidgetKit

/// The deck to study next -- tapping it opens that deck.
struct JumpBackInWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GRASPJumpBackIn", provider: SnapshotProvider()) { entry in
            JumpBackInView(entry: entry)
                .graspWidgetBackground()
        }
        .configurationDisplayName("Jump Back In")
        .description("The deck to study next. Tap to open it.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct JumpBackInView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state {
            if let next = state.jumpBackIn {
                switch family {
                case .systemMedium:
                    HStack(alignment: .top, spacing: 16) {
                        featured(next.deck, due: next.dueCount)
                        let others = state.dueDecks.filter { $0.deck.id != next.deck.id }.prefix(3)
                        if !others.isEmpty {
                            Rectangle().fill(GRASPColor.hairline).frame(width: 1)
                            alsoDue(Array(others))
                        }
                    }
                    // The whole widget opens the featured deck; each row in
                    // the list is its own link.
                    .widgetURL(WidgetLink.deck(next.deck.id).url)
                default:
                    featured(next.deck, due: next.dueCount)
                        .widgetURL(WidgetLink.deck(next.deck.id).url)
                }
            } else {
                caughtUp
                    .widgetURL(WidgetLink.today.url)
            }
        } else {
            OpenAppPrompt(icon: "play.circle.fill")
                .widgetURL(WidgetLink.today.url)
        }
    }

    private func featured(_ deck: WidgetSnapshot.Deck, due: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(GRASPColor.dynamic(light: 0xFFFFFF, dark: 0x16130C))
                    .frame(width: 30, height: 30)
                    .background(GRASPColor.accent, in: Circle())
                    .widgetAccentable()
                Spacer(minLength: 4)
                Text("\(due) due")
                    .font(.graspNumber(12))
                    .foregroundStyle(GRASPColor.accent)
            }
            Spacer(minLength: 6)
            WidgetEyebrow(text: "Jump back in")
                .padding(.bottom, 3)
            Text(deck.name)
                .graspType(.title)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(deck.courseName)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func alsoDue(_ decks: [(deck: WidgetSnapshot.Deck, dueCount: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetEyebrow(text: "Also due")
            ForEach(decks, id: \.deck.id) { entry in
                Link(destination: WidgetLink.deck(entry.deck.id).url) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.deck.name)
                                .graspType(.rowTitle)
                                .foregroundStyle(GRASPColor.textPrimary)
                                .lineLimit(1)
                            Text(entry.deck.courseName)
                                .graspType(.meta)
                                .foregroundStyle(GRASPColor.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text("\(entry.dueCount)")
                            .font(.graspNumber(12))
                            .foregroundStyle(GRASPColor.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var caughtUp: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(GRASPColor.success)
                .widgetAccentable()
            Spacer(minLength: 6)
            WidgetEyebrow(text: "Jump back in")
                .padding(.bottom, 3)
            Text("All caught up")
                .graspType(.title)
                .foregroundStyle(GRASPColor.textPrimary)
            Text("Nothing due right now.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
