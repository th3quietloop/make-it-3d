import SwiftUI

/// 11pt, all caps, +0.4 tracking, 62% text. The only way a section label is
/// drawn anywhere in Relief.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Tokens.Font.sectionLabel)
            .tracking(Tokens.Tracking.sectionLabel)
            .textCase(.uppercase)
            .foregroundStyle(Tokens.Palette.textSecondary)
            .lineSpacing(Tokens.LineSpacing.labels(Tokens.TypeScale.caption))
    }
}

/// A 1pt hairline. Panels separate by tone and hairline, never by shadow.
struct Hairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Tokens.Palette.hairline)
            .frame(
                width: axis == .vertical ? Tokens.Layout.hairlineWidth : nil,
                height: axis == .horizontal ? Tokens.Layout.hairlineWidth : nil
            )
    }
}

/// The one filled accent control in the app. All eight states live here.
struct ConvertButton: View {
    enum State: Equatable {
        case normal
        case disabled
        case loading(fraction: Double)
        case success
        case error(String)
    }

    let title: String
    let state: State
    let action: () -> Void

    @SwiftUI.State private var isHovering = false
    @SwiftUI.State private var isPressed = false
    @SwiftUI.State private var shakeOffset: CGFloat = 0
    @FocusState private var isFocused: Bool

    private var isDisabled: Bool {
        if case .disabled = state { return true }
        return false
    }

    private var fill: Color {
        switch state {
        case .disabled:
            return Tokens.Palette.panelRaised
        case .loading, .normal, .success, .error:
            if isPressed { return Tokens.Palette.accent.shiftedLightness(by: Tokens.StateShift.active) }
            if isHovering { return Tokens.Palette.accent.shiftedLightness(by: Tokens.StateShift.hover) }
            return Tokens.Palette.accent
        }
    }

    private var label: String {
        switch state {
        case .loading(let fraction): return "\(Int(fraction * 100))%"
        default: return title
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Button(action: action) {
                ZStack {
                    // Determinate sweep: the fill itself reports progress, so
                    // there is never an indeterminate spinner once a conversion
                    // has started.
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Tokens.Palette.panelRaised)
                            Rectangle()
                                .fill(fill)
                                .frame(width: geometry.size.width * sweepFraction)
                        }
                    }
                    Text(label)
                        .font(state.isLoading ? Tokens.Font.mono : Tokens.Font.bodyMedium)
                        .foregroundStyle(labelColor)
                }
                .frame(height: Tokens.Layout.minTarget)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .focused($isFocused)
            .offset(x: shakeOffset)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .strokeBorder(
                        isFocused ? Tokens.Palette.focusRing : .clear,
                        lineWidth: Tokens.Layout.focusRingWidth
                    )
            )
            .onHover { isHovering = $0 }
            .onLongPressGesture(minimumDuration: 0, pressing: { isPressed = $0 }, perform: {})
            .onChange(of: state) { _, new in
                if case .error = new { shake() }
            }

            if case .error(let message) = state {
                Text(message)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sweepFraction: Double {
        switch state {
        case .loading(let fraction): return max(0, min(fraction, 1))
        case .disabled: return 0
        default: return 1
        }
    }

    private var labelColor: Color {
        switch state {
        case .disabled: return Tokens.Palette.textTertiary
        // The label sits on the accent fill, so it takes the stage colour.
        default: return Tokens.Palette.stage
        }
    }

    /// Shakes 2px twice, then the message appears below.
    private func shake() {
        let offsets: [CGFloat] = [
            Tokens.Motion.shakeOffset, -Tokens.Motion.shakeOffset,
            Tokens.Motion.shakeOffset, -Tokens.Motion.shakeOffset, 0
        ]
        for (index, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(index) * Tokens.Motion.shakeStep
            ) {
                withAnimation(.easeOut(duration: Tokens.Motion.shakeStep)) { shakeOffset = offset }
            }
        }
    }
}

private extension ConvertButton.State {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// A small chip, used for Done, Failed, and Settings changed.
struct Chip: View {
    enum Tone { case accent, error, quiet }

    let text: String
    var tone: Tone = .quiet

    private var foreground: Color {
        switch tone {
        case .accent: return Tokens.Palette.accent
        case .error: return Tokens.Palette.error
        case .quiet: return Tokens.Palette.textSecondary
        }
    }

    private var background: Color {
        switch tone {
        case .accent: return Tokens.Palette.chipFillAccent
        case .error: return Tokens.Palette.chipFillError
        case .quiet: return Tokens.Palette.panelRaised
        }
    }

    var body: some View {
        Text(text)
            .font(Tokens.Font.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, Tokens.Space.xs)
            .padding(.vertical, Tokens.Space.xxs)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
    }
}

/// A numeric readout. SF Mono with tabular figures, always.
struct Readout: View {
    let value: String
    var size: CGFloat = Tokens.TypeScale.body

    var body: some View {
        Text(value)
            .font(Tokens.Font.mono(size: size))
            .foregroundStyle(Tokens.Palette.textPrimary)
    }
}

#Preview("Convert button states") {
    VStack(alignment: .leading, spacing: Tokens.Space.m) {
        ConvertButton(title: "Convert", state: .normal) {}
        ConvertButton(title: "Convert", state: .disabled) {}
        ConvertButton(title: "Convert", state: .loading(fraction: 0.42)) {}
        ConvertButton(title: "Convert", state: .error("Couldn't read this file.")) {}
        HStack(spacing: Tokens.Space.xs) {
            Chip(text: "Done", tone: .accent)
            Chip(text: "Failed", tone: .error)
            Chip(text: "Settings changed", tone: .quiet)
        }
        SectionLabel(text: "Strength")
        Readout(value: "16.4 px", size: Tokens.TypeScale.readout)
    }
    .padding(Tokens.Space.l)
    .frame(width: 296)
    .background(Tokens.Palette.panel)
}
