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
            CREATE TABLE frame_messages (frame_id TEXT NOT NULL, idx INTEGER NOT NULL, msg_json TEXT NOT NULL,
                msg_uuid TEXT, PRIMARY KEY (frame_id, idx));
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

    private func message(_ frame: String, _ idx: Int, _ json: String) -> String {
        "INSERT INTO frame_messages VALUES ('\(frame)', \(idx), '\(json)', NULL);"
    }

    func testCountsOnlyYourOwnMessagesPerDay() throws {
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        let yesterday = today.addingTimeInterval(-86_400)
        try sqlite([
            root("s1", status: "completed", updated: 1),
            root("hidden", status: "completed", updated: 1, hidden: 1),
            child("sub", of: "s1", status: "completed", hidden: 1),
            // Yours: a user message with an intent, in a session's root.
            message("s1", 0, #"{"role":"user","_intent_id":"i1","_ts":\#(ms(today)),"content":"x"}"#),
            message("s1", 1, #"{"role":"user","_intent_id":"i2","_ts":\#(ms(today)),"content":"x"}"#),
            message("s1", 2, #"{"role":"user","_intent_id":"i3","_ts":\#(ms(yesterday)),"content":"x"}"#),
            // Not yours: a tool result, a harness notice, an agent's instructions to a
            // sub-agent, a hidden session, and one too old to have a timestamp.
            message("s1", 3, #"{"role":"user","_ts":\#(ms(today)),"content":[{"type":"tool_result"}]}"#),
            message("s1", 4, #"{"role":"user","_harness_notice":true,"_ts":\#(ms(today)),"content":"x"}"#),
            message("sub", 0, #"{"role":"user","_intent_id":"i4","_ts":\#(ms(today)),"content":"x"}"#),
            message("hidden", 0, #"{"role":"user","_intent_id":"i5","_ts":\#(ms(today)),"content":"x"}"#),
            message("s1", 5, #"{"role":"user","_intent_id":"i6","content":"x"}"#),
            message("s1", 6, #"{"role":"assistant","_ts":\#(ms(today)),"content":"x"}"#),
        ].joined(separator: "\n"))

        let counts = try fetchDailyMessageCounts(db: db, days: 30)
        XCTAssertEqual(counts, [DailyCounts.key(for: today): 2, DailyCounts.key(for: yesterday): 1])
    }

    func testSumsInputAndOutputTokensPerDayIncludingSubAgents() throws {
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        let tokens = { (input: Int, output: Int) in
            #"{"input":\#(input),"output":\#(output),"cache_read":0,"cache_write":0,"uncached":\#(input)}"#
        }
        try sqlite([
            root("s1", status: "completed", updated: 1),
            child("sub", of: "s1", status: "completed", hidden: 1),
            message("s1", 0, #"{"role":"assistant","_ts":\#(ms(today)),"_tokens":\#(tokens(1000, 50))}"#),
            message("sub", 0, #"{"role":"assistant","_ts":\#(ms(today)),"_tokens":\#(tokens(200, 5))}"#),
            message("s1", 1, #"{"role":"user","_intent_id":"i1","_ts":\#(ms(today))}"#),
        ].joined(separator: "\n"))

        XCTAssertEqual(try fetchDailyTokenCounts(db: db, days: 30), [DailyCounts.key(for: today): 1255])
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
        XCTAssertEqual(counts, [DailyCounts.key(for: today): 2, DailyCounts.key(for: yesterday): 1])
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
