// Subprocess.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// Why a command did not produce output.
enum SubprocessFailure: Error, Equatable {
    case couldNotStart(String)
    case timedOut
}

/// Run a command and return its exit status and standard output.
///
/// Output is drained while the command runs. Waiting for the exit first and
/// reading afterwards deadlocks as soon as the output outgrows the pipe
/// buffer (64 KB): the command blocks on a full pipe and never exits.
func runProcess(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: Data) {
    let task = Process()
    task.executableURL = executable
    task.arguments = arguments
    let out = Pipe()
    task.standardOutput = out
    task.standardError = FileHandle.nullDevice
    task.standardInput = FileHandle.nullDevice
    do { try task.run() } catch { throw SubprocessFailure.couldNotStart(error.localizedDescription) }

    let reader = DispatchGroup()
    let buffer = OutputBuffer()
    reader.enter()
    DispatchQueue.global(qos: .utility).async {
        buffer.data = out.fileHandleForReading.readDataToEndOfFile()   // returns at EOF, when the command exits
        reader.leave()
    }
    if reader.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        throw SubprocessFailure.timedOut
    }
    task.waitUntilExit()
    return (task.terminationStatus, buffer.data)
}

/// Written once by the reader before `leave()`, read after `wait()`.
private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}
