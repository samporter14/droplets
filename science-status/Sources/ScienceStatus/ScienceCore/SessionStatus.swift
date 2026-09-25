// SessionStatus.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// One Claude Science session as the shelf/HUD/pill shows it.
///
/// Metadata only: ids, names, states, timestamps, deep link. Never message
/// bodies, payload text, or research content.
public struct SessionStatus: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let projectName: String
    public let title: String
    public let state: SessionState
    public let updatedAt: Date
    public let startedAt: Date?
    public let deepLink: URL?

    public init(
        id: String,
        projectID: String,
        projectName: String,
        title: String,
        state: SessionState,
        updatedAt: Date,
        startedAt: Date? = nil,
        deepLink: URL? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.deepLink = deepLink
    }

    /// Short display title. Falls back to project name when untitled.
    public var displayTitle: String {
        title.isEmpty ? projectName : title
    }

    /// Session length, when both ends are known. Used for the "don't HUD for
    /// sessions shorter than N seconds" threshold.
    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return updatedAt.timeIntervalSince(startedAt)
    }
}
