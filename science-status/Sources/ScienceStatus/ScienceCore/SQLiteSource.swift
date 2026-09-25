// SQLiteSource.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.
//
// Reads the daemon's SQLite database with the system `sqlite3` tool in
// read-only mode (`file:...?mode=ro`), one short query per poll, connection
// never held open. Metadata only: ids, names, statuses, timestamps.
// Never input_data / output_data / task_summary / payload bodies; the one
// look at an output is a count of its pending input requests, taken inside
// SQLite (see `pendingInputSQL`).

import Foundation

/// Resolve the org database path without guessing:
///
/// 1. `~/.claude-science/active-org.json` → `orgs/<uuid>/operon-cli.db`
/// 2. Fallback: newest `~/.claude-science/orgs/*/operon-cli.db`
func resolveDatabase() -> URL? {
    let home = NSHomeDirectory()
    let base = URL(fileURLWithPath: home + "/.claude-science")
    if
        let data = try? Data(contentsOf: base.appendingPathComponent("active-org.json")),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let uuid = json["org_uuid"] as? String
    {
        let db = base.appendingPathComponent("orgs/\(uuid)/operon-cli.db")
        if FileManager.default.isReadableFile(atPath: db.path) { return db }
    }
    let orgs = base.appendingPathComponent("orgs")
    guard
        let uuids = try? FileManager.default.contentsOfDirectory(atPath: orgs.path)
    else { return nil }
    var newest: (URL, Date)?
    for uuid in uuids {
        let db = orgs.appendingPathComponent("\(uuid)/operon-cli.db")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: db.path),
           let modified = attrs[.modificationDate] as? Date,
           FileManager.default.isReadableFile(atPath: db.path)
        {
            if newest == nil || modified > newest!.1 { newest = (db, modified) }
        }
    }
    return newest?.0
}

func resolveSqlite3() -> URL {
    for path in ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"] {
        if FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
    }
    return URL(fileURLWithPath: "/usr/bin/sqlite3")
}

/// Run one read-only query, return raw rows split on `separator`.
func runReadOnlyQuery(db: URL, sql: String, timeout: TimeInterval = 8) throws -> [[String]] {
    let separator = "\u{1F}"
    let task = Process()
    task.executableURL = resolveSqlite3()
    task.arguments = ["-separator", separator, "-list", "file:\(db.path)?mode=ro", sql]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch {
        throw ScienceError.databaseUnreadable(error.localizedDescription)
    }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { task.waitUntilExit(); group.leave() }
    if group.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        throw ScienceError.databaseUnreadable("query timed out")
    }
    guard task.terminationStatus == 0 else {
        throw ScienceError.databaseUnreadable("query failed (schema changed?)")
    }
    let out = String(
        data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init) }
}

/// One session row: a conversation root, metadata only.
struct FrameRow: Equatable {
    let id: String
    let projectID: String
    let name: String
    let status: String
    let createdMs: Int64
    let updatedMs: Int64
    let completedMs: Int64?
    /// When the latest turn began: the last user message, else creation.
    let turnStartedMs: Int64
    let hasPendingInput: Bool
}

/// SQL that is true when `alias`'s output lists pending input requests.
/// The same test the daemon's dashboard runs. It measures the array in
/// SQLite; the output body itself never leaves the database.
private func pendingInputSQL(_ alias: String) -> String {
    let output = """
        COALESCE(\(alias).output_data, (SELECT b.body FROM frame_blobs b \
        WHERE b.frame_id = \(alias).id AND b.kind = 'output'))
        """
    return """
        COALESCE(json_array_length(CASE WHEN json_valid(\(output)) THEN \(output) END, \
        '$.pending_input_requests'), 0) > 0
        """
}

/// What Claude Science's own dashboard counts as a session: conversation
/// roots only, never hidden sub-agents, uploads or the concierge.
private func sessionFilterSQL(_ alias: String) -> String {
    """
    \(alias).parent_frame_id IS NULL
      AND \(alias).is_hidden IS NOT 1
      AND \(alias).conversation_type != 'uploads'
      AND \(alias).agent_name NOT IN ('CONCIERGE','CANVAS_CONCIERGE')
    """
}

/// Recent sessions, the way Claude Science's own dashboard picks them (see
/// `sessionFilterSQL`). Working and waiting sessions sort first so they are
/// never pushed out of `limit`, then by the latest activity anywhere in the
/// tree. `limit` keeps the poll cheap against a 1 GB db.
func fetchRecentFrames(db: URL, limit: Int = 25) throws -> [FrameRow] {
    let awaiting = "'awaiting_user_response','awaiting_plan_approval'"
    let sql = """
        SELECT f.id, COALESCE(f.project_id,''), COALESCE(f.name,''), f.status,
               f.created_at, f.updated_at, COALESCE(f.completed_at,''),
               MAX(f.created_at, COALESCE(f.last_user_message_at, 0)),
               CASE WHEN f.status = 'processing' AND (\(pendingInputSQL("f")) OR EXISTS (
                   SELECT 1 FROM frames c
                   WHERE c.root_frame_id = f.id AND c.parent_frame_id IS NOT NULL
                     AND c.is_hidden IS NOT 1
                     AND (c.status IN (\(awaiting))
                          OR (c.status = 'processing' AND \(pendingInputSQL("c"))))
               )) THEN 1 ELSE 0 END
        FROM frames f
        WHERE \(sessionFilterSQL("f"))
        ORDER BY f.status IN ('processing',\(awaiting)) DESC,
                 MAX(f.updated_at, COALESCE((SELECT MAX(c.updated_at) FROM frames c
                     WHERE c.root_frame_id = f.id AND c.parent_frame_id IS NOT NULL), 0)) DESC
        LIMIT \(max(1, min(limit, 50)));
        """
    let rows = try runReadOnlyQuery(db: db, sql: sql)
    return rows.compactMap { cols in
        guard cols.count >= 9 else { return nil }
        let created = Int64(cols[4]) ?? 0
        return FrameRow(
            id: cols[0], projectID: cols[1], name: cols[2], status: cols[3],
            createdMs: created, updatedMs: Int64(cols[5]) ?? 0,
            completedMs: cols[6].isEmpty ? nil : Int64(cols[6]),
            turnStartedMs: Int64(cols[7]) ?? created,
            hasPendingInput: cols[8] == "1"
        )
    }
}

/// Sessions started per local day over the last `days`, for the activity
/// graph. One grouped count; no names, no content.
func fetchDailySessionCounts(db: URL, days: Int, now: Date = Date()) throws -> [String: Int] {
    let since = Int64((now.timeIntervalSince1970 - Double(max(1, days)) * 86_400) * 1000)
    let sql = """
        SELECT date(f.created_at / 1000, 'unixepoch', 'localtime'), COUNT(*)
        FROM frames f
        WHERE \(sessionFilterSQL("f")) AND f.created_at >= \(since)
        GROUP BY 1;
        """
    var out: [String: Int] = [:]
    for cols in try runReadOnlyQuery(db: db, sql: sql) where cols.count >= 2 {
        out[cols[0]] = Int(cols[1]) ?? 0
    }
    return out
}

/// Project names for the ids we show. Never description/context (research).
func fetchProjectNames(db: URL) throws -> [String: String] {
    let rows = try runReadOnlyQuery(db: db, sql: "SELECT id, COALESCE(name,'') FROM projects;")
    var out: [String: String] = [:]
    for cols in rows where cols.count >= 2 { out[cols[0]] = cols[1] }
    return out
}
