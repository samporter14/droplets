// ActivityGridTests.swift — the activity graph's layout and shading.

import XCTest
@testable import ScienceStatus

final class ActivityGridTests: XCTestCase {
    /// Sunday-first weeks in UTC, so the layout does not depend on this Mac.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testLastColumnEndsToday() {
        let wednesday = day(2026, 9, 23)
        let counts = DailyCounts(counts: [
            DailyCounts.key(for: wednesday, calendar: calendar): 3,
            DailyCounts.key(for: day(2026, 9, 21), calendar: calendar): 1,   // Monday
            DailyCounts.key(for: day(2026, 9, 12), calendar: calendar): 2,   // last week's Saturday
        ])
        let grid = ActivityGrid(counts: counts, today: wednesday, weeks: 4, calendar: calendar)

        XCTAssertEqual(grid.weeks.count, 4)
        let thisWeek = grid.weeks[3]
        XCTAssertEqual(thisWeek[0]?.day, day(2026, 9, 20))        // Sunday
        XCTAssertEqual(thisWeek[3]?.count, 3)                      // today
        XCTAssertNil(thisWeek[4])                                  // Thursday hasn't happened
        XCTAssertNil(thisWeek[6])
        XCTAssertEqual(grid.weeks[2][6]?.count, 0)                 // 19th: nothing that day
        XCTAssertEqual(grid.weeks[1][6]?.count, 2)                 // 12th
        XCTAssertEqual(grid.total, 6)
        XCTAssertEqual(grid.thisWeek, 4)
        XCTAssertEqual(thisWeek[3]?.level, 4)                      // the busiest day in view
    }

    func testLevelsRankDaysAmongTheActiveOnes() {
        let busy = [1, 2, 3]
        XCTAssertEqual(ActivityGrid.level(0, sortedBusy: busy), 0)
        XCTAssertEqual(ActivityGrid.level(1, sortedBusy: busy), 1)       // any activity shows
        XCTAssertEqual(ActivityGrid.level(2, sortedBusy: busy), 3)
        XCTAssertEqual(ActivityGrid.level(3, sortedBusy: busy), 4)       // the busiest is darkest
        XCTAssertEqual(ActivityGrid.level(5, sortedBusy: []), 0)
    }

    func testOneHeavyDayDoesNotWashOutTheRest() {
        // A token-style outlier: relative to the maximum, the 10s would be palest.
        let busy = [10, 10, 10, 10, 1_000]
        XCTAssertEqual(ActivityGrid.level(10, sortedBusy: busy), 2)
        XCTAssertEqual(ActivityGrid.level(1_000, sortedBusy: busy), 4)
    }

    func testCompactNumbers() {
        XCTAssertEqual(ActivityMetric.compact(950), "950")
        XCTAssertEqual(ActivityMetric.compact(12_400), "12.4K")
        XCTAssertEqual(ActivityMetric.compact(2_000_000), "2M")
        XCTAssertEqual(ActivityMetric.compact(2_790_540_000), "2.8B")
        XCTAssertEqual(ActivityMetric.tokens.describe(41_000_000), "41M tokens")
        XCTAssertEqual(ActivityMetric.messages.describe(1), "1 message")
    }

    func testDemoHistoryIsTheSameEveryTime() {
        let today = day(2026, 9, 23)
        XCTAssertEqual(FakeScienceSource.demoHistory(days: 120, today: today, calendar: calendar),
                       FakeScienceSource.demoHistory(days: 120, today: today, calendar: calendar))
    }
}
