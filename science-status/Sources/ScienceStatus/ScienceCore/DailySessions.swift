// DailySessions.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// Sessions started per day, for the activity graph. Counts only.
public struct DailySessions: Sendable, Equatable {
    /// Local calendar day, "yyyy-MM-dd", to sessions started that day.
    public let counts: [String: Int]

    public init(counts: [String: Int]) { self.counts = counts }

    public func count(on day: Date, calendar: Calendar = .current) -> Int {
        counts[Self.key(for: day, calendar: calendar)] ?? 0
    }

    /// The same key SQLite's `date(..., 'localtime')` produces.
    public static func key(for day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// One square of the graph.
public struct ActivityCell: Sendable, Equatable, Identifiable {
    public let day: Date
    public let count: Int
    /// 0 for no sessions, then 1 through 4 as the day gets busier.
    public let level: Int
    public var id: Date { day }
}

/// The graph laid out the way GitHub's is: one column per week, oldest on
/// the left, days down each column in the calendar's week order, and no
/// squares for the days after today.
public struct ActivityGrid: Sendable, Equatable {
    public let weeks: [[ActivityCell?]]
    public let total: Int
    public let thisWeek: Int

    public init(sessions: DailySessions, today: Date, weeks count: Int, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: today)
        let row = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let lastWeek = calendar.date(byAdding: .day, value: -row, to: today)!
        let first = calendar.date(byAdding: .day, value: -7 * (max(1, count) - 1), to: lastWeek)!

        var days: [[(day: Date, count: Int)?]] = []
        for week in 0..<max(1, count) {
            days.append((0..<7).map { offset in
                let day = calendar.date(byAdding: .day, value: week * 7 + offset, to: first)!
                return day > today ? nil : (day, sessions.count(on: day, calendar: calendar))
            })
        }
        let busiest = days.joined().compactMap { $0?.count }.max() ?? 0
        weeks = days.map { column in
            column.map { $0.map { ActivityCell(day: $0.day, count: $0.count, level: Self.level($0.count, busiest: busiest)) } }
        }
        total = days.joined().compactMap { $0?.count }.reduce(0, +)
        thisWeek = days.last?.compactMap { $0?.count }.reduce(0, +) ?? 0
    }

    /// Four steps of the busiest day in view; any session at all is at least 1.
    public static func level(_ count: Int, busiest: Int) -> Int {
        guard count > 0, busiest > 0 else { return 0 }
        return min(4, Int((Double(count) / Double(busiest) * 4).rounded(.up)))
    }
}
