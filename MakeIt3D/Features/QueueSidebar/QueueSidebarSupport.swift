import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// The four useful ways to cut a large queue. This stays view state: filtering
/// changes what is visible, never what the runner will convert.
enum QueueFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case waiting
    case failed
    case converted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .converted: "Converted"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "line.3.horizontal.decrease"
        case .waiting: "clock"
        case .failed: "exclamationmark.triangle"
        case .converted: "checkmark.circle"
        }
    }

    @MainActor
    func includes(_ conversion: Conversion) -> Bool {
        // A finished export whose settings changed is runnable work again. It
        // belongs with Waiting even though its underlying status is still done.
        if conversion.settingsChangedSinceExport {
            return self == .all || self == .waiting
        }

        return switch (self, conversion.status) {
        case (.all, _): true
        case (.waiting, .probing), (.waiting, .ready), (.waiting, .converting): true
        case (.failed, .failed): true
        case (.converted, .done): true
        default: false
        }
    }

    @MainActor
    func includes(_ conversion: Conversion, searchText: String) -> Bool {
        guard includes(conversion) else { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return conversion.displayName.localizedCaseInsensitiveContains(query)
            || conversion.sourceURL.path.localizedCaseInsensitiveContains(query)
    }
}

/// A dense status rail for a queue that may run unattended for hours. The
/// estimate stays visible while the controls change between Pause and Resume.
struct QueueRunSummary: View {
    let summaryText: String
    let outputEstimateText: String?
    let phase: QueuePhase
    let onPauseAfterCurrent: () -> Void
    let onStopAfterCurrent: () -> Void
    let onResume: () -> Void
    let onStopNow: () -> Void

    private var isRunning: Bool { phase != .idle }

    private var statusText: String? {
        switch phase {
        case .idle, .running: nil
        case .pauseAfterCurrent: "Pausing after current video"
        case .stopAfterCurrent: "Stopping after current video"
        case .paused: "Queue paused"
        case .stopping: "Stopping now"
        }
    }

    private var primaryTitle: String {
        switch phase {
        case .running: "Pause after current video"
        case .pauseAfterCurrent, .stopAfterCurrent, .paused: "Resume queue"
        case .stopping: "Stopping queue"
        case .idle: "Queue controls"
        }
    }

    private var primaryImage: String {
        switch phase {
        case .running: "pause.fill"
        case .pauseAfterCurrent, .stopAfterCurrent, .paused: "play.fill"
        case .stopping: "hourglass"
        case .idle: "ellipsis"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.xs) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(summaryText)
                    .font(Tokens.Font.bodyMedium)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let outputEstimateText {
                    Text(outputEstimateText)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }

                if let statusText {
                    Text(statusText)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.accent)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isRunning {
                Button(action: primaryAction) {
                    Image(systemName: primaryImage)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                        .frame(
                            width: Tokens.Layout.minTarget,
                            height: Tokens.Layout.minTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(phase == .stopping)
                .help(primaryTitle)
                .accessibilityLabel(primaryTitle)

                Menu {
                    if phase == .running || phase == .pauseAfterCurrent {
                        Button("Stop After Current Video", action: onStopAfterCurrent)
                    }
                    Button("Stop Now", role: .destructive, action: onStopNow)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(Tokens.Font.body)
                        .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
                        .frame(
                            width: Tokens.Layout.minTarget,
                            height: Tokens.Layout.minTarget
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(phase == .stopping)
                .help("More queue controls")
                .accessibilityLabel("More queue controls")
            }
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.xs)
    }

    private func primaryAction() {
        switch phase {
        case .running: onPauseAfterCurrent()
        case .pauseAfterCurrent, .stopAfterCurrent, .paused: onResume()
        case .idle, .stopping: break
        }
    }
}

/// Search and filtering share one compact rail. At 264pt, four segmented
/// buttons would truncate; a native menu preserves clear labels and keyboard
/// accessibility without taking a second row.
struct QueueSidebarControls: View {
    @Binding var searchText: String
    @Binding var filter: QueueFilter

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            HStack(spacing: Tokens.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .accessibilityHidden(true)

                TextField("Search videos", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Tokens.Font.body)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Tokens.Font.caption)
                            .foregroundStyle(Tokens.Palette.textTertiary)
                            .frame(
                                width: Tokens.Layout.minTarget,
                                height: Tokens.Layout.minTarget
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, Tokens.Space.xs)
            .frame(height: Tokens.Layout.minTarget)
            .background(
                Tokens.Palette.controlFillQuiet,
                in: RoundedRectangle(
                    cornerRadius: Tokens.Radius.control,
                    style: .continuous
                )
            )

            Menu {
                ForEach(QueueFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        Label(option.label, systemImage: option == filter ? "checkmark" : option.systemImage)
                    }
                }
            } label: {
                Image(systemName: filter == .all
                      ? "line.3.horizontal.decrease"
                      : "line.3.horizontal.decrease.circle.fill")
                    .font(Tokens.Font.body)
                    .foregroundStyle(filter == .all
                                     ? Tokens.Palette.textSecondary
                                     : Tokens.Palette.accent)
                    .frame(
                        width: Tokens.Layout.minTarget,
                        height: Tokens.Layout.minTarget
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Filter: \(filter.label)")
            .accessibilityLabel("Filter queue")
            .accessibilityValue(filter.label)
        }
        .padding(.horizontal, Tokens.Space.xs)
        .padding(.vertical, Tokens.Space.xs)
    }
}

/// Position within the runnable work, separate from selection and visual row
/// index. Failed and converted rows never receive a position.
enum QueuePosition: Equatable, Sendable {
    case next
    case numbered(Int)
}

struct QueuePositionBadge: View {
    let position: QueuePosition

    var body: some View {
        switch position {
        case .next:
            Chip(text: "Next", tone: .accent)
                .accessibilityLabel("Next to convert")
        case .numbered(let number):
            Text("#\(number)")
                .font(Tokens.Font.monoCaption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .accessibilityLabel("Queue position \(number)")
        }
    }
}

/// Copy for the same priority action changes with queue state and selection
/// size. The idle action is an ordering action; the running action is a promise
/// about what converts after the active file.
enum QueuePriorityCopy {
    static func actionTitle(count: Int, queueRunning: Bool) -> String {
        guard count > 1 else {
            return queueRunning ? "Convert Next" : "Move to Top of Queue"
        }
        return queueRunning
            ? "Convert \(count) Videos Next"
            : "Move \(count) Videos to Top"
    }

    static func confirmation(
        names: [String],
        queueRunning: Bool
    ) -> QueuePriorityNoticeContent {
        let count = names.count
        if count == 1, let name = names.first {
            return QueuePriorityNoticeContent(
                title: queueRunning ? "\(name) is next" : "\(name) moved to the top",
                detail: queueRunning ? "It will start after the current conversion." : nil
            )
        }
        return QueuePriorityNoticeContent(
            title: queueRunning
                ? "\(count) videos are next"
                : "\(count) videos moved to the top",
            detail: queueRunning ? "They will keep their current order." : nil
        )
    }
}

struct QueuePriorityNoticeContent: Equatable, Sendable {
    let title: String
    let detail: String?
}

/// Unlike a toast, this stays in the sidebar until dismissed or until the
/// prioritised work starts. Priority is queue state, not a four-second event.
struct QueuePriorityNotice: View {
    let content: QueuePriorityNoticeContent
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.xs) {
            Image(systemName: "arrow.up.to.line")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.accent)
                .frame(
                    width: Tokens.Layout.minTarget,
                    height: Tokens.Layout.minTarget
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(content.title)
                    .font(Tokens.Font.bodyMedium)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = content.detail {
                    Text(detail)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .frame(
                        width: Tokens.Layout.minTarget,
                        height: Tokens.Layout.minTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss priority confirmation")
        }
        .padding(.horizontal, Tokens.Space.xs)
        .padding(.vertical, Tokens.Space.xs)
        .background(Tokens.Palette.selectionFill)
        .accessibilityElement(children: .contain)
    }
}

/// Lives outside the ScrollView so adding another video never requires a trip
/// to the bottom of a 40-item queue.
struct QueueStickyAddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: "plus")
                    .font(Tokens.Font.caption)
                Text("Add videos")
                    .font(Tokens.Font.bodyMedium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.Palette.textSecondaryVibrant)
            .padding(.horizontal, Tokens.Space.m)
            .frame(height: Tokens.Layout.leanBackTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .accessibilityHint("Opens a file picker and adds videos to the queue")
    }
}

/// A local-only transfer type. Source file URLs continue through RootView's URL
/// drop destination, while queue rows use this separate type and cannot be
/// mistaken for imports.
extension UTType {
    static let makeIt3DQueueItems = UTType(
        exportedAs: "com.russellwhite.makeit3d.queue-items"
    )
}

struct QueueDragPayload: Codable, Transferable, Sendable {
    /// Ordered as they currently appear, so a multi-row move preserves the
    /// group rather than replaying Set iteration order.
    let ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .makeIt3DQueueItems)
    }
}

enum QueueDropTarget: Equatable, Sendable {
    case before(UUID)
    case end

    var destinationID: UUID? {
        switch self {
        case .before(let id): id
        case .end: nil
        }
    }
}

/// Sits between rows while a local queue payload targets that insertion point.
struct QueueDropIndicator: View {
    let isVisible: Bool

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(isVisible ? Tokens.Palette.accent : .clear)
                .frame(height: Tokens.Layout.focusRingWidth)
                .padding(.horizontal, Tokens.Space.xs)
        }
        .frame(height: Tokens.Space.xxs)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

struct QueueEmptyResults: View {
    let hasSearch: Bool
    let filter: QueueFilter
    let hasPinnedWork: Bool

    var body: some View {
        Text(message)
            .font(Tokens.Font.body)
            .foregroundStyle(Tokens.Palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.l)
    }

    private var message: String {
        let prefix = hasPinnedWork ? "No other" : "No"
        return hasSearch
            ? "\(prefix) matching videos"
            : "\(prefix) \(filter.label.lowercased()) videos"
    }
}

#Preview("Queue controls") {
    @Previewable @State var searchText = ""
    @Previewable @State var filter = QueueFilter.all

    VStack(spacing: 0) {
        QueueSidebarControls(searchText: $searchText, filter: $filter)
        QueuePriorityNotice(
            content: QueuePriorityNoticeContent(
                title: "Beach clip is next",
                detail: "It will start after the current conversion."
            ),
            onDismiss: {}
        )
        HStack {
            QueuePositionBadge(position: .next)
            QueuePositionBadge(position: .numbered(3))
        }
        .padding(Tokens.Space.m)
        Hairline()
        QueueStickyAddButton(action: {})
    }
    .frame(width: Tokens.Layout.sidebarWidth)
    .surfaceMaterial(.sidebar)
    .environment(AppearanceSettings())
}
