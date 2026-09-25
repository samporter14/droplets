// PlumbingTests.swift — running commands, sign-in links, watching the database.

import XCTest
@testable import ScienceStatus

final class SubprocessTests: XCTestCase {
    func testOutputLargerThanThePipeBufferComesBackWhole() throws {
        // 200 KB: three times what a pipe holds before its writer blocks.
        let result = try runProcess(URL(fileURLWithPath: "/bin/dd"),
                                    ["if=/dev/zero", "bs=1024", "count=200"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 200 * 1024)
    }

    func testTimesOut() {
        XCTAssertThrowsError(try runProcess(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.3)) {
            XCTAssertEqual($0 as? SubprocessFailure, .timedOut)
        }
    }
}

final class SignInLinkTests: XCTestCase {
    func testAttachesTheCodeAndKeepsThePath() {
        let url = URL(string: "http://localhost:8765/projects/proj_1/frames/abc")!
        XCTAssertEqual(addingLoginNonce("n1", to: url).absoluteString,
                       "http://localhost:8765/projects/proj_1/frames/abc?nonce=n1")
    }

    func testReplacesAStaleCodeAndKeepsOtherQueryItems() {
        let url = URL(string: "http://localhost:8765/?tab=files&nonce=old")!
        XCTAssertEqual(addingLoginNonce("new", to: url).absoluteString,
                       "http://localhost:8765/?tab=files&nonce=new")
    }
}

final class DatabaseWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("science-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["operon-cli.db", "operon-cli.db-wal", "operon-cli.db-shm"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func append(_ name: String) throws {
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name))
        handle.seekToEndOfFile(); handle.write(Data("x".utf8)); try handle.close()
    }

    func testFiresWhenTheWriteAheadLogChanges() throws {
        let fired = expectation(description: "change reported")
        fired.assertForOverFulfill = false
        let watcher = DatabaseWatcher(database: directory.appendingPathComponent("operon-cli.db"),
                                      interval: 0.1, queue: DispatchQueue(label: "watch-test")) { fired.fulfill() }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isWatching)
        try append("operon-cli.db-wal")
        wait(for: [fired], timeout: 5)
    }

    func testReportsOnceWhenTheLogIsDeletedAndReopensIt() throws {
        let reported = expectation(description: "deletion reported")
        reported.assertForOverFulfill = false
        let queue = DispatchQueue(label: "watch-test")
        let watcher = DatabaseWatcher(database: directory.appendingPathComponent("operon-cli.db"),
                                      interval: 0.1, queue: queue) { reported.fulfill() }
        defer { watcher.stop() }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("operon-cli.db-wal"))
        wait(for: [reported], timeout: 5)
        XCTAssertFalse(watcher.isWatching)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("operon-cli.db-wal").path, contents: Data())
        let deadline = Date().addingTimeInterval(5)
        while !watcher.isWatching, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(watcher.isWatching)                     // picked the new log up again
    }

    func testIgnoresTheSharedMemoryFileEveryReaderTouches() throws {
        let fired = expectation(description: "no change reported")
        fired.isInverted = true
        let watcher = DatabaseWatcher(database: directory.appendingPathComponent("operon-cli.db"),
                                      interval: 0.1, queue: DispatchQueue(label: "watch-test")) { fired.fulfill() }
        defer { watcher.stop() }
        try append("operon-cli.db-shm")
        wait(for: [fired], timeout: 1.5)
    }
}
