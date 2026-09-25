// DatabaseWatcher.swift
// ScienceStatus — DroppyKit-free core. No DroppyKit import in this file.

import Foundation

/// Tells the droplet the moment the daemon writes to its database, so a
/// session starting, parking on a card or finishing shows within a second
/// instead of at the next poll, and nothing runs while nothing changes.
///
/// Watches the write-ahead log (`<db>-wal`), where every write lands first,
/// with a kqueue vnode source. Not FSEvents: it reports a file's changes when
/// the file is closed, and the daemon keeps its database open for good. Not
/// the `-shm` file either: every reader touches it, the droplet's own reads
/// included.
///
/// The first write is reported at once; after that at most one report per
/// `interval`, with one trailing report so the last write is never missed.
/// When the log goes away (daemon stopped or restarted) it reports once and
/// keeps trying to reopen it.
public final class DatabaseWatcher: @unchecked Sendable {
    private let log: URL
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void

    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false

    // Touched only on `queue`.
    private var lastReport = Date.distantPast
    private var trailingScheduled = false

    public init(database: URL, interval: TimeInterval = 1, queue: DispatchQueue = .main,
                onChange: @escaping @Sendable () -> Void) {
        log = URL(fileURLWithPath: database.path + "-wal")
        self.interval = interval
        self.queue = queue
        self.onChange = onChange
        open()
    }

    /// Whether the log is open right now. False while the daemon is down;
    /// the watcher keeps retrying on its own.
    public var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return source != nil
    }

    public func stop() {
        lock.lock()
        stopped = true
        let current = source
        source = nil
        lock.unlock()
        current?.cancel()
    }

    deinit { stop() }

    private func open() {
        lock.lock()
        guard !stopped, source == nil else { lock.unlock(); return }
        let fd = Darwin.open(log.path, O_EVTONLY)
        guard fd >= 0 else {
            lock.unlock()
            reopenLater()
            return
        }
        let watched = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        watched.setEventHandler { [weak self, weak watched] in
            guard let self, let watched else { return }
            if !watched.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.lock.lock()
                if self.source === watched { self.source = nil }
                self.lock.unlock()
                watched.cancel()
                self.report()
                self.reopenLater()
            } else {
                self.report()
            }
        }
        watched.setCancelHandler { close(fd) }
        source = watched
        lock.unlock()
        watched.resume()
    }

    private func reopenLater() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.open() }
    }

    private func report() {
        let wait = interval - Date().timeIntervalSince(lastReport)
        if wait <= 0 {
            lastReport = Date()
            onChange()
        } else if !trailingScheduled {
            trailingScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.trailingScheduled = false
                self.lock.lock(); let live = !self.stopped; self.lock.unlock()
                guard live else { return }
                self.lastReport = Date()
                self.onChange()
            }
        }
    }
}
