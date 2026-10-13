import SwiftUI

/// The frame every GRASP popup sits in: a yellow-dot eyebrow, the title in
/// the display face, an optional icon tile and one line of explanation,
/// then the content on the canvas, then a footer bar one surface step up
/// with the buttons right-aligned. Sheets, confirmations and results all
/// use it, so a popup reads as part of the app rather than a system box.
struct GRASPSheet<Content: View, Footer: View>: View {
    @Environment(\.dismiss) private var dismiss
    var eyebrow: String? = nil
    let title: String
    var message: String? = nil
    var icon: String? = nil
    var tone: Tone = .accent
    /// Nil lets the content decide (a sheet that sizes itself).
    var width: CGFloat? = 420
    /// Set for a sheet with a fixed height; the content then fills it.
    var height: CGFloat? = nil
    var showsClose = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    typealias Tone = PopupTone

    #if os(iOS)
    /// What a phone sheet needs to show all of itself, so its presenter can
    /// fit the detent to it (`SheetFitHeightKey`).
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            header
            contentArea(content)
            #else
            // A phone sheet scrolls; the footer stays put under it.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    contentArea(content)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            #endif
            if Footer.self != EmptyView.self {
                HStack(spacing: GRASPSpace.s) { footer() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, GRASPSpace.xl)
                    .padding(.vertical, 14)
                    .background(GRASPColor.surface)
                    .overlay(alignment: .top) { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                    #if os(iOS)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                    #endif
            }
        }
        #if os(macOS)
        .frame(width: width, height: height)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preference(key: SheetFitHeightKey.self, value: contentHeight + footerHeight)
        #endif
        .graspPopup()
    }

    @ViewBuilder
    private func contentArea(_ content: () -> Content) -> some View {
        if Content.self != EmptyView.self {
            content()
                .frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity, alignment: .topLeading)
                .padding(.horizontal, GRASPSpace.xl)
                .padding(.bottom, GRASPSpace.xl)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: GRASPSpace.m) {
            if let icon {
                PopupIconTile(systemImage: icon, tone: tone)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow { SectionLabel(eyebrow) }
                Text(title)
                    .font(.graspDisplay(22))
                    .tracking(-0.4)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if showsClose {
                PopupCloseButton { dismiss() }
            }
        }
        .padding(.horizontal, GRASPSpace.xl)
        .padding(.top, 22)
        .padding(.bottom, GRASPSpace.l)
    }
}

extension GRASPSheet where Footer == EmptyView {
    init(eyebrow: String? = nil, title: String, message: String? = nil, icon: String? = nil,
         tone: Tone = .accent, width: CGFloat? = 420, height: CGFloat? = nil, showsClose: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(eyebrow: eyebrow, title: title, message: message, icon: icon, tone: tone,
                  width: width, height: height, showsClose: showsClose, content: content, footer: { EmptyView() })
    }
}

/// The height a `GRASPSheet` needs on iPhone: its content plus its footer.
struct SheetFitHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The color of a popup's icon tile and its confirming button.
enum PopupTone { case accent, destructive, success }

/// The icon at the head of a popup: a rounded tile in the tone's soft fill.
struct PopupIconTile: View {
    let systemImage: String
    var tone: PopupTone = .accent

    private var tint: Color {
        switch tone {
        case .accent: GRASPColor.accent
        case .destructive: GRASPColor.rejected
        case .success: GRASPColor.success
        }
    }

    private var soft: Color {
        switch tone {
        case .accent: GRASPColor.accentSoft
        case .destructive: GRASPColor.rejectedSoft
        case .success: GRASPColor.successSoft
        }
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.graspUI(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(soft, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The round × in a popup's corner. Escape does the same.
struct PopupCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.graspUI(size: 10, weight: .bold))
                .foregroundStyle(hovering ? GRASPColor.textPrimary : GRASPColor.textTertiary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? GRASPColor.surfaceRaised : GRASPColor.surface))
                .overlay(Circle().strokeBorder(GRASPColor.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .help("Close")
        .accessibilityLabel("Close")
    }
}

extension View {
    /// The look every popup's content gets: the canvas behind it, GRASP's
    /// fields, checkboxes and pill buttons as the defaults inside it, and
    /// no system list or form backgrounds. Controls that set their own
    /// style keep it.
    func graspPopup() -> some View {
        self
            .graspPopupBackground()
            .font(.graspBody)
            .textFieldStyle(GRASPFieldStyle())
            .toggleStyle(GRASPCheckboxStyle())
            .buttonStyle(GRASPQuietButton())
            .scrollContentBackground(.hidden)
    }

    /// Only the canvas and tint, for full-screen popups (study, tests,
    /// note viewer) whose own buttons are drawn by hand.
    func graspPopupBackground() -> some View {
        self
            .tint(GRASPColor.accent)
            .background(GRASPColor.canvas)
            .presentationBackground(GRASPColor.canvas)
    }

    /// A popup's grouped box: the surface fill with a hairline, for a block
    /// of settings or a list inside a sheet.
    func popupGroup(padding: CGFloat = GRASPSpace.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous)
                    .strokeBorder(GRASPColor.hairline, lineWidth: 1)
            )
    }
}

/// A small caption over a field in a popup.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.graspUI(size: 12, weight: .semibold))
            .foregroundStyle(GRASPColor.textSecondary)
    }
}

/// A text field on the raised surface with a hairline that turns yellow
/// while you type in it.
struct GRASPFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        FieldChrome { configuration }
    }
}

/// The field look, for `TextField`, `SecureField` and `TextEditor` alike.
struct FieldChrome<Field: View>: View {
    @ViewBuilder let field: () -> Field
    @FocusState private var focused: Bool

    var body: some View {
        field()
            .focused($focused)
            .graspFieldChrome(focused: focused)
    }
}

extension View {
    /// The field look around a control that tracks its own focus.
    func graspFieldChrome(focused: Bool) -> some View {
        self
            .textFieldStyle(.plain)
            .font(.graspBody)
            .foregroundStyle(GRASPColor.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(GRASPColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? GRASPColor.accent : GRASPColor.hairlineStrong,
                                  lineWidth: focused ? 1.5 : 1)
            )
            .animation(Motion.fade, value: focused)
    }
}

extension View {
    /// `FieldChrome` for a `TextEditor` (which has no field style).
    func graspEditorChrome(minHeight: CGFloat = 80) -> some View {
        FieldChrome {
            self
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
        }
    }
}

/// A checkbox drawn in GRASP's colors: a rounded square that fills yellow
/// with an ink check when on.
struct GRASPCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(configuration.isOn ? GRASPColor.brand : GRASPColor.surfaceRaised)
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(configuration.isOn ? .clear : GRASPColor.hairlineStrong, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(GRASPColor.ink)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                configuration.label
                    .foregroundStyle(GRASPColor.textPrimary)
            }
            .contentShape(Rectangle())
            .animation(Motion.snappy, value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

/// A switch in GRASP's colors, for settings that turn a behavior on.
struct GRASPSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label.foregroundStyle(GRASPColor.textPrimary)
            Spacer(minLength: GRASPSpace.m)
            Capsule()
                .fill(configuration.isOn ? GRASPColor.brand : GRASPColor.hairlineStrong)
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? GRASPColor.ink : GRASPColor.textPrimary)
                        .frame(width: 14, height: 14)
                        .padding(3)
                }
                .animation(Motion.choose(Motion.snappy, reduceMotion: reduceMotion), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
        }
    }
}

/// Pick one of a few: a pill track with a yellow pill that slides to the
/// chosen option. Replaces the system segmented control and the radio
/// groups in popups.
struct GRASPSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var fillsWidth = false
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.value == selection
                Button {
                    withAnimation(Motion.choose(Motion.snappy, reduceMotion: reduceMotion)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.graspUI(size: 12.5, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 26)
                        .background {
                            // Cream, like the Cards / Overview switch: yellow
                            // is for Study and the sparkle.
                            if isOn {
                                Capsule().fill(GRASPColor.surfaceRaised)
                                    .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong))
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(GRASPColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(GRASPColor.hairline, lineWidth: 1))
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }
}

/// One choice of several, as a row with a round marker -- for choices
/// that need a sentence each, where a segmented pill would be too tight.
struct GRASPRadioRow<Label: View>: View {
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                ZStack {
                    Circle().strokeBorder(isOn ? GRASPColor.brand : GRASPColor.hairlineStrong, lineWidth: isOn ? 5 : 1)
                        .background(Circle().fill(isOn ? GRASPColor.ink : GRASPColor.surfaceRaised))
                }
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                label().foregroundStyle(GRASPColor.textPrimary)
            }
            .contentShape(Rectangle())
            .animation(Motion.snappy, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Pick one of a list in a popup: GRASP's own dropdown on the Mac, the
/// system menu picker (tinted) on iPhone, where a touch menu is expected.
struct GRASPPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        #if os(macOS)
        GRASPDropdown(selection: $selection, options: options)
        #else
        Picker("", selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(GRASPColor.accent)
        #endif
    }
}
