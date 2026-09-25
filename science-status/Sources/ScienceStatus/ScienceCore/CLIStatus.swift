// CLIStatus.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// What `claude-science status` tells us. Documented, always exits 0,
/// no auth to manage.
public struct CLIStatus: Sendable, Equatable {
    public let running: Bool
    public let activeFrames: Int
    public let activeConversations: Int
    public let version: String
    public let port: Int
    /// The daemon's process, so later checks can ask the kernel whether it is
    /// still alive instead of running this command again.
    public let pid: Int32?

    public init(running: Bool, activeFrames: Int, activeConversations: Int, version: String, port: Int, pid: Int32? = nil) {
        self.running = running
        self.activeFrames = activeFrames
        self.activeConversations = activeConversations
        self.version = version
        self.port = port
        self.pid = pid
    }
}

/// Locate the `claude-science` binary. Never writes, only resolves a path.
func resolveCLI() -> URL? {
    let candidates = [
        NSHomeDirectory() + "/.local/bin/claude-science",
        NSHomeDirectory() + "/.claude-science/bin/claude-science",
        "/opt/homebrew/bin/claude-science",
        "/usr/local/bin/claude-science",
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    // PATH fallback.
    guard
        let (_, data) = try? runProcess(URL(fileURLWithPath: "/usr/bin/which"), ["claude-science"], timeout: 3),
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !out.isEmpty, FileManager.default.isExecutableFile(atPath: out)
    else { return nil }
    return URL(fileURLWithPath: out)
}

/// Run `claude-science status` with a timeout and parse the fields we need.
/// Throws `ScienceError.daemonNotRunning` when `.running` is false.
///
/// It costs about 0.3 s of CPU, so callers check the daemon's pid between
/// runs rather than calling this on every refresh.
public func fetchCLIStatus(timeout: TimeInterval = 5) throws -> CLIStatus {
    guard let cli = resolveCLI() else { throw ScienceError.cliMissing }
    let data: Data
    do {
        data = try runProcess(cli, ["status"], timeout: timeout).output
    } catch SubprocessFailure.timedOut {
        throw ScienceError.cliFailed("timed out")
    } catch {
        throw ScienceError.cliFailed("\(error)")
    }
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
        port: port,
        pid: (json["pid"] as? Int).map(Int32.init)
    )
}

/// Whether a process is still alive: `kill` with signal 0 sends nothing, it
/// only checks. Microseconds, where the status command takes 0.3 s.
func processIsAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// A fresh single-use sign-in code from `claude-science url`, the same code
/// its own `open` command uses. It expires in about three minutes.
func fetchLoginNonce(timeout: TimeInterval = 5) -> String? {
    guard
        let cli = resolveCLI(),
        let result = try? runProcess(cli, ["url"], timeout: timeout), result.status == 0,
        let text = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
        let url = URLComponents(string: text)
    else { return nil }
    return url.queryItems?.first(where: { $0.name == "nonce" })?.value
}

/// `url` with a sign-in code attached. The daemon accepts the code on any of
/// its pages: signed-in browsers go straight there, others see one Sign in
/// button that lands on the same page.
public func addingLoginNonce(_ nonce: String, to url: URL) -> URL {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    var items = (parts.queryItems ?? []).filter { $0.name != "nonce" }
    items.append(URLQueryItem(name: "nonce", value: nonce))
    parts.queryItems = items
    return parts.url ?? url
}
