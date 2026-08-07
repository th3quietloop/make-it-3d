import SwiftUI
import AppKit

/// The queue. Selection is encoded by a 2pt leading accent bar plus a 12%
/// accent fill, so it reads as state rather than decoration.
struct QueueSidebarView: View {
    @Bindable var model: AppModel
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Queue")
                Spacer()
                Text("\(model.conversions.count)")
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
            .padding(.horizontal, Tokens.Space.m)
            .frame(height: Tokens.Layout.paneHeaderHeight)

            Hairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.conversions) { conversion in
                        QueueRow(
                            conversion: conversion,
                            isSelected: conversion.id == model.selectionID
                        )
                        .onTapGesture { model.select(conversion) }
                        .contextMenu { rowMenu(conversion) }
                    }
                }

                // The empty stretch below the rows accepts drops too, so it
                // says so rather than reading as dead space.
                Text("Drop more movies here")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Space.l)
            }
            // Rows pass under the header rather than stopping at a rule.
            .scrollEdgeFade(top: true, bottom: false)

            Spacer(minLength: 0)
        }
        .frame(minWidth: Tokens.Layout.sidebarMinWidth)
        .surfaceMaterial(.sidebar)
        .overlay(
            // Drag over wake, in the populated layout as well as the empty one.
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .strokeBorder(
                    isTargeted ? Tokens.Palette.accent : .clear,
                    lineWidth: Tokens.Layout.focusRingWidth
                )
                .padding(Tokens.Space.xxs)
        )
        .animation(Tokens.Motion.previewCrossfadeAnimation, value: isTargeted)
    }

    @ViewBuilder
    private func rowMenu(_ conversion: Conversion) -> some View {
        if case .done(let url) = conversion.status {
            Button("Send to Vision Pro") { model.share(url) }
            Button("Show in Finder") { model.reveal(url) }
            Button("Convert Again") { model.reconvert(conversion) }
                .disabled(model.isConverting)
            Divider()
        }
        Button("Remove from Queue") { model.remove(conversion) }
            .disabled(conversion.status.isConverting)
    }
}

struct QueueRow: View {
    let conversion: Conversion
    let isSelected: Bool

    @State private var isHovering = false
    /// Drives the stereo fuse when a conversion lands.
    @State private var fuseAmount: CGFloat = 0

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            // The 2pt leading bar encodes selection.
            Rectangle()
                .fill(isSelected ? Tokens.Palette.accent : .clear)
                .frame(width: Tokens.Layout.selectionBarWidth)

            thumbnail

            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                title
                subtitle
            }

            Spacer(minLength: 0)
        }
        .padding(.trailing, Tokens.Space.s)
        .padding(.vertical, Tokens.Space.xs)
        .frame(minHeight: Tokens.Layout.queueRowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: conversion.status) { _, new in
            if case .done = new { runStereoFuse() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Title, with the signature moment

    @ViewBuilder
    private var title: some View {
        ZStack(alignment: .leading) {
            // The stereo fuse: on completion the title splits into a vermilion
            // and a cyan copy offset 2px, then fuses back to white. The
            // anaglyph identity, spent once, at the only moment that earns it.
            if fuseAmount > 0 {
                Text(conversion.displayName)
                    .foregroundStyle(Tokens.Palette.stereoL)
                    .offset(x: -Tokens.Motion.fuseOffset * fuseAmount)
                Text(conversion.displayName)
                    .foregroundStyle(Tokens.Palette.accent)
                    .offset(x: Tokens.Motion.fuseOffset * fuseAmount)
            }
            Text(conversion.displayName)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .opacity(1 - fuseAmount)
        }
        .font(Tokens.Font.rowTitle)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func runStereoFuse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        fuseAmount = 1
        withAnimation(Tokens.Motion.fuseSpring) {
            fuseAmount = 0
        }
    }

    // MARK: Row furniture

    @ViewBuilder
    private var subtitle: some View {
        switch conversion.status {
        case .probing:
            // A skeleton, not the word "Reading". Text that says it is loading
            // is a spinner in prose.
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .fill(Tokens.Palette.panelRaised)
                .frame(width: Tokens.Layout.durationColumn, height: Tokens.TypeScale.caption)
                .accessibilityLabel("Reading file")

        case .ready:
            HStack(spacing: Tokens.Space.xs) {
                Text(conversion.probe?.displayDuration ?? "")
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                if conversion.settingsChangedSinceExport {
                    Chip(text: "Settings changed")
                }
            }

        case .converting(let fraction, _):
            HStack(spacing: Tokens.Space.xs) {
                Text("\(Int(fraction * 100))%")
                    .font(Tokens.Font.monoCaption)
                    .foregroundStyle(Tokens.Palette.accent)
                if let remaining = conversion.estimatedSecondsRemaining {
                    Text("\(AppModel.humanDuration(remaining)) left")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }

        case .done:
            HStack(spacing: Tokens.Space.xs) {
                Chip(text: "Done", tone: .accent)
                if conversion.settingsChangedSinceExport {
                    Chip(text: "Settings changed")
                }
            }

        case .failed(let message):
            // The reason lives on the row that failed. It used to live only in
            // the inspector of whichever row happened to be selected, so a
            // queue of failures was a queue of red chips with no explanation.
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Chip(text: "Couldn't convert", tone: .error)
                Text(message)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .fill(Tokens.Palette.panelRaised)

            if let image = conversion.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Aspect fill overflows its frame, so it has to be clipped
                    // to the thumbnail box before the corner radius is applied.
                    // Without this the image spills across the sidebar.
                    .frame(
                        width: Tokens.Layout.thumbnailSize,
                        height: Tokens.Layout.thumbnailSize
                    )
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous))
                    // The thumbnail dims while its row converts.
                    .opacity(conversion.status.isConverting ? Tokens.StateShift.dimmed : 1)
            }

            if case .converting(let fraction, _) = conversion.status {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Tokens.Palette.accent, lineWidth: Tokens.Layout.progressRingWidth)
                    .rotationEffect(.degrees(-90))
                    .frame(width: Tokens.Layout.progressRing, height: Tokens.Layout.progressRing)
            }
        }
        .frame(width: Tokens.Layout.thumbnailSize, height: Tokens.Layout.thumbnailSize)
    }

    private var background: some View {
        Group {
            if isSelected {
                Tokens.Palette.selectionFill
            } else if isHovering {
                Tokens.Palette.panelRaised
            } else {
                Color.clear
            }
        }
    }
}

#Preview {
    QueueSidebarView(model: AppModel(), isTargeted: false)
        .frame(width: Tokens.Layout.sidebarWidth, height: 500)
}
