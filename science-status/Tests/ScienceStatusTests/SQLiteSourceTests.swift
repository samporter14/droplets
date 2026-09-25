// SQLiteSourceTests.swift — the session query against a throwaway database
// shaped like Claude Science 0.1.53's (only the columns the query touches).

import XCTest
@testable import ScienceStatus

final class SQLiteSourceTests: XCTestCase {
    private var directory: URL!
    private var db: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("science-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = directory.appendingPathComponent("operon-cli.db")
        try sqlite("""
            CREATE TABLE frames (
                id TEXT PRIMARY KEY, parent_frame_id TEXT, root_frame_id TEXT,
                agent_name TEXT NOT NULL, status TEXT NOT NULL, output_data TEXT,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, completed_at INTEGER,
                project_id TEXT, name TEXT, conversation_type TEXT NOT NULL,
                is_hidden INTEGER, last_user_message_at INTEGER);
            CREATE TABLE frame_blobs (frame_id TEXT, kind TEXT, body TEXT);
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sqlite(_ sql: String) throws {
        let task = Process()
        task.executableURL = resolveSqlite3()
        task.arguments = [db.path, sql]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "setup SQL failed")
    }

    private func root(
        _ id: String, status: String, updated: Int, hidden: Int = 0,
        type: String = "agent", agent: String = "MAIN", lastUser: Int? = nil, completed: Int? = nil,
        created: Int64 = 100
    ) -> String {
        """
        INSERT INTO frames VALUES ('\(id)', NULL, '\(id)', '\(agent)', '\(status)', NULL,
            \(created), \(updated), \(completed.map(String.init) ?? "NULL"), 'proj', 'Name \(id)', '\(type)',
            \(hidden), \(lastUser.map(String.init) ?? "NULL"));
        """
    }

    private func child(_ id: String, of parent: String, status: String, hidden: Int, created: Int64 = 100) -> String {
        """
        INSERT INTO frames VALUES ('\(id)', '\(parent)', '\(parent)', 'SUB', '\(status)', NULL,
            \(created), 150, NULL, 'proj', NULL, 'agent', \(hidden), NULL);
        """
    }

    func testCountsSessionsStartedPerLocalDay() throws {
        let now = Date()
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        let today = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)
        let yesterday = today.addingTimeInterval(-86_400)
        let lastYear = today.addingTimeInterval(-400 * 86_400)
        try sqlite([
            root("t1", status: "completed", updated: 1, created: ms(today)),
            root("t2", status: "processing", updated: 1, created: ms(today)),
            root("y1", status: "completed", updated: 1, created: ms(yesterday)),
            root("old", status: "completed", updated: 1, created: ms(lastYear)),
            root("hidden", status: "completed", updated: 1, hidden: 1, created: ms(today)),
            child("sub", of: "t1", status: "completed", hidden: 1, created: ms(today)),
        ].joined(separator: "\n"))

        let counts = try fetchDailySessionCounts(db: db, days: 371, now: now)
        XCTAssertEqual(counts, [DailySessions.key(for: today): 2, DailySessions.key(for: yesterday): 1])
    }

    private func output(_ id: String, _ json: String) -> String {
        "INSERT INTO frame_blobs VALUES ('\(id)', 'output', '\(json)');"
    }

    func testListsOnlyVisibleRootsWithActiveOnesFirst() throws {
        try sqlite([
            root("done", status: "completed", updated: 9000, completed: 9000),
            root("work", status: "processing", updated: 500),
            root("hidden-root", status: "processing", updated: 9999, hidden: 1),
            root("uploads", status: "completed", updated: 9999, type: "uploads"),
            root("concierge", status: "processing", updated: 9999, agent: "CONCIERGE"),
            child("sub", of: "done", status: "processing", hidden: 1),
        ].joined(separator: "\n"))

        let rows = try fetchRecentFrames(db: db)
        XCTAssertEqual(rows.map(\.id), ["work", "done"])
    }

    func testNeedsInputMatchesTheDaemonsDashboard() throws {
        try sqlite([
            root("idle-output", status: "processing", updated: 600),
            output("idle-output", #"{"pending_input_requests":[]}"#),
            root("pending", status: "processing", updated: 500),
            output("pending", #"{"pending_input_requests":[{"kind":"approval"}]}"#),
            root("parked", status: "processing", updated: 400),
            child("parked-sub", of: "parked", status: "awaiting_user_response", hidden: 0),
            root("parked-hidden", status: "processing", updated: 300),
            child("parked-hidden-sub", of: "parked-hidden", status: "awaiting_plan_approval", hidden: 1),
            root("plan", status: "awaiting_plan_approval", updated: 200),
        ].joined(separator: "\n"))

        let rows = try fetchRecentFrames(db: db)
        let states = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, SessionState(frameStatus: $0.status, hasPendingInput: $0.hasPendingInput))
        })
        XCTAssertEqual(states["idle-output"], .running)
        XCTAssertEqual(states["pending"], .needsInput)
        XCTAssertEqual(states["parked"], .needsInput)
        // The dashboard ignores hidden sub-agents; so does the droplet.
        XCTAssertEqual(states["parked-hidden"], .running)
        XCTAssertEqual(states["plan"], .needsInput)
    }

    func testTurnStartsAtTheLastUserMessage() throws {
        try sqlite(root("resumed", status: "processing", updated: 800, lastUser: 700))
        let row = try XCTUnwrap(fetchRecentFrames(db: db).first)
        XCTAssertEqual(row.createdMs, 100)
        XCTAssertEqual(row.turnStartedMs, 700)
    }
}
