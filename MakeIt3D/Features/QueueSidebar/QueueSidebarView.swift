import SwiftUI
import AppKit

/// The queue, in two parts: what is finished, and what is still to do.
///
/// They used to be one list. A converted file sat in a queue labelled "Queue"
/// wearing a Done chip, which says the work is still pending and finished at
/// the same time. Splitting them means the list you scan for "what do I send to
/// the headset" and the list you scan for "what is left" are different lists.
///
/// Finished sits on top on purpose. With the queue running unattended, the
/// state you come back to is a pile of results, and results are what you came
/// back for. The row being converted is pinned above both so a long run never
/// hides its own progress.
struct QueueSidebarView: View {
    @Bindable var model: AppModel
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            // No pane header. MOVIES and TO CONVERT sat two rows apart naming
            // the same one list, and only one of them said anything: TO CONVERT
            // is a state, MOVIES is a category. The selection count it used to
            // carry moved into the section header, which is where the rows it
            // counts actually live.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !model.finished.isEmpty {
                        Section {
                            ForEach(model.finished) { row($0) }
                        } header: {
                            QueueSectionHeader(
                                title: "Converted",
                                count: model.finished.count,
                                trailing: model.finished.isEmpty ? nil : "Clear"
                            ) {
                                model.clearFinished()
                            }
                        }
                    }

                    Section {
                        ForEach(model.upNext) { row($0) }
                        addMoreButton
                    } header: {
                        // Always shown, even when it is the only section.
                        //
                        // This was cut last round as redundant with MOVIES two
                        // rows above, which was optimising for repetition and
                        // deleting the only word in the sidebar that implied
                        // unfinished work. "To convert" is a state, "Videos" is
                        // a category, and the reported experience was not
                        // knowing that anything was still waiting. It also uses
                        // the same verb as the button, so the list and the
                        // button say the same word.
                        QueueSectionHeader(
                            title: "To convert",
                            count: model.upNext.count,
                            trailing: model.selectedIDs.count > 1
                                ? "\(model.selectedIDs.count) selected" : nil,
                            action: model.selectedIDs.count > 1 ? {} : nil
                        )
                    }
                }
                .padding(.top, Tokens.Space.xs)
                .padding(.bottom, Tokens.Space.m)
            }
            .scrollEdgeFade(top: true, bottom: false)

            Spacer(minLength: 0)
        }
        .frame(minWidth: Tokens.Layout.sidebarMinWidth)
        .surfaceMaterial(.sidebar)
        .overlay(dragWake)
        .animation(Tokens.Motion.previewCrossfadeAnimation, value: isTargeted)
        // Finder keys, because this looks like a Finder list and anything that
        // looks like one is expected to behave like one.
        .onDeleteCommand { model.removeSelected() }
        // Focusable so Delete reaches the list, but without the system ring:
        // a 2pt accent outline around the entire sidebar reads as the drag
        // target state, which is a different message entirely.
        .focusable()
        .focusEffectDisabled()
    }

    private var dragWake: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
            .strokeBorder(
                isTargeted ? Tokens.Palette.accent : .clear,
                lineWidth: Tokens.Layout.focusRingWidth
            )
            .padding(Tokens.Space.xxs)
    }

    // MARK: Rows

    private func row(_ conversion: Conversion) -> some View {
        QueueRow(
            conversion: conversion,
            isSelected: model.selectedIDs.contains(conversion.id),
            isFocused: conversion.id == model.selectionID,
            isMultiSelect: model.selectedIDs.count > 1
        )
        .onTapGesture { handleTap(conversion) }
        .contextMenu { rowMenu(conversion) }
    }

    /// Finder click semantics. Shift takes the run, command picks and chooses,
    /// a plain click starts over.
    private func handleTap(_ conversion: Conversion) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            model.extendSelection(to: conversion)
        } else if flags.contains(.command) {
            model.toggleSelection(conversion)
        } else {
            model.select(conversion)
        }
    }

    /// The way out of "what now". After a conversion lands, the next thing a
    /// person wants is another video, and the only way to say so used to be a
    /// plus in the toolbar at the opposite end of the window.
    private var addMoreButton: some View {
        Button {
            model.chooseFiles()
        } label: {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: "plus")
                    .font(Tokens.Font.caption)
                Text(model.conversions.isEmpty ? "Add videos" : "Add more videos")
                    .font(Tokens.Font.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.Palette.textSecondary)
            .padding(.horizontal, Tokens.Space.m)
            .frame(height: Tokens.Layout.queueRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
    }

    @ViewBuilder
    private func rowMenu(_ conversion: Conversion) -> some View {
        if case .done(let url) = conversion.status {
            Button("Send to Vision Pro") { model.share(url) }
            Button("Show in Finder") { model.reveal(url) }
            Button("Convert this again") { model.reconvert(conversion) }
                .disabled(model.isConverting)
            Divider()
        }
        if model.selectedIDs.count > 1, model.selectedIDs.contains(conversion.id) {
            Button("Remove \(model.selectedIDs.count) videos") { model.removeSelected() }
        } else {
            Button("Remove") { model.remove(conversion) }
                .disabled(conversion.status.isConverting)
        }
    }
}

/// A sticky section header, with an optional action on the right.
struct QueueSectionHeader: View {
    let title: String
    let count: Int
    var trailing: String?
    var action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            SectionLabel(text: title)
            Text("\(count)")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textTertiary)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .buttonStyle(.plain)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(isHovering ? Tokens.Palette.accent : Tokens.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Tokens.Space.m)
        .frame(height: Tokens.Layout.sectionHeaderHeight)
        // No material. This sat on an already translucent vibrant sidebar, so
        // two blurs stacked and it read as a grey bar hovering over the rows
        // rather than a label belonging to them. The headers are no longer
        // pinned either: two short sections do not need sticky behaviour, and
        // unpinning is what removes the need for a background at all.
        .onHover { isHovering = $0 }
    }
}

struct QueueRow: View {
    let conversion: Conversion
    let isSelected: Bool
    /// The one row driving the stage. Distinct from selection, because a
    /// thirteen row selection still shows exactly one picture.
    let isFocused: Bool
    /// True when the user has more than one row selected.
    let isMultiSelect: Bool

    @State private var isHovering = false
    /// Drives the stereo fuse when a conversion lands.
    @State private var fuseAmount: CGFloat = 0

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            thumbnail

            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                title
                subtitle
            }

            Spacer(minLength: 0)

            // The finished row's whole point is getting the file to the
            // headset, so the action lives on the row rather than three clicks
            // away in a context menu.
            if case .done(let url) = conversion.status, isHovering {
                SendGlyph(url: url)
            }
        }
        // Space.xs, not Space.s. The selection fill is inset by Space.xs, so
        // Space.s here put the thumbnail at 20pt while every label in the pane
        // sat at 16pt. Three different left edges in a 264pt column: 8 for the
        // fill, 20 for the row, 16 for the labels. Nothing lined up with
        // anything, which is a thing you feel before you can name it.
        .padding(.horizontal, Tokens.Space.xs)
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
                    .contentTransition(.numericText())
                if let remaining = conversion.estimatedSecondsRemaining {
                    Text("\(AppModel.humanDuration(remaining)) left")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }

        case .done:
            HStack(spacing: Tokens.Space.xs) {
                Text("Ready to send")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
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

    /// Selection, the way macOS draws it.
    ///
    /// There used to be a 2pt accent bar down the leading edge. That is the
    /// Bootstrap list-group pattern, and no Apple list has ever used it: Finder,
    /// Mail, Music and the Xcode navigator all encode selection as a filled
    /// rounded rectangle inset from the edges. The bar is gone.
    private var background: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
            .fill(fill)
            .overlay {
                // Fill says selected. The outline says which selected row is
                // the one on the stage, and that is only a question worth
                // answering when more than one is selected. On a single
                // selection it was a second signal for a state the fill had
                // already carried.
                if isFocused && isSelected && isMultiSelect {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Tokens.Palette.accent.opacity(0.55), lineWidth: Tokens.Layout.hairlineWidth)
                }
            }
            .padding(.horizontal, Tokens.Space.xs)
            .padding(.vertical, Tokens.Space.xxs)
    }

    private var fill: Color {
        if isSelected { return Tokens.Palette.selectionFill }
        if isHovering { return Tokens.Palette.panelRaised }
        return .clear
    }
}

/// A small share glyph that appears on a finished row when you point at it.
private struct SendGlyph: View {
    let url: URL

    @State private var anchor: NSView?

    var body: some View {
        Button {
            guard let anchor else { return }
            NSSharingServicePicker(items: [url])
                .show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .frame(width: Tokens.Layout.iconButton, height: Tokens.Layout.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RowShareAnchor(view: $anchor))
        .help("Send to Vision Pro")
        .accessibilityLabel("Send to Vision Pro")
    }
}

private struct RowShareAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        DispatchQueue.main.async { view = anchor }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    QueueSidebarView(model: AppModel(), isTargeted: false)
        .frame(width: Tokens.Layout.sidebarWidth, height: 500)
        .environment(AppearanceSettings())
}
