// CLIStatus.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// What `claude-science status` tells us. Documented, always exits 0,
/// no auth to manage — the cheapest signal available.
public struct CLIStatus: Sendable, Equatable {
    public let running: Bool
    public let activeFrames: Int
    public let activeConversations: Int
    public let version: String
    public let port: Int

    public init(running: Bool, activeFrames: Int, activeConversations: Int, version: String, port: Int) {
        self.running = running
        self.activeFrames = activeFrames
        self.activeConversations = activeConversations
        self.version = version
        self.port = port
    }
}

/// Locate the `claude-science` binary. Never writes, only resolves a path.
func resolveCLI() -> URL? {
    let candidates = [
        NSHomeDirectory() + "/.local/bin/claude-science",
        "/opt/homebrew/bin/claude-science",
        "/usr/local/bin/claude-science",
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    // PATH fallback.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    task.arguments = ["claude-science"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
            return URL(fileURLWithPath: out)
        }
    } catch { return nil }
    return nil
}

/// Run `claude-science status` with a timeout and parse the fields we need.
/// Throws `ScienceError.daemonNotRunning` when `.running` is false.
public func fetchCLIStatus(timeout: TimeInterval = 5) throws -> CLIStatus {
    guard let cli = resolveCLI() else { throw ScienceError.cliMissing }
    let task = Process()
    task.executableURL = cli
    task.arguments = ["status"]
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do { try task.run() } catch { throw ScienceError.cliFailed(error.localizedDescription) }

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { task.waitUntilExit(); group.leave() }
    if group.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        throw ScienceError.cliFailed("timed out")
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ScienceError.cliFailed("unparseable output") }

    let running = (json["running"] as? Bool) ?? false
    guard running else { throw ScienceError.daemonNotRunning }
    let daemon = json["daemon"] as? [String: Any] ?? [:]
    // active_frames lives inside daemon; fall back to 0 (idle) when absent.
    let activeFrames = (daemon["active_frames"] as? Int)
        ?? (daemon["activeFrames"] as? Int) ?? 0
    let activeConversations = (daemon["active_conversations"] as? Int)
        ?? (daemon["activeConversations"] as? Int) ?? 0
    let version = (json["version"] as? String) ?? "unknown"
    let port = (json["port"] as? Int) ?? 8765
    return CLIStatus(
        running: true,
        activeFrames: activeFrames,
        activeConversations: activeConversations,
        version: version,
        port: port
    )
}
