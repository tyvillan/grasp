import Foundation
import GRASPCore
import SwiftCrossUI

/// The dashboard, after the Mac's `HomeView`: the wordmark, a greeting,
/// a strip of figures, and a shelf of course tiles. The Mac's upcoming
/// exams, "pick up where you left off" card, recent decks and streak come
/// later.
struct HomeView: View {
    let library: Library
    @Binding var route: Route

    private static let horizontalPadding = 32.0

    var body: some View {
        // Outside the ScrollView, where the width is known, as on the Mac.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    statStrip.padding(.top, 26)
                    coursesShelf(width: proxy.size.width - 2 * Self.horizontalPadding)
                        .padding(.top, 34)
                }
                .padding(.horizontal, Int(Self.horizontalPadding))
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("G.R.A.S.P")
                    .font(Font.system(size: 11, weight: .bold))
                    .foregroundColor(GRASPColor.accent)
                Rectangle().fill(GRASPColor.hairlineStrong).frame(width: 14.0, height: 1.0)
                Text("Gather Resources, Apply, Study, Perform")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome back")
                    .font(GRASPFont.display)
                    .foregroundColor(GRASPColor.textPrimary)
                Text(Self.dateLine(Date()))
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
    }

    /// "Friday, September 25", as the Mac formats it.
    static func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter.string(from: date)
    }

    // MARK: - Figures

    private var statStrip: some View {
        let due = library.decks.reduce(0) { $0 + $1.due }
        let cards = library.decks.reduce(0) { $0 + $1.total }
        let courses = library.courseSections.reduce(0) { $0 + $1.courses.count }
        return HStack(spacing: 0) {
            StatFigure(value: due, label: "Due today", tint: due > 0 ? GRASPColor.accent : nil)
            statDivider
            StatFigure(value: cards, label: "Cards", tint: nil)
            statDivider
            StatFigure(value: courses, label: "Courses", tint: nil)
            Spacer()
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(GRASPColor.hairlineStrong)
            .frame(width: 1.0, height: 26.0)
            .padding(.horizontal, 22)
    }

    // MARK: - Courses

    private func coursesShelf(width: Double) -> some View {
        let tiles = courseTiles
        let layout = Self.gridLayout(width: width)
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Your courses")
            if tiles.isEmpty {
                Text("Import your notes folder, or sign in to sync, to see your courses here.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textTertiary)
            } else {
                // SwiftCrossUI has no grid, so rows of fixed-width tiles.
                VStack(alignment: .leading, spacing: Int(Self.tileSpacing)) {
                    ForEach(Self.rows(of: tiles, size: layout.columns), id: \.first!.id) { row in
                        HStack(spacing: Int(Self.tileSpacing)) {
                            ForEach(row, id: \.id) { tile in
                                CourseTile(tile: tile) { route = .course(tile.id) }
                                    .frame(width: layout.tileWidth)
                            }
                        }
                    }
                }
            }
        }
    }

    private static let tileSpacing = 10.0

    /// The Mac's `GridItem(.adaptive(minimum: 172, maximum: 230))`: as many
    /// columns as fit at 172 wide or more, each at most 230.
    static func gridLayout(width proposed: Double) -> (columns: Int, tileWidth: Double) {
        // GeometryReader can be offered an infinite (or unset) width while
        // SwiftCrossUI measures the page; converting that to Int crashes.
        let width = proposed.isFinite && proposed > 0 ? proposed : 3 * 230 + 2 * tileSpacing
        let columns = max(1, Int((width + tileSpacing) / (172 + tileSpacing)))
        let tileWidth = min(230, (width - Double(columns - 1) * tileSpacing) / Double(columns))
        return (columns, max(172, tileWidth.rounded(.down)))
    }

    /// Every course that has cards, in sidebar order, with its totals.
    private var courseTiles: [CourseTileData] {
        let semesterNames = Dictionary(uniqueKeysWithValues: library.semesters.map { ($0.id, $0.name) })
        return library.courseSections.flatMap(\.courses).compactMap { course in
            let decks = library.decks(inCourse: course.id)
            guard !decks.isEmpty else { return nil }
            return CourseTileData(
                id: course.id,
                name: course.name,
                eyebrow: course.code ?? course.semesterId.flatMap { semesterNames[$0] },
                colorHex: course.colorHex,
                cards: decks.reduce(0) { $0 + $1.total },
                due: decks.reduce(0) { $0 + $1.due }
            )
        }
    }

    static func rows<T>(of items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

struct CourseTileData: Identifiable {
    let id: String
    let name: String
    let eyebrow: String?
    let colorHex: String?
    let cards: Int
    let due: Int
}

private struct StatFigure: View {
    let value: Int
    let label: String
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(Font.system(size: 15, weight: .semibold))
                .foregroundColor(tint ?? GRASPColor.textPrimary)
            Text(label)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
        }
        .fixedSize()
    }
}

/// A course on the dashboard: dot and code, the name, then its card and
/// due counts. No border at rest; lighter on hover, as on the Mac.
private struct CourseTile: View {
    let tile: CourseTileData
    let open: () -> Void
    @State var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tile.colorHex.map { Color(hex: $0) } ?? GRASPColor.hairlineStrong)
                    .frame(width: 6.0, height: 6.0)
                if let eyebrow = tile.eyebrow {
                    Text(eyebrow.uppercased())
                        .font(GRASPFont.eyebrow)
                        .foregroundColor(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Text(tile.name)
                .font(GRASPFont.title)
                .foregroundColor(GRASPColor.textPrimary)
                .lineLimit(2)
                .padding(.top, 8)
            Spacer()
            HStack(spacing: 5) {
                Text("\(tile.cards) cards")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                if tile.due > 0 {
                    Text("·").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    Text("\(tile.due) due")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.accent)
                }
            }
        }
        .padding(13)
        .frame(height: 112.0)
        .background(isHovering ? GRASPColor.surfaceRaised : GRASPColor.surface)
        .cornerRadius(10)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
    }
}
