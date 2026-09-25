// ScienceEngineTests.swift — fixture tests for the transition state machine.

import XCTest
@testable import ScienceStatus

final class ScienceEngineTests: XCTestCase {
    private func session(_ id: String, _ state: SessionState, age: TimeInterval = 600) -> SessionStatus {
        let now = Date()
        return SessionStatus(
            id: id, projectID: "proj_x", projectName: "P", title: "T",
            state: state, updatedAt: now, startedAt: now.addingTimeInterval(-age))
    }

    func testRunningArrivalEmitsStarted() {
        var engine = ScienceEngine()
        let transitions = engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x",
            sessions: [session("a", .running)]))
        XCTAssertEqual(transitions.count, 1)
        if case .started(let s) = transitions.first { XCTAssertEqual(s.id, "a") }
        else { XCTFail("expected started") }
    }

    func testBackfilledFinishedStaysQuiet() {
        var engine = ScienceEngine()
        let transitions = engine.advance(to: ScienceSnapshot(
            runningCount: 0, daemonVersion: "x",
            sessions: [session("a", .finished)]))
        XCTAssertTrue(transitions.isEmpty)
    }

    func testRunningToFinishedEmitsFinished() {
        var engine = ScienceEngine()
        _ = engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .running)]))
        let transitions = engine.advance(to: ScienceSnapshot(
            runningCount: 0, daemonVersion: "x", sessions: [session("a", .finished)]))
        XCTAssertEqual(transitions.count, 1)
        if case .finished(let s) = transitions.first { XCTAssertEqual(s.id, "a") }
        else { XCTFail("expected finished") }
    }

    func testShortSessionFinishedIsSuppressed() {
        var engine = ScienceEngine(minDuration: 30)
        _ = engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .running, age: 500)]))
        // Same row, now finished after only 10 s of life.
        let now = Date()
        let quick = SessionStatus(
            id: "a", projectID: "proj_x", projectName: "P", title: "T",
            state: .finished, updatedAt: now, startedAt: now.addingTimeInterval(-10))
        let transitions = engine.advance(to: ScienceSnapshot(
            runningCount: 0, daemonVersion: "x", sessions: [quick]))
        XCTAssertTrue(transitions.isEmpty)
    }

    func testNeedsInputAlwaysEmits() {
        var engine = ScienceEngine()
        _ = engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .running)]))
        let transitions = engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .needsInput)]))
        XCTAssertEqual(transitions.count, 1)
        if case .needsInput(let s) = transitions.first { XCTAssertEqual(s.id, "a") }
        else { XCTFail("expected needsInput") }
    }

    func testUnknownNeverEmits() {
        var engine = ScienceEngine()
        let transitions = engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .unknown)]))
        XCTAssertTrue(transitions.isEmpty)
    }

    func testFinishDuringAFailedReadStillEmits() {
        var engine = ScienceEngine()
        _ = engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .running)]))
        let failed = engine.advance(to: ScienceSnapshot(
            runningCount: nil, daemonVersion: nil, sessions: [],
            readError: .databaseUnreadable("query timed out")))
        XCTAssertTrue(failed.isEmpty)
        let transitions = engine.advance(to: ScienceSnapshot(
            runningCount: 0, daemonVersion: "x", sessions: [session("a", .finished)]))
        XCTAssertEqual(transitions.count, 1)
        if case .finished(let s) = transitions.first { XCTAssertEqual(s.id, "a") }
        else { XCTFail("expected finished") }
    }

    func testNeedsInputCardDoesNotRepeatAfterAFailedRead() {
        var engine = ScienceEngine()
        XCTAssertEqual(engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .needsInput)])).count, 1)
        _ = engine.advance(to: ScienceSnapshot(
            runningCount: nil, daemonVersion: nil, sessions: [], readError: .cliFailed("timed out")))
        XCTAssertTrue(engine.advance(to: ScienceSnapshot(
            runningCount: 1, daemonVersion: "x", sessions: [session("a", .needsInput)])).isEmpty)
    }
}

final class SessionStateTests: XCTestCase {
    func testMapsTheDaemonsStatusEnum() {
        XCTAssertEqual(SessionState(frameStatus: "processing"), .running)
        XCTAssertEqual(SessionState(frameStatus: "processing", hasPendingInput: true), .needsInput)
        XCTAssertEqual(SessionState(frameStatus: "awaiting_user_response"), .needsInput)
        XCTAssertEqual(SessionState(frameStatus: "awaiting_plan_approval"), .needsInput)
        for status in ["completed", "success", "cancelled", "replaced"] {
            XCTAssertEqual(SessionState(frameStatus: status), .finished, status)
        }
        XCTAssertEqual(SessionState(frameStatus: "failed"), .error)
        XCTAssertEqual(SessionState(frameStatus: "error"), .error)
        XCTAssertEqual(SessionState(frameStatus: "something_new"), .unknown)
    }
}
