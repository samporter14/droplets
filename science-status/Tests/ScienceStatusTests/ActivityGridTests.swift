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
        let sessions = DailySessions(counts: [
            DailySessions.key(for: wednesday, calendar: calendar): 3,
            DailySessions.key(for: day(2026, 9, 21), calendar: calendar): 1,   // Monday
            DailySessions.key(for: day(2026, 9, 12), calendar: calendar): 2,   // last week's Saturday
        ])
        let grid = ActivityGrid(sessions: sessions, today: wednesday, weeks: 4, calendar: calendar)

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

    func testLevelsStepByQuartersOfTheBusiestDay() {
        XCTAssertEqual(ActivityGrid.level(0, busiest: 8), 0)
        XCTAssertEqual(ActivityGrid.level(1, busiest: 8), 1)       // any session shows
        XCTAssertEqual(ActivityGrid.level(2, busiest: 8), 1)
        XCTAssertEqual(ActivityGrid.level(3, busiest: 8), 2)
        XCTAssertEqual(ActivityGrid.level(6, busiest: 8), 3)
        XCTAssertEqual(ActivityGrid.level(8, busiest: 8), 4)
        XCTAssertEqual(ActivityGrid.level(0, busiest: 0), 0)
    }

    func testDemoHistoryIsTheSameEveryTime() {
        let today = day(2026, 9, 23)
        XCTAssertEqual(FakeScienceSource.demoHistory(days: 120, today: today, calendar: calendar),
                       FakeScienceSource.demoHistory(days: 120, today: today, calendar: calendar))
    }
}
