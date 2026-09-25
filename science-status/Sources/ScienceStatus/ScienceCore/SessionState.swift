// SessionState.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// What a Claude Science session is doing, as far as a notch pill can say.
///
/// Local, read-only, no guessing: every case maps to a value the daemon
/// itself defines for `frames.status` (its `processing` / `awaiting_*` /
/// terminal enum in Claude Science 0.1.53, see DISCOVERY.md §7). Unknown
/// future values map to `.unknown`, which the UI renders as a visible
/// "Unknown" instead of stale or invented state.
public enum SessionState: String, Sendable, Equatable, Codable {
    case running
    case needsInput
    case finished
    case error
    case unknown

    /// `hasPendingInput` is the daemon dashboard's own test for a
    /// `processing` session that is really parked on an approval or input
    /// card, in the session or in one of its visible sub-agents.
    public init(frameStatus: String, hasPendingInput: Bool = false) {
        switch frameStatus {
        case "processing": self = hasPendingInput ? .needsInput : .running
        case "awaiting_user_response", "awaiting_plan_approval": self = .needsInput
        case "completed", "success", "cancelled", "replaced": self = .finished
        // `error` is not in the current enum but older rows carry it.
        case "failed", "error": self = .error
        default: self = .unknown
        }
    }

    /// Sentence case, never ALL-CAPS (Droppy design guidelines).
    public var label: String {
        switch self {
        case .running: return "Working"
        case .needsInput: return "Needs input"
        case .finished: return "Finished"
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .running: return "flask.fill"
        case .needsInput: return "hand.raised.fill"
        case .finished: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
