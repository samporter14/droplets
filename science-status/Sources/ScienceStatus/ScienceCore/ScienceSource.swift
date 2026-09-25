// ScienceSource.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// Snapshot of everything the notch needs for one refresh.
public struct ScienceSnapshot: Sendable, Equatable {
    /// Sessions working or waiting on the user (pill number). Nil when
    /// neither the daemon nor its database could be read.
    public let runningCount: Int?
    public let daemonVersion: String?
    /// The port the daemon reports it serves on, for links. Nil when unknown.
    public let port: Int?
    public let sessions: [SessionStatus]
    public let readError: ScienceError?

    public init(
        runningCount: Int?, daemonVersion: String?, port: Int? = nil,
        sessions: [SessionStatus], readError: ScienceError? = nil
    ) {
        self.runningCount = runningCount
        self.daemonVersion = daemonVersion
        self.port = port
        self.sessions = sessions
        self.readError = readError
    }

    public var hasFailure: Bool { readError != nil }
}

/// Anything that can produce a snapshot. The droplet hides every source
/// behind this so a future schema/API change touches one adapter.
public protocol ScienceSource: Sendable {
    func snapshot() throws -> ScienceSnapshot
    /// Sessions started per day over the last `days`, for the activity graph.
    func dailySessions(days: Int) throws -> DailySessions
    /// The database to watch for changes, when there is one on disk.
    var database: URL? { get }
    /// `url` made to open signed in. Blocks for a moment: call off the main thread.
    func signedIn(_ url: URL) -> URL
}

/// The real source: documented CLI for daemon health, version and port,
/// read-only SQLite for the sessions and their states. No auth, no network,
/// no capability.
public final class CombinedScienceSource: ScienceSource, @unchecked Sendable {
    /// Used for links only when the CLI cannot say which port it serves on.
    public let fallbackPort: Int
    /// How long a status result is trusted while its daemon is alive.
    public let daemonCheckInterval: TimeInterval

    private let lock = NSLock()
    private var lastStatus: (status: CLIStatus, at: Date)?

    public init(fallbackPort: Int = 8765, daemonCheckInterval: TimeInterval = 300) {
        self.fallbackPort = fallbackPort
        self.daemonCheckInterval = daemonCheckInterval
    }

    public var database: URL? { resolveDatabase() }

    public func signedIn(_ url: URL) -> URL {
        fetchLoginNonce().map { addingLoginNonce($0, to: url) } ?? url
    }

    /// The daemon's status, from the CLI only when needed: the first time,
    /// when its process has gone, or every `daemonCheckInterval`. In between,
    /// a kernel check on its pid says it is still up, for microseconds
    /// instead of the command's 0.3 s.
    private func daemonStatus() throws -> CLIStatus {
        lock.lock()
        let cached = lastStatus
        lock.unlock()
        if let cached, let pid = cached.status.pid, processIsAlive(pid),
           Date().timeIntervalSince(cached.at) < daemonCheckInterval {
            return cached.status
        }
        do {
            let status = try fetchCLIStatus()
            lock.lock(); lastStatus = (status, Date()); lock.unlock()
            return status
        } catch {
            lock.lock(); lastStatus = nil; lock.unlock()
            throw error
        }
    }

    public func snapshot() throws -> ScienceSnapshot {
        // Daemon first: the only word on whether it is up at all.
        let cli: CLIStatus
        do {
            cli = try daemonStatus()
        } catch let error as ScienceError {
            // Daemon down is a state, not a crash: report it visibly.
            if error == .daemonNotRunning {
                return ScienceSnapshot(runningCount: nil, daemonVersion: nil, sessions: [], readError: error)
            }
            // Other CLI failures still allow a DB-backed list; surface the error too.
            return try snapshotSessions(cli: nil, readError: error)
        }
        return try snapshotSessions(cli: cli, readError: nil)
    }

    private func snapshotSessions(cli: CLIStatus?, readError: ScienceError?) throws -> ScienceSnapshot {
        let port = cli?.port ?? fallbackPort
        guard let db = resolveDatabase() else {
            return ScienceSnapshot(
                runningCount: cli?.activeFrames, daemonVersion: cli?.version, port: cli?.port,
                sessions: [], readError: readError ?? .databaseMissing)
        }
        do {
            let frames = try fetchRecentFrames(db: db)
            let projects = (try? fetchProjectNames(db: db)) ?? [:]
            let sessions: [SessionStatus] = frames.map { frame in
                let state = SessionState(frameStatus: frame.status, hasPendingInput: frame.hasPendingInput)
                let link = URL(string: "http://localhost:\(port)/projects/\(frame.projectID)/frames/\(frame.id)")
                // A resumed session keeps its previous turn's completed_at
                // until this turn ends; only trust it when it is this turn's.
                let ended = frame.completedMs.flatMap { $0 >= frame.turnStartedMs ? $0 : nil }
                return SessionStatus(
                    id: frame.id,
                    projectID: frame.projectID,
                    projectName: projects[frame.projectID] ?? frame.projectID,
                    title: frame.name,
                    state: state,
                    updatedAt: date(ended ?? frame.updatedMs),
                    startedAt: date(frame.turnStartedMs),
                    deepLink: link
                )
            }
            // Counted from the rows, not the CLI's `active_frames`, which
            // also counts every sub-agent and misses sessions parked on a card.
            let active = sessions.filter { $0.state == .running || $0.state == .needsInput }.count
            return ScienceSnapshot(
                runningCount: active, daemonVersion: cli?.version, port: cli?.port,
                sessions: sessions, readError: readError)
        } catch let error as ScienceError {
            return ScienceSnapshot(
                runningCount: cli?.activeFrames, daemonVersion: cli?.version, port: cli?.port,
                sessions: [], readError: error)
        }
    }

    private func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    public func dailySessions(days: Int) throws -> DailySessions {
        guard let db = resolveDatabase() else { throw ScienceError.databaseMissing }
        return DailySessions(counts: try fetchDailySessionCounts(db: db, days: days))
    }
}

/// Fixture source for the harness, previews, and tests. No disk, no daemon.
/// Every name here is made up: these end up in public screenshots.
public struct FakeScienceSource: ScienceSource {
    public let snapshotValue: ScienceSnapshot

    public init(snapshotValue: ScienceSnapshot) { self.snapshotValue = snapshotValue }

    public func snapshot() throws -> ScienceSnapshot { snapshotValue }

    public func dailySessions(days: Int) throws -> DailySessions { Self.demoHistory(days: days) }

    public var database: URL? { nil }

    public func signedIn(_ url: URL) -> URL { url }

    /// A made-up year of sessions: busier on weekdays, quiet on most
    /// weekends, picking up lately. Seeded, so every shot draws the same.
    public static func demoHistory(days: Int, today: Date = Date(), calendar: Calendar = .current) -> DailySessions {
        var seed: UInt64 = 0x5C1E_2026
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var counts: [String: Int] = [:]
        let start = calendar.startOfDay(for: today)
        for back in 0..<max(0, days) {
            let day = calendar.date(byAdding: .day, value: -back, to: start)!
            let r = next()
            let pace = back < 28 ? 1.6 : (back < 120 ? 1.0 : 0.55)
            let n = calendar.isDateInWeekend(day)
                ? (r < 0.8 ? 0 : 1 + Int(r * 2))
                : (r < 0.22 ? 0 : Int((r * 5 * pace).rounded(.up)))
            if n > 0 { counts[DailySessions.key(for: day, calendar: calendar)] = n }
        }
        return DailySessions(counts: counts)
    }

    private static func link(_ project: String, _ frame: String) -> URL? {
        URL(string: "http://localhost:8765/projects/\(project)/frames/\(frame)")
    }

    /// What the harness and the Store screenshots show: one session
    /// working, one waiting on the user, one finished.
    public static func demo() -> FakeScienceSource {
        let now = Date()
        return FakeScienceSource(snapshotValue: ScienceSnapshot(
            runningCount: 2,
            daemonVersion: "0.1.53",
            port: 8765,
            sessions: [
                SessionStatus(
                    id: "00000000-0000-4000-8000-000000000001",
                    projectID: "proj_000000000001",
                    projectName: "Soil microbiome",
                    title: "Compare 16S diversity across plots",
                    state: .running,
                    updatedAt: now,
                    startedAt: now.addingTimeInterval(-640),
                    deepLink: link("proj_000000000001", "00000000-0000-4000-8000-000000000001")),
                SessionStatus(
                    id: "00000000-0000-4000-8000-000000000002",
                    projectID: "proj_000000000002",
                    projectName: "Enzyme kinetics",
                    title: "Fit Michaelis–Menten curves",
                    state: .needsInput,
                    updatedAt: now.addingTimeInterval(-40),
                    startedAt: now.addingTimeInterval(-900),
                    deepLink: link("proj_000000000002", "00000000-0000-4000-8000-000000000002")),
                SessionStatus(
                    id: "00000000-0000-4000-8000-000000000003",
                    projectID: "proj_000000000001",
                    projectName: "Soil microbiome",
                    title: "Literature search: nitrogen fixers",
                    state: .finished,
                    updatedAt: now.addingTimeInterval(-90),
                    startedAt: now.addingTimeInterval(-1800),
                    deepLink: link("proj_000000000001", "00000000-0000-4000-8000-000000000003")),
            ]))
    }

    public static func working() -> FakeScienceSource {
        let now = Date()
        return FakeScienceSource(snapshotValue: ScienceSnapshot(
            runningCount: 1,
            daemonVersion: "0.1.53",
            port: 8765,
            sessions: [
                SessionStatus(
                    id: "00000000-0000-4000-8000-000000000001",
                    projectID: "proj_000000000001",
                    projectName: "Soil microbiome",
                    title: "Compare 16S diversity across plots",
                    state: .running,
                    updatedAt: now,
                    startedAt: now.addingTimeInterval(-640),
                    deepLink: link("proj_000000000001", "00000000-0000-4000-8000-000000000001")),
                SessionStatus(
                    id: "00000000-0000-4000-8000-000000000003",
                    projectID: "proj_000000000001",
                    projectName: "Soil microbiome",
                    title: "Literature search: nitrogen fixers",
                    state: .finished,
                    updatedAt: now.addingTimeInterval(-90),
                    startedAt: now.addingTimeInterval(-1800)),
            ]))
    }

    public static func idle() -> FakeScienceSource {
        FakeScienceSource(snapshotValue: ScienceSnapshot(
            runningCount: 0, daemonVersion: "0.1.53", port: 8765, sessions: []))
    }

    public static func needsInput() -> FakeScienceSource {
        let now = Date()
        return FakeScienceSource(snapshotValue: ScienceSnapshot(
            runningCount: 1,
            daemonVersion: "0.1.53",
            port: 8765,
            sessions: [
                SessionStatus(
                    id: "00000000-0000-4000-8000-000000000002",
                    projectID: "proj_000000000002",
                    projectName: "Enzyme kinetics",
                    title: "Fit Michaelis–Menten curves",
                    state: .needsInput,
                    updatedAt: now,
                    startedAt: now.addingTimeInterval(-900)),
            ]))
    }

    public static func unreachable() -> FakeScienceSource {
        FakeScienceSource(snapshotValue: ScienceSnapshot(
            runningCount: nil, daemonVersion: nil, sessions: [],
            readError: .daemonNotRunning))
    }
}
