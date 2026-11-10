import CoreServices
import Foundation

/// Watches the folders that have active rules with one FSEvents stream.
/// ResilientFileWatcher watches a single file with a recovery poll, so it
/// doesn't fit: FSEvents reports changes anywhere below a folder, costs
/// nothing between events, and survives renames of the folder's contents.
/// Events are coalesced (1 s latency) and reported on the main queue as the
/// watched folders they fall under.
final class FolderRulesWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.kyw.allofmacos.folder-rules.events", qos: .utility)
    private(set) var paths: [String] = []
    private var resolved: [(watched: String, real: String)] = []
    /// Called on the main queue with the watched folder paths that changed.
    var onChange: (([String]) -> Void)?

    deinit { stop() }

    /// Starts, restarts or stops the stream for exactly these folders.
    func watch(_ newPaths: [String]) {
        let sorted = Array(Set(newPaths)).sorted()
        guard sorted != paths || (stream == nil && !sorted.isEmpty) else { return }
        stop()
        paths = sorted
        guard !sorted.isEmpty else { return }
        resolved = sorted.map { ($0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
                                             | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderRulesWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            var flags: [FSEventStreamEventFlags] = []
            for index in 0..<count { flags.append(eventFlags[index]) }
            watcher.received(changed, flags: flags)
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, sorted as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            paths = []
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            paths = []
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        paths = []
    }

    private func received(_ changed: [String], flags: [FSEventStreamEventFlags]) {
        var hits: Set<String> = []
        for path in changed {
            let real = (path as NSString).standardizingPath
            for pair in resolved where real == pair.real || real.hasPrefix(pair.real + "/") || real == pair.watched
                || real.hasPrefix(pair.watched + "/") || pair.real.hasPrefix(real + "/") {
                // The last case: a parent of the folder changed (WatchRoot: moved or deleted).
                hits.insert(pair.watched)
            }
        }
        guard !hits.isEmpty else { return }
        let folders = Array(hits)
        DispatchQueue.main.async { [weak self] in self?.onChange?(folders) }
    }
}
