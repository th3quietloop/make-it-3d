import SwiftUI

/// The queue. Rows are 56pt with a 40pt thumbnail, a title, and a duration in
/// mono. Selection is encoded by a 2pt leading accent bar plus a 12% accent
/// fill, so it reads as state rather than decoration.
struct QueueSidebarView: View {
    @Bindable var model: AppModel

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
            .padding(.vertical, Tokens.Space.s)

            Hairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.conversions) { conversion in
                        QueueRow(
                            conversion: conversion,
                            isSelected: conversion.id == model.selectionID
                        )
                        .onTapGesture { model.select(conversion) }
                        .contextMenu {
                            Button("Remove from Queue") { model.remove(conversion) }
                                .disabled(conversion.status.isConverting)
                            if case .done(let url) = conversion.status {
                                Button("Reveal in Finder") { model.reveal(url) }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: Tokens.Layout.sidebarMinWidth)
        .background(Tokens.Palette.panel)
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

            VStack(alignment: .leading, spacing: 2) {
                title
                subtitle
            }

            Spacer(minLength: 0)
        }
        .padding(.trailing, Tokens.Space.s)
        .frame(height: Tokens.Layout.queueRowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: conversion.status) { _, new in
            if case .done = new { runStereoFuse() }
        }
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
        fuseAmount = 1
        withAnimation(.easeOut(duration: Tokens.Motion.stereoFuse)) {
            fuseAmount = 0
        }
    }

    // MARK: Row furniture

    @ViewBuilder
    private var subtitle: some View {
        switch conversion.status {
        case .probing:
            Text("Reading")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textTertiary)
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
            Text("\(Int(fraction * 100))%")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.accent)
        case .done:
            HStack(spacing: Tokens.Space.xs) {
                Chip(text: "Done", tone: .accent)
                if conversion.settingsChangedSinceExport {
                    Chip(text: "Settings changed")
                }
            }
        case .failed:
            Chip(text: "Failed", tone: .error)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel)
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
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.panel))
                    // The thumbnail dims while its row converts.
                    .opacity(conversion.status.isConverting ? 0.4 : 1)
            }

            if case .converting(let fraction, _) = conversion.status {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Tokens.Palette.accent, lineWidth: 2)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: 22)
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
    let model = AppModel()
    return QueueSidebarView(model: model)
        .frame(width: Tokens.Layout.sidebarWidth, height: 500)
}
