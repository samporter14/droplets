// ActivityHistory.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// What the activity graph counts.
public enum ActivityMetric: String, CaseIterable, Sendable, Codable {
    /// Sessions started that day.
    case sessions
    /// Messages the user sent that day.
    case messages
    /// Tokens the model processed that day, sub-agents included.
    case tokens

    public var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .messages: return "Messages"
        case .tokens: return "Tokens"
        }
    }

    /// For the icon-only switch in the narrow composition.
    public var systemImage: String {
        switch self {
        case .sessions: return "rectangle.stack"
        case .messages: return "text.bubble"
        case .tokens: return "number"
        }
    }

    /// "1 session", "12 messages", "2.8M tokens".
    public func describe(_ value: Int) -> String {
        switch self {
        case .sessions: return value == 1 ? "1 session" : "\(value.formatted()) sessions"
        case .messages: return value == 1 ? "1 message" : "\(value.formatted()) messages"
        case .tokens: return "\(Self.compact(value)) tokens"
        }
    }

    /// Short numbers for large counts: 950, 12.4K, 2.8M, 1.2B.
    public static func compact(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case 1_000_000_000...: return trimmed(v / 1_000_000_000) + "B"
        case 1_000_000...: return trimmed(v / 1_000_000) + "M"
        case 10_000...: return trimmed(v / 1_000) + "K"
        default: return value.formatted()
        }
    }

    private static func trimmed(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "")
    }
}

/// A count per local calendar day. Counts only.
public struct DailyCounts: Sendable, Equatable {
    /// Local calendar day, "yyyy-MM-dd", to that day's count.
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

/// Everything the activity graph can show. A metric is nil when it could
/// not be read (the daemon changed its format), so the widget can say so
/// instead of drawing an empty year.
public struct ActivityHistory: Sendable, Equatable {
    public let sessions: DailyCounts
    public let messages: DailyCounts?
    public let tokens: DailyCounts?

    public init(sessions: DailyCounts, messages: DailyCounts?, tokens: DailyCounts?) {
        self.sessions = sessions
        self.messages = messages
        self.tokens = tokens
    }

    public subscript(metric: ActivityMetric) -> DailyCounts? {
        switch metric {
        case .sessions: return sessions
        case .messages: return messages
        case .tokens: return tokens
        }
    }
}

/// One square of the graph.
public struct ActivityCell: Sendable, Equatable, Identifiable {
    public let day: Date
    public let count: Int
    /// 0 for nothing that day, then 1 through 4 as the day gets busier.
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

    public init(counts: DailyCounts, today: Date, weeks count: Int, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: today)
        let row = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let lastWeek = calendar.date(byAdding: .day, value: -row, to: today)!
        let first = calendar.date(byAdding: .day, value: -7 * (max(1, count) - 1), to: lastWeek)!

        var days: [[(day: Date, count: Int)?]] = []
        for week in 0..<max(1, count) {
            days.append((0..<7).map { offset in
                let day = calendar.date(byAdding: .day, value: week * 7 + offset, to: first)!
                return day > today ? nil : (day, counts.count(on: day, calendar: calendar))
            })
        }
        let busy = days.joined().compactMap { $0?.count }.filter { $0 > 0 }.sorted()
        weeks = days.map { column in
            column.map { $0.map { ActivityCell(day: $0.day, count: $0.count, level: Self.level($0.count, sortedBusy: busy)) } }
        }
        total = days.joined().compactMap { $0?.count }.reduce(0, +)
        thisWeek = days.last?.compactMap { $0?.count }.reduce(0, +) ?? 0
    }

    /// 0 for nothing, otherwise 1 through 4 by where the day ranks among the
    /// active days in view (its mid-rank percentile, in quarters), so the
    /// busiest days are always the darkest. Relative to the single busiest
    /// day instead, one heavy day of tokens would leave every other day in
    /// the palest shade. `sortedBusy` is the active days' values, ascending.
    public static func level(_ count: Int, sortedBusy busy: [Int]) -> Int {
        guard count > 0, !busy.isEmpty else { return 0 }
        let below = firstIndex(in: busy) { $0 >= count }
        let atOrBelow = firstIndex(in: busy) { $0 > count }
        let percentile = (Double(below) + Double(atOrBelow - below) / 2) / Double(busy.count)
        return 1 + min(3, Int(percentile * 4))
    }

    /// First index where `predicate` turns true in a sorted array.
    private static func firstIndex(in sorted: [Int], where predicate: (Int) -> Bool) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(sorted[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
