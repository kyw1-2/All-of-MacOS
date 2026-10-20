import Foundation
import Darwin

/// Watches the target inode and its parent. The parent event re-arms a replaced
/// inode; a small retry timer also handles a missing target or parent at startup.
/// All callbacks run on main, and stop cancels every source before release.
final class ResilientFileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var parentSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var signature: Signature?
    private var active = false
    private struct Signature: Equatable {
        var inode: UInt64
        var size: UInt64
        var modified: Double
    }
    init(path: String, onChange: @escaping () -> Void) { self.path = path; self.onChange = onChange }
    func start() {
        stop(); active = true; signature = currentSignature(); armFile(); armParent()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reconcile() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        active = false; timer?.invalidate(); timer = nil
        fileSource?.cancel(); fileSource = nil; parentSource?.cancel(); parentSource = nil
    }
    deinit { stop() }
    private func currentSignature() -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return Signature(inode: inode.uint64Value, size: size.uint64Value, modified: date.timeIntervalSince1970)
    }
    private func source(_ watched: String, handler: @escaping (DispatchSourceFileSystemObject) -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(watched, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link], queue: .main)
        source.setEventHandler { [weak source] in if let source { handler(source) } }
        source.setCancelHandler { close(fd) }; source.resume(); return source
    }
    private func armFile() {
        guard active, fileSource == nil else { return }
        fileSource = source(path) { [weak self] source in
            guard let self, self.active else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.fileSource?.cancel(); self.fileSource = nil
            }
            self.signature = self.currentSignature(); self.onChange(); self.armFile()
        }
    }
    private func armParent() {
        guard active, parentSource == nil else { return }
        parentSource = source((path as NSString).deletingLastPathComponent) { [weak self] source in
            guard let self, self.active else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) { self.parentSource?.cancel(); self.parentSource = nil }
            self.reconcile()
        }
    }
    private func reconcile() {
        guard active else { return }
        let next = currentSignature()
        if next != signature {
            let replaced = next?.inode != signature?.inode
            signature = next
            if replaced { fileSource?.cancel(); fileSource = nil }
            onChange()
        }
        armFile(); armParent()
    }
}
