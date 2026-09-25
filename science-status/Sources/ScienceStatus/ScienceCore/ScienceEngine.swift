// ScienceEngine.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// A transition worth telling the user about (HUD-worthy).
public enum ScienceTransition: Sendable, Equatable {
    case started(SessionStatus)
    case finished(SessionStatus)
    case needsInput(SessionStatus)
}

/// Pure state machine: diff the last snapshot against the new one and emit
/// transitions. Unit-tested against fixtures; no I/O here.
///
/// - Sessions shorter than `minDuration` never emit `.finished` (the
///   "don't HUD for sessions shorter than N seconds" setting).
/// - `.needsInput` always emits: an approval card must never be swallowed.
/// - Unknown states never emit: fail visible in the widget, not via HUD.
/// - A read that failed outright is not news: the last good snapshot stays
///   the baseline, so a finish during the gap still emits and a card that
///   already showed does not show again.
public struct ScienceEngine: Sendable {
    public var lastByID: [String: SessionStatus] = [:]
    public var minDuration: TimeInterval

    public init(minDuration: TimeInterval = 30) { self.minDuration = minDuration }

    public mutating func advance(to snapshot: ScienceSnapshot) -> [ScienceTransition] {
        if snapshot.readError != nil, snapshot.sessions.isEmpty { return [] }
        var out: [ScienceTransition] = []
        var next: [String: SessionStatus] = [:]
        for session in snapshot.sessions {
            next[session.id] = session
            let previous = lastByID[session.id]
            guard let previous else {
                // New row. Only announce running/needs-input arrivals; history
                // backfill (finished rows we never saw run) stays quiet.
                if session.state == .running { out.append(.started(session)) }
                else if session.state == .needsInput { out.append(.needsInput(session)) }
                continue
            }
            guard previous.state != session.state else { continue }
            switch (previous.state, session.state) {
            case (.running, .finished), (.needsInput, .finished):
                if let duration = session.duration, duration < minDuration { break }
                out.append(.finished(session))
            case (_, .needsInput):
                out.append(.needsInput(session))
            case (.needsInput, .running):
                out.append(.started(session))
            default:
                break
            }
        }
        lastByID = next
        return out
    }
}
