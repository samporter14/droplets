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

    // Each setting saves only itself: saving all of them from one didSet made
    // restoreSettings() overwrite the stored values it had not read yet.

    /// Pin the pill in the notch while a session works. Off, the host shows it
    /// only while the pointer is over the notch. Off by default, as DroppyKit
    /// asks: pinning is a strong claim on someone else's notch.
    @Published var keepPillShowing = false {
        didSet {
            save(keepPillShowing, forKey: "keepPillShowing")
            if !restoring { publishActivity() }
        }
    }
    /// A status icon in the menu bar that opens sessions and activity. On by
    /// default: with the notch pill shown only on hover, it is the one status
    /// that is always in view.
    @Published var showInMenuBar = true { didSet { save(showInMenuBar, forKey: "showInMenuBar") } }
    /// What the activity graph counts; chosen in the widget itself.
    @Published var activityMetric: ActivityMetric = .sessions { didSet { save(activityMetric, forKey: "activityMetric") } }
    @Published var pollRunning: Double = 3 { didSet { save(pollRunning, forKey: "pollRunning"); reschedule() } }
    @Published var pollIdle: Double = 30 { didSet { save(pollIdle, forKey: "pollIdle"); reschedule() } }
    @Published var hudOnFinished = true { didSet { save(hudOnFinished, forKey: "hudOnFinished") } }
    @Published var hudOnNeedsInput = true {
        didSet {
            save(hudOnNeedsInput, forKey: "hudOnNeedsInput")
            if !hudOnNeedsInput { dismissNeedsInputHUD() }
        }
    }
    @Published var minDuration: Double = 30 {
        didSet { save(minDuration, forKey: "minDuration"); engine.minDuration = minDuration }
    }

    // MARK: - Model

    @Published private(set) var snapshot = ScienceSnapshot(
        runningCount: nil, daemonVersion: nil, sessions: [])
    @Published private(set) var checking = true
    /// Sessions started per day, for the activity graph. Nil until first read.
    @Published private(set) var history: ActivityHistory?

    private var host: DropletHost?
    private var historyReadAt: Date?
    private var readingHistory = false
    private var timer: Timer?
    private var engine = ScienceEngine()
    private var seat: DropletLiveActivitySeat = .none(.idle)
    private var fetching = false
    /// Reject reads begun by an earlier activation after the host restarts us.
    private var activationGeneration = 0
    /// A database change arrived mid-read: read once more when it ends.
    private var changedWhileFetching = false
    private var watcher: DatabaseWatcher?
    private var needsInputHUDSessionID: String?
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
        activationGeneration += 1
        self.host = host
        restoreSettings()
        engine.minDuration = minDuration
        host.log.info("Science Status activated")
        fetch()
        startWatching()
    }

    public func deactivate() {
        activationGeneration += 1
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        host?.hud.dismiss(id: "science-transition")
        needsInputHUDSessionID = nil
        host?.liveActivity.yield(reason: .idle)
        activitySubject.send(nil)
        host = nil
        fetching = false
        changedWhileFetching = false
        readingHistory = false
        historyReadAt = nil
        engine = ScienceEngine(minDuration: minDuration)
        snapshot = ScienceSnapshot(runningCount: nil, daemonVersion: nil, sessions: [])
        checking = true
        history = nil
        seat = .none(.idle)
    }

    // MARK: - Watching and polling

    func refresh() {
        fetch()
    }

    /// Read the moment the daemon writes to its database, as Droppy's own
    /// Agents droplet reacts to its agents. The timer stays as a slow
    /// fallback for anything the watcher misses.
    private func startWatching() {
        guard watcher == nil, host != nil, let database = source.database else { return }
        // Kept even when the log is not there yet: the watcher reopens it
        // on its own once the daemon starts.
        let generation = activationGeneration
        watcher = DatabaseWatcher(database: database) { [weak self] in
            Task { @MainActor in
                guard let self, self.activationGeneration == generation else { return }
                self.databaseChanged()
            }
        }
    }

    private func databaseChanged() {
        guard host != nil else { return }
        if fetching {
            changedWhileFetching = true
        } else {
            fetch()
        }
    }

    private func fetch() {
        guard !fetching, host != nil else { return }
        fetching = true
        let generation = activationGeneration
        let source = self.source
        Task { [weak self] in
            let snap = await Task.detached(priority: .utility) { () -> ScienceSnapshot in
                (try? source.snapshot()) ?? ScienceSnapshot(
                    runningCount: nil, daemonVersion: nil, sessions: [],
                    readError: .databaseUnreadable("fetch failed"))
            }.value
            guard let self, self.activationGeneration == generation else { return }
            self.apply(snap)
        }
    }

    private func apply(_ snap: ScienceSnapshot) {
        guard host != nil else { fetching = false; return }
        fetching = false
        // Assign only real changes: every published change makes the host
        // re-read the menu bar item and redraws the widgets.
        if checking { checking = false }
        if snapshot != snap { snapshot = snap }
        let transitions = engine.advance(to: snap)
        if let id = needsInputHUDSessionID, snap.readError == nil || !snap.sessions.isEmpty,
           !snap.sessions.contains(where: { $0.id == id && $0.state == .needsInput }) {
            dismissNeedsInputHUD()
        }
        for transition in transitions {
            handle(transition)
        }
        publishActivity()
        readHistoryIfDue(sessionsChanged: !transitions.isEmpty)
        reschedule()
        // The database may have appeared since activation.
        startWatching()
        if changedWhileFetching {
            changedWhileFetching = false
            fetch()
        }
    }

    // MARK: - History (the activity graph)

    /// History changes slowly: read it at activation, every ten minutes, and
    /// whenever a session starts or finishes. Riding the session poll means
    /// there is no second timer to stop.
    private func readHistoryIfDue(sessionsChanged: Bool) {
        guard host != nil, !readingHistory else { return }
        if let last = historyReadAt, !sessionsChanged, Date().timeIntervalSince(last) < 600 { return }
        readingHistory = true
        let generation = activationGeneration
        let source = self.source
        Task { [weak self] in
            let history = await Task.detached(priority: .utility) {
                try? source.activityHistory(days: 7 * 53)
            }.value
            guard let self else { return }
            guard self.activationGeneration == generation else { return }
            self.readingHistory = false
            guard self.host != nil else { return }
            self.historyReadAt = Date()
            if let history { self.history = history }
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard host != nil else { return }
        // With the database watched, changes arrive as they happen and this
        // timer is only a fallback. Without it, poll fast only while something
        // runs and the row can be seen. Losing the seat is normal, not an
        // error: slow down, don't stop.
        let visible = seat == .compact
        let watching = watcher?.isWatching ?? false
        let interval = (isLive && visible && !watching) ? pollRunning : pollIdle
        let generation = activationGeneration
        timer = Timer.scheduledTimer(withTimeInterval: max(2, interval), repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.activationGeneration == generation else { return }
                self.fetch()
            }
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

    private func dismissNeedsInputHUD() {
        guard needsInputHUDSessionID != nil else { return }
        host?.hud.dismiss(id: "science-transition")
        needsInputHUDSessionID = nil
    }

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
        if host.hud.present(request) {
            switch kind {
            case .needsInput: needsInputHUDSessionID = session.id
            case .finished: needsInputHUDSessionID = nil
            }
        } else {
            host.log.debug("HUD not shown")
        }
    }

    // MARK: - Actions

    func openSession(_ session: SessionStatus) {
        guard let url = session.deepLink else { return }
        openSignedIn(url)
    }

    func openDashboard() {
        guard let url = URL(string: "http://localhost:\(snapshot.port ?? 8765)/") else { return }
        openSignedIn(url)
    }

    /// The daemon's pages need a signed-in browser. Attach a fresh one-time
    /// sign-in code, as its own `open` command does, so the link works in a
    /// browser that has never signed in; the plain link is the fallback.
    private func openSignedIn(_ url: URL) {
        let generation = activationGeneration
        let source = self.source
        Task { [weak self] in
            let link = await Task.detached(priority: .userInitiated) { source.signedIn(url) }.value
            guard let self, self.activationGeneration == generation, let host = self.host else { return }
            if !host.workspace.open(link) {
                host.log.debug("Workspace refused to open a Science page")
            }
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
            isInteractive: false,
            joinsPersistentActivitySet: keepPillShowing
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
        keepPillShowing = host.preferences.value(forKey: "keepPillShowing", default: false)
        showInMenuBar = host.preferences.value(forKey: "showInMenuBar", default: true)
        activityMetric = host.preferences.value(forKey: "activityMetric", default: ActivityMetric.sessions)
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
            ),
            ShelfWidgetDescriptor(
                id: "activity",
                title: "Science activity",
                systemImage: "square.grid.3x3.fill",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(ScienceActivityWidget.height)
                ),
                searchKeywords: ["claude", "science", "activity", "history", "graph", "streak"]
            ),
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        if id == "activity" {
            return AnyView(ScienceActivityWidget(droplet: self, context: context))
        }
        return AnyView(ScienceWidget(droplet: self, context: context))
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
                LiveGlyph(droplet: droplet, size: 12, tint: AdaptiveColors.notchSurfaceSecondaryText)
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

// MARK: - Glyph

/// The droplet's glyph, following the droplet's state: an empty flask when
/// idle, a flask with clay liquid and rising bubbles while a session works,
/// a hand while one waits on the user.
private struct LiveGlyph: View {
    @ObservedObject var droplet: ScienceStatusDroplet
    let size: CGFloat
    let tint: Color

    var body: some View {
        ScienceGlyph(mode: droplet.waitingCount > 0 ? .needsInput : (droplet.isLive ? .working : .idle),
                     size: size, tint: tint)
    }
}

/// The only motion is inside the glyph, never around the surface Droppy
/// owns, and none at all with Reduce Motion on. The frame is fixed, so
/// switching modes never shifts the row.
private struct ScienceGlyph: View {
    enum Mode: Equatable { case idle, working, needsInput }

    let mode: Mode
    let size: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch mode {
            case .needsInput:
                symbol("hand.raised.fill")
            case .idle:
                symbol("flask")
            case .working where reduceMotion:
                symbol("flask.fill")
            case .working:
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    Canvas { context, canvas in
                        BubblingFlask.draw(in: &context, size: canvas,
                                           time: timeline.date.timeIntervalSinceReferenceDate, tint: tint)
                    }
                }
            }
        }
        .frame(width: size * 1.25, height: size * 1.25)
        .transition(DroppyTransition.compactContent)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint)
    }
}

/// A flask with clay liquid whose surface rocks gently and three small
/// bubbles rising through it, fading as they reach the surface. One loop is
/// 1.6 s; the bubbles are staggered so one is always on its way up.
enum BubblingFlask {
    static func draw(in context: inout GraphicsContext, size: CGSize, time t: Double, tint: Color) {
        var outline = context.resolve(Image(systemName: "flask"))
        var fill = context.resolve(Image(systemName: "flask.fill"))
        outline.shading = .color(tint)
        fill.shading = .color(clay)

        // The symbol at its own aspect ratio, centred in the square.
        let natural = outline.size
        let scale = min(size.width / max(natural.width, 1), size.height / max(natural.height, 1))
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        let rect = CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)

        // Liquid: the filled flask below a gently rocking surface.
        let surface = rect.minY + rect.height * (0.55 + 0.02 * sin(t * 2.4))
        var liquid = context
        liquid.clip(to: Path(CGRect(x: rect.minX, y: surface, width: rect.width, height: rect.maxY - surface)))
        liquid.draw(fill, in: rect)

        // Bubbles rise from near the bottom and fade out at the surface.
        let period = 1.6
        let bottom = rect.minY + rect.height * 0.88
        for i in 0..<3 {
            let phase = (t / period + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let x = rect.midX + rect.width * [-0.1, 0.08, -0.02][i]
            let y = bottom - (bottom - surface) * phase
            let r = rect.width * (0.05 + 0.02 * phase)
            let alpha = phase < 0.75 ? 0.85 : 0.85 * (1 - (phase - 0.75) / 0.25)
            liquid.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(alpha)))
        }

        // The flask itself on top, in the surface's own ink.
        context.draw(outline, in: rect)
    }
}

// MARK: - Activity graph widget

/// Anthropic's clay, the droplet's one accent. Empty days use Droppy's own
/// raised-tile fill, so only active days carry colour.
private let clay = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

/// A GitHub-style graph of Claude Science use per day: sessions started,
/// messages sent or tokens processed. A column per week, as many weeks as
/// the slot is wide.
private struct ScienceActivityWidget: View {
    @ObservedObject var droplet: ScienceStatusDroplet
    let context: ShelfWidgetContext

    static let cell: CGFloat = 11
    static let gap: CGFloat = 3
    /// Header with the metric switch, seven rows of squares, footer.
    static let height: CGFloat = 146

    /// Text at the ends of the header and footer sits in the widget's
    /// rounded corners, which clip it; this inner inset keeps it clear.
    static let inset = DroppySpacing.sm

    private var weeks: Int {
        var width = context.availableSize.width - context.contentInsets.leading - context.contentInsets.trailing
        if width <= 0 { width = 420 }
        width -= 2 * Self.inset
        return max(4, min(53, Int((width + Self.gap) / (Self.cell + Self.gap))))
    }

    var body: some View {
        let metric = droplet.activityMetric
        let history = context.isPreview ? FakeScienceSource.demoHistory(days: 7 * 53) : droplet.history
        let grid = history?[metric].map { ActivityGrid(counts: $0, today: Date(), weeks: weeks) }
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 12, weight: .medium))
                Text(context.isCompact ? "Activity" : "Science activity")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: DroppySpacing.sm)
                ActivityMetricSwitch(selection: $droplet.activityMetric, iconsOnly: context.isCompact)
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            if let grid {
                ActivityGridView(grid: grid, metric: metric, cell: Self.cell, gap: Self.gap)
                    .id(metric)
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(metric.describe(grid.total)) in \(span), \(metric.describe(grid.thisWeek)) this week")
                HStack(spacing: DroppySpacing.sm) {
                    Text(summary(grid, metric))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    if !context.isCompact {
                        ActivityLegend()
                    }
                }
            } else if history != nil {
                // Sessions always read; messages and tokens come from message
                // records a Claude Science update may reshape.
                Text("Can't read \(metric.title.lowercased()) from this version of Claude Science")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            } else if let error = droplet.snapshot.readError {
                Text(error.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(error.hint)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            } else {
                Text("Checking…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: metric)
        .padding(.horizontal, Self.inset)
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "2.8B tokens in the last 7 months · 41M this week", shorter when paired.
    private func summary(_ grid: ActivityGrid, _ metric: ActivityMetric) -> String {
        let total = metric.describe(grid.total)
        guard !context.isCompact else { return total }
        let week = metric == .tokens ? ActivityMetric.compact(grid.thisWeek) : grid.thisWeek.formatted()
        return "\(total) in \(span) · \(week) this week"
    }

    /// "the last year", or the months the columns cover.
    private var span: String {
        weeks >= 52 ? "the last year" : "the last \(Int((Double(weeks) * 7 / 30.44).rounded())) months"
    }
}

/// Sessions · Messages · Tokens. Droppy's shelf tokens, no border: the
/// chosen option sits on the raised-tile fill, the rest are quiet text.
/// Icons alone in the paired composition, where the words do not fit.
private struct ActivityMetricSwitch: View {
    @Binding var selection: ActivityMetric
    let iconsOnly: Bool
    var palette: ActivityPalette = .notch
    @State private var hovered: ActivityMetric?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ActivityMetric.allCases, id: \.self) { metric in
                let selected = metric == selection
                Button {
                    selection = metric
                } label: {
                    Group {
                        if iconsOnly {
                            Image(systemName: metric.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 22, height: 20)
                        } else {
                            Text(metric.title)
                                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                .padding(.horizontal, DroppySpacing.sm)
                                .frame(height: 20)
                        }
                    }
                    .foregroundStyle(selected ? palette.primary : palette.tertiary)
                    .background {
                        if selected {
                            Capsule(style: .continuous).fill(palette.selectedFill)
                        } else if hovered == metric {
                            Capsule(style: .continuous).fill(palette.hoverFill)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? metric : (hovered == metric ? nil : hovered) }
                .help(metric.title)
                .accessibilityLabel(metric.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selection)
    }
}

/// The activity graph on the notch's black, or on the menu bar panel's
/// system material, which follows the Mac's light or dark appearance.
private struct ActivityPalette {
    let empty: Color
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let selectedFill: Color
    let hoverFill: Color

    static var notch: ActivityPalette {
        ActivityPalette(
            empty: AdaptiveColors.notchSurfaceCardFill,
            primary: AdaptiveColors.notchSurfacePrimaryText,
            secondary: AdaptiveColors.notchSurfaceSecondaryText,
            tertiary: AdaptiveColors.notchSurfaceTertiaryText,
            selectedFill: AdaptiveColors.notchSurfaceCardHoverFill,
            hoverFill: AdaptiveColors.notchSurfaceCardFill)
    }

    static var menu: ActivityPalette {
        ActivityPalette(
            empty: AdaptiveColors.contrastTintAuto.opacity(0.08),
            primary: AdaptiveColors.primaryTextAuto,
            secondary: AdaptiveColors.secondaryTextAuto,
            tertiary: AdaptiveColors.secondaryTextAuto.opacity(0.75),
            selectedFill: AdaptiveColors.hoverBackgroundAuto,
            hoverFill: AdaptiveColors.buttonBackgroundAuto)
    }
}

private func activityFill(_ level: Int, palette: ActivityPalette = .notch) -> Color {
    switch level {
    case 0: return palette.empty
    // The same ramp as the Focus droplet's stats graph, so the two read alike.
    case 1: return clay.opacity(0.3)
    case 2: return clay.opacity(0.5)
    case 3: return clay.opacity(0.75)
    default: return clay
    }
}

private struct ActivityGridView: View {
    let grid: ActivityGrid
    let metric: ActivityMetric
    let cell: CGFloat
    let gap: CGFloat
    var palette: ActivityPalette = .notch

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        if let day = week[row] {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(activityFill(day.level, palette: palette))
                                .frame(width: cell, height: cell)
                                .help(tooltip(day))
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }

    private func tooltip(_ day: ActivityCell) -> String {
        let date = day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard day.count > 0 else { return "No \(metric.title.lowercased()) on \(date)" }
        return "\(metric.describe(day.count)) on \(date)"
    }
}

private struct ActivityLegend: View {
    var palette: ActivityPalette = .notch

    var body: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(activityFill(level, palette: palette))
                    .frame(width: 9, height: 9)
            }
            Text("More")
        }
        .font(.system(size: 10))
        .foregroundStyle(palette.tertiary)
        .accessibilityHidden(true)
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
            LiveGlyph(droplet: self, size: DroppyLiveActivityMetrics.iconSize,
                      tint: AdaptiveColors.notchSurfacePrimaryText)
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

// MARK: - Menu bar

extension ScienceStatusDroplet: MenuBarExtraProviding {
    public func makeMenuBarExtra() -> MenuBarExtraDescriptor? {
        guard showInMenuBar else { return nil }
        return MenuBarExtraDescriptor(title: menuBarTitle, systemImage: menuBarSymbol) { [self] in
            AnyView(ScienceMenuBarPanel(droplet: self))
        }
    }

    /// The host shows a symbol only, so the symbol carries the status: a
    /// hand while a session waits on the user, a filled flask while one
    /// works, an empty flask otherwise. It changes only when the state does.
    var menuBarSymbol: String {
        if waitingCount > 0 { return "hand.raised.fill" }
        if isLive { return "flask.fill" }
        return "flask"
    }

    var menuBarTitle: String {
        if snapshot.readError != nil, snapshot.sessions.isEmpty { return "Claude Science: can't read status" }
        let waiting = waitingCount
        let working = runningCount - waiting
        if waiting > 0 {
            return waiting == 1 ? "Claude Science: a session needs input" : "Claude Science: \(waiting) sessions need input"
        }
        if working > 0 { return working == 1 ? "Claude Science: working" : "Claude Science: \(working) working" }
        return "Claude Science: idle"
    }

    func openDropletSettings() {
        guard let host else { return }
        if !host.workspace.openSettings() {
            host.log.debug("Settings did not open")
        }
    }
}

/// What the menu bar item opens: status, the latest sessions, and the
/// activity graph. It sits on the system menu material, so it uses the
/// adaptive colours rather than the notch's white on black.
private struct ScienceMenuBarPanel: View {
    @ObservedObject var droplet: ScienceStatusDroplet

    static let width: CGFloat = 300
    static let cell: CGFloat = 9
    static let gap: CGFloat = 2

    private var palette: ActivityPalette { .menu }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            header
            sessionList
            activity
            footer
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.vertical, DroppySpacing.xs)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            LiveGlyph(droplet: droplet, size: 13, tint: droplet.isLive ? palette.primary : palette.secondary)
            Text("Claude Science")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primary)
            Spacer(minLength: DroppySpacing.sm)
            Text(status)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
        }
    }

    private var status: String {
        let snap = droplet.snapshot
        if droplet.checking { return "Checking…" }
        if snap.readError != nil, snap.sessions.isEmpty { return "Can't read status" }
        let waiting = droplet.waitingCount
        let working = droplet.runningCount - waiting
        let parts = [
            working > 0 ? "\(working) working" : nil,
            waiting > 0 ? "\(waiting) \(waiting == 1 ? "needs" : "need") input" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var sessionList: some View {
        let snap = droplet.snapshot
        let recent = Array(snap.sessions.prefix(5))
        if let error = snap.readError, recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.primary)
                Text(error.hint)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
            }
        } else if recent.isEmpty {
            Text("No recent sessions")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(recent) { session in
                    MenuSessionRow(session: session, palette: palette) { droplet.openSession(session) }
                }
            }
            .padding(.horizontal, -DroppySpacing.xsm)
        }
    }

    @ViewBuilder private var activity: some View {
        let metric = droplet.activityMetric
        let weeks = Int((Self.width + Self.gap) / (Self.cell + Self.gap))
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Text("Activity")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                Spacer(minLength: DroppySpacing.sm)
                ActivityMetricSwitch(selection: $droplet.activityMetric, iconsOnly: true, palette: palette)
            }
            if let counts = droplet.history?[metric] {
                let grid = ActivityGrid(counts: counts, today: Date(), weeks: weeks)
                ActivityGridView(grid: grid, metric: metric, cell: Self.cell, gap: Self.gap, palette: palette)
                    .id(metric)
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(metric.describe(grid.total)) in the last \(weeks) weeks")
                HStack(spacing: DroppySpacing.sm) {
                    Text("\(metric.describe(grid.total)) in \(weeks) weeks")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ActivityLegend(palette: palette)
                }
            } else {
                Text(droplet.history == nil ? "Checking…" : "Can't read \(metric.title.lowercased()) from this version of Claude Science")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: metric)
    }

    private var footer: some View {
        HStack(spacing: DroppySpacing.sm) {
            Button {
                droplet.openDashboard()
            } label: {
                Text("Open Claude Science")
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
            Spacer(minLength: 0)
            Button {
                droplet.openDropletSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Science Status settings")
            .accessibilityLabel("Science Status settings")
        }
    }
}

/// One session in the menu bar panel. The whole row opens it, like a menu
/// item, with the menu's own hover highlight.
private struct MenuSessionRow: View {
    let session: SessionStatus
    let palette: ActivityPalette
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: DroppySpacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title.isEmpty ? "Untitled session" : session.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(session.projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: DroppySpacing.sm)
                Text(session.state.label)
                    .font(.system(size: 12, weight: session.state == .needsInput ? .semibold : .regular))
                    .foregroundStyle(session.state == .needsInput ? clay : palette.secondary)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, DroppySpacing.xsm)
            .padding(.vertical, 4)
            .background {
                if hovering {
                    RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                        .fill(palette.hoverFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in Claude Science")
        .accessibilityLabel("\(session.title.isEmpty ? "Untitled session" : session.title), \(session.state.label)")
        .accessibilityHint("Opens it in Claude Science")
    }
}

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
                Text("Notch and menu bar")
                    .font(.headline)
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Keep the pill showing",
                        subtitle: "Show it in the notch while a session works. Off, it appears only when you hover the notch.",
                        isOn: $droplet.keepPillShowing
                    )
                    DropletToggleRow(
                        title: "Show in the menu bar",
                        subtitle: "A flask that fills while a session works and turns into a hand when one needs you. Click it for your sessions and activity.",
                        isOn: $droplet.showInMenuBar
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
