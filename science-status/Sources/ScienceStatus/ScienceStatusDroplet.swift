//
//  ScienceStatusDroplet.swift
//  ScienceStatus
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(ScienceStatusPrincipal)
public final class ScienceStatusPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { ScienceStatusDroplet() }
}

/// Claude Science sessions in the notch: a pill while something runs,
/// a shelf list of recent sessions, a card when one finishes or needs input.
///
/// Local and read-only like Droppy's own Agents droplet: the documented
/// `claude-science status` CLI for daemon health, plus a read-only pass over
/// the daemon's SQLite database for the sessions and their states. No auth,
/// no network, no guessing — an unreadable state shows as "can't read status".
@MainActor
public final class ScienceStatusDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "science-status"

    // MARK: - Settings (persisted in host.preferences)

    // Each setting saves only itself: saving all five from one didSet made
    // restoreSettings() overwrite the stored values it had not read yet.
    @Published var pollRunning: Double = 3 { didSet { save(pollRunning, forKey: "pollRunning"); reschedule() } }
    @Published var pollIdle: Double = 30 { didSet { save(pollIdle, forKey: "pollIdle"); reschedule() } }
    @Published var hudOnFinished = true { didSet { save(hudOnFinished, forKey: "hudOnFinished") } }
    @Published var hudOnNeedsInput = true { didSet { save(hudOnNeedsInput, forKey: "hudOnNeedsInput") } }
    @Published var minDuration: Double = 30 {
        didSet { save(minDuration, forKey: "minDuration"); engine.minDuration = minDuration }
    }

    // MARK: - Model

    @Published private(set) var snapshot = ScienceSnapshot(
        runningCount: nil, daemonVersion: nil, sessions: [])
    @Published private(set) var checking = true

    private var host: DropletHost?
    private var timer: Timer?
    private var engine = ScienceEngine()
    private var seat: DropletLiveActivitySeat = .none(.idle)
    private var fetching = false
    private var restoring = false
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    /// Where sessions come from. The harness swaps in a fixture before
    /// activation so its shots never show a real session.
    public var source: any ScienceSource = CombinedScienceSource()

    /// Sessions working or waiting on the user.
    var runningCount: Int { snapshot.runningCount ?? 0 }
    var waitingCount: Int { snapshot.sessions.filter { $0.state == .needsInput }.count }
    var isLive: Bool { runningCount > 0 }

    // MARK: - Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        restoreSettings()
        engine.minDuration = minDuration
        host.log.info("Science Status activated")
        fetch()
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        timer?.invalidate()
        timer = nil
        host?.liveActivity.yield(reason: .idle)
        activitySubject.send(nil)
        host = nil
    }

    // MARK: - Polling

    func refresh() {
        fetch()
    }

    private func fetch() {
        guard !fetching, host != nil else { return }
        fetching = true
        let source = self.source
        Task { [weak self] in
            let snap = await Task.detached(priority: .utility) { () -> ScienceSnapshot in
                (try? source.snapshot()) ?? ScienceSnapshot(
                    runningCount: nil, daemonVersion: nil, sessions: [],
                    readError: .databaseUnreadable("fetch failed"))
            }.value
            self?.apply(snap)
        }
    }

    private func apply(_ snap: ScienceSnapshot) {
        guard host != nil else { fetching = false; return }
        fetching = false
        checking = false
        snapshot = snap
        for transition in engine.advance(to: snap) {
            handle(transition)
        }
        publishActivity()
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard host != nil else { return }
        // Poll fast only while something runs and the row can be seen.
        // Losing the seat is normal, not an error: slow down, don't stop.
        let visible = seat == .compact
        let interval = (isLive && visible) ? pollRunning : pollIdle
        timer = Timer.scheduledTimer(withTimeInterval: max(2, interval), repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    // MARK: - Transitions

    private func handle(_ transition: ScienceTransition) {
        switch transition {
        case .finished(let session):
            guard hudOnFinished else { return }
            presentMoment(for: session, kind: .finished)
        case .needsInput(let session):
            guard hudOnNeedsInput else { return }
            presentMoment(for: session, kind: .needsInput)
        case .started:
            break
        }
    }

    private enum MomentKind { case finished, needsInput }

    private func presentMoment(for session: SessionStatus, kind: MomentKind) {
        guard let host else { return }
        let title = session.displayTitle
        let detail = session.projectName
        let label: String
        let priority: DropletHUDPriority
        let duration: TimeInterval?
        switch kind {
        case .finished:
            label = "Session finished: \(title)"
            priority = .normal
            duration = 6
        case .needsInput:
            label = "Session needs input: \(title)"
            priority = .high
            duration = nil
        }
        let request = DropletHUDRequest(
            id: "science-transition",
            duration: duration,
            priority: priority,
            accessibilityLabel: label,
            isExpanded: true,
            expandedContentHeight: ScienceMomentCard.height
        ) {
            ScienceStripView(systemImage: session.state.systemImage, text: session.state.label)
        } expanded: {
            ScienceMomentCard(
                title: title,
                detail: detail,
                stateLabel: session.state.label,
                systemImage: session.state.systemImage,
                openTitle: "Open",
                onOpen: { [self, session] in self.openSession(session) }
            )
        }
        if !host.hud.present(request) {
            host.log.debug("HUD not shown")
        }
    }

    // MARK: - Actions

    func openSession(_ session: SessionStatus) {
        guard let host, let url = session.deepLink else { return }
        if !host.workspace.open(url) {
            host.log.debug("Workspace refused to open session")
        }
    }

    func openDashboard() {
        guard let host, let url = URL(string: "http://localhost:\(snapshot.port ?? 8765)") else { return }
        if !host.workspace.open(url) {
            host.log.debug("Workspace refused to open dashboard")
        }
    }

    // MARK: - Live activity

    private func publishActivity() {
        let count = runningCount
        guard count > 0 else {
            activitySubject.send(nil)
            return
        }
        let waiting = waitingCount
        let title: String
        if waiting > 0 {
            title = waiting == 1
                ? "Claude Science: a session needs input"
                : "Claude Science: \(waiting) sessions need input"
        } else {
            title = count == 1
                ? "Claude Science working"
                : "Claude Science: \(count) working"
        }
        activitySubject.send(LiveActivityState(
            priority: 120,
            accessibilityTitle: title,
            isInteractive: false
        ))
    }

    // MARK: - Settings persistence

    private func save<Value: Codable>(_ value: Value, forKey key: String) {
        guard let host, !restoring else { return }
        host.preferences.setValue(value, forKey: key)
    }

    private func restoreSettings() {
        guard let host else { return }
        restoring = true
        defer { restoring = false }
        pollRunning = host.preferences.value(forKey: "pollRunning", default: 3)
        pollIdle = host.preferences.value(forKey: "pollIdle", default: 30)
        hudOnFinished = host.preferences.value(forKey: "hudOnFinished", default: true)
        hudOnNeedsInput = host.preferences.value(forKey: "hudOnNeedsInput", default: true)
        minDuration = host.preferences.value(forKey: "minDuration", default: 30)
    }
}

// MARK: - Shelf widget

extension ScienceStatusDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "sessions",
                title: "Science status",
                systemImage: "atom",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(168)
                ),
                searchKeywords: ["claude", "science", "agent", "session"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(ScienceWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

/// The widget. Solo and paired are different compositions, not one view at
/// two widths: branch on `context.isCompact`.
private struct ScienceWidget: View {
    @ObservedObject var droplet: ScienceStatusDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "atom")
                    .font(.system(size: 12, weight: .medium))
                Text("Science status")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if !context.isCompact {
                    Button {
                        droplet.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                }
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            if context.isPreview {
                SciencePreviewBody()
            } else {
                ScienceLiveBody(droplet: droplet, compact: context.isCompact)
            }

            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Live content: loading, error, working, recent, or empty — never invented.
private struct ScienceLiveBody: View {
    @ObservedObject var droplet: ScienceStatusDroplet
    let compact: Bool

    var body: some View {
        let snap = droplet.snapshot
        if droplet.checking {
            ScienceLine(title: "Checking…", state: nil)
        } else if let error = snap.readError, snap.sessions.isEmpty {
            VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                Text(error.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(error.hint)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        } else if !snap.sessions.isEmpty {
            // The list read but something else did not: say so, rather than
            // let the pill vanish while the list looks current.
            if let error = snap.readError {
                Text(error.label)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
            } else if droplet.isLive {
                ScienceLine(title: summary, state: nil, monospaced: true)
            }
            // The source sorts working and waiting sessions first. Two rows
            // under a lead line: a third reaches the island's rounded corner.
            let hasLead = snap.readError != nil || droplet.isLive
            ForEach(snap.sessions.prefix(compact ? 1 : (hasLead ? 2 : 3))) { session in
                ScienceSessionRow(droplet: droplet, session: session, compact: compact)
            }
        } else {
            VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                Text("No recent sessions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                if !compact {
                    Button {
                        droplet.openDashboard()
                    } label: {
                        Text("Open Claude Science")
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }

    private var summary: String {
        let waiting = droplet.waitingCount
        let working = droplet.runningCount - waiting
        let parts = [
            working > 0 ? "\(working) working" : nil,
            waiting > 0 ? "\(waiting) \(waiting == 1 ? "needs" : "need") input" : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// Deterministic preview for the widget gallery. Made-up names only.
private struct SciencePreviewBody: View {
    var body: some View {
        ScienceLine(title: "1 working · 1 needs input", state: nil, monospaced: true)
        ScienceLine(title: "Compare 16S diversity across plots", state: "Working")
        ScienceLine(title: "Fit Michaelis–Menten curves", state: "Needs input")
    }
}

private struct ScienceLine: View {
    let title: String
    let state: String?
    var monospaced = false

    var body: some View {
        HStack {
            Group {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .monospacedDigit()
            Spacer(minLength: DroppySpacing.md)
            if let state {
                Text(state)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        }
    }
}

private struct ScienceSessionRow: View {
    @ObservedObject var droplet: ScienceStatusDroplet
    let session: SessionStatus
    let compact: Bool

    private var rowTitle: String {
        session.title.isEmpty ? "Untitled session" : session.title
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !compact {
                    Text(session.projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: DroppySpacing.md)
            Text(session.state.label)
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            if !compact, session.deepLink != nil {
                Button {
                    droplet.openSession(session)
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open session")
                .accessibilityLabel("Open \(rowTitle)")
            }
        }
    }
}

// MARK: - Live activity

extension ScienceStatusDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {
        // Losing the seat is normal, not an error. Slow down while nobody
        // can see the row; speed back up when it returns.
        self.seat = seat
        reschedule()
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(
            // A session waiting on the user outranks one that is working.
            Image(systemName: waitingCount > 0 ? SessionState.needsInput.systemImage : "atom")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .padding(.trailing, DroppySpacing.sm)
        )
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(
            Text(trailingText)
                .font(.system(
                    size: DroppyLiveActivityMetrics.labelFontSize,
                    weight: .medium,
                    design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }

    /// Short enough for a 70pt notch wing: one word, or a count.
    private var trailingText: String {
        let count = runningCount
        if count > 1 { return "\(count) active" }
        return waitingCount > 0 ? "Waiting" : "Working"
    }

    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        // Not mounted by Droppy: hovering or clicking the row opens the
        // shelf, where the widget is. Controls belong there.
        AnyView(EmptyView())
    }
}

// MARK: - HUD

extension ScienceStatusDroplet: HUDPresenting {}

/// The strip: content at the two outer edges, nothing in the middle —
/// the middle is the camera housing. Never centred.
private struct ScienceStripView: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

/// The card the strip grows into: title, description, one primary action.
/// Three rows, so it fits the island's card (208pt wide) as well as the
/// notch's; `height` is what they need, stated rather than left to the host.
private struct ScienceMomentCard: View {
    static let height: CGFloat = 76

    let title: String
    let detail: String
    let stateLabel: String
    let systemImage: String
    let openTitle: String
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(stateLabel)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: DroppySpacing.sm) {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button(action: onOpen) {
                    Text(openTitle)
                }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings pane

extension ScienceStatusDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(ScienceSettingsPane(droplet: self))
    }
}

private struct ScienceSettingsPane: View {
    @ObservedObject var droplet: ScienceStatusDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsSection {
                Text("Watching")
                    .font(.headline)
            } content: {
                DropletSettingsCard {
                    DropletSliderRow(
                        title: "Check while working",
                        value: "\(Int(droplet.pollRunning)) seconds",
                        binding: $droplet.pollRunning,
                        range: 2 ... 10,
                        step: 1
                    )
                    DropletSliderRow(
                        title: "Check while idle",
                        value: "\(Int(droplet.pollIdle)) seconds",
                        binding: $droplet.pollIdle,
                        range: 15 ... 60,
                        step: 5
                    )
                    DropletSliderRow(
                        title: "Skip sessions shorter than",
                        value: shortSessionLabel,
                        binding: $droplet.minDuration,
                        range: 0 ... 120,
                        step: 15
                    )
                }
            }
            DropletSettingsSection {
                Text("Notifications")
                    .font(.headline)
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Finished sessions",
                        subtitle: "Show a card when a session finishes.",
                        isOn: $droplet.hudOnFinished
                    )
                    DropletToggleRow(
                        title: "Needs input",
                        subtitle: "Show a card when a session waits on an approval or an answer.",
                        isOn: $droplet.hudOnNeedsInput
                    )
                }
            }
            DropletSettingsSection {
                Text("About")
                    .font(.headline)
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Source") {
                        Text("Local, read-only")
                            .foregroundStyle(.secondary)
                    }
                    DropletControlRow(title: "Daemon") {
                        DropletValuePill(text: droplet.snapshot.daemonVersion ?? "Not running")
                    }
                }
            }
        }
    }

    private var shortSessionLabel: String {
        let value = Int(droplet.minDuration)
        if value == 0 { return "Off" }
        return "\(value) seconds"
    }
}
