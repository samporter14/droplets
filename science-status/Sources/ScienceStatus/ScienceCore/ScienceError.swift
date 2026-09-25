// ScienceError.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// Failures reading Claude Science state. The UI renders these as a visible
/// "can't read status" — never stale or invented sessions.
public enum ScienceError: Error, Sendable, Equatable {
    case daemonNotRunning
    case cliMissing
    case cliFailed(String)
    case databaseMissing
    case databaseUnreadable(String)
    case unknownSchema(String)

    /// What the user can do about it, shown under the label.
    public var hint: String {
        switch self {
        case .daemonNotRunning: return "Start Claude Science to see sessions."
        case .cliMissing: return "Install Claude Science, or check it is on this Mac."
        default: return "Sessions will show again once it can be read."
        }
    }

    public var label: String {
        switch self {
        case .daemonNotRunning: return "Claude Science isn't running"
        case .cliMissing: return "Can't find the claude-science tool"
        case .cliFailed: return "Can't read Claude Science status"
        case .databaseMissing: return "Can't find the Science database"
        case .databaseUnreadable: return "Can't read the Science database"
        case .unknownSchema: return "Science updated — status format changed"
        }
    }
}
