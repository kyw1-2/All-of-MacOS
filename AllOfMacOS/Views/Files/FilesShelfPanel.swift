import AppKit
import QuickLook
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The Drop Shelf's transient state: selection, drop highlight, progress and
/// the last message (with Undo when the action can be undone).
@MainActor
final class FilesShelfViewModel: ObservableObject {
    struct Message: Equatable {
        var text: String
        var tone: AOMTone
        var undoTitle: String?
        var id = UUID()
    }

    @Published var selection: Set<UUID> = []
    /// 7.12 (NEW-1): each shelf keeps its own selection while another is shown.
    var selections: [UUID: Set<UUID>] = [:]
    /// The shelf `selection` belongs to.
    var selectionShelf: UUID?
    @Published var isTargeted = false
    @Published var progress: String?
    @Published var message: Message?
    @Published var quickLookURL: URL?
    var quickLookURLs: [URL] = []
    var undo: (() -> Void)?
    var cancelProgress: (() -> Void)?
    private var messageReset: DispatchWorkItem?

    func show(_ text: String, tone: AOMTone = .success, undoTitle: String? = nil, undo: (() -> Void)? = nil) {
        messageReset?.cancel()
        let message = Message(text: text, tone: tone, undoTitle: undo == nil ? nil : (undoTitle ?? "Undo"))
        self.message = message
        self.undo = undo
        let seconds = undo != nil ? AOMMotion.undoToastSeconds : (tone == .danger ? 8 : AOMMotion.toastSeconds)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if self?.message?.id == message.id { self?.message = nil; self?.undo = nil }
            }
        }
        messageReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// The Drop Shelf: a floating panel that holds files on their way somewhere
/// else. Shaking the pointer during a file drag, the hotkey, the status menu
/// and Workspace open it. It never takes focus when it appears; clicking an
/// item makes it key for Space (Quick Look), Delete and ⌘A.
@MainActor
final class FilesShelfPanelController: NSObject {
    static let shared = FilesShelfPanelController()

    static let width: CGFloat = 320
    /// 7.14 (Codex 7.13): every drop still receiving promised files. The
    /// status row sums them, so one drop timing out or finishing doesn't
    /// clear "Receiving…" while another is still coming in.
    private var receiving: [FilesReceiveBatch] = []

    fileprivate func showReceiveProgress() {
        receiving.removeAll { $0.gaveUp || $0.finished >= $0.total }
        guard !receiving.isEmpty else { model.progress = nil; return }
        let total = receiving.reduce(0) { $0 + $1.total }
        let finished = receiving.reduce(0) { $0 + $1.finished }
        model.progress = total == 1 ? "Receiving…" : "Receiving \(finished) of \(total)…"
    }
    /// One queue for promised files, a few at a time.
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    let store: FilesShelfStore
    let model = FilesShelfViewModel()
    private var panel: FilesShelfWindow?
    /// 7.13 (GPT F17): each show or hide; a fade-out that finishes after the
    /// shelf was shown again must not take it off screen.
    private var presentation = 0
    private var compressHandle: FilesProcess.Handle?
    private var storeChanges: AnyCancellable?
    private var modelChanges: AnyCancellable?

    init(store: FilesShelfStore? = nil) {
        let store = store ?? .shared
        self.store = store
        super.init()
        storeChanges = store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.followActiveShelf()
                    let ids = Set(items.map(\.id))
                    if !self.model.selection.isSubset(of: ids) { self.model.selection.formIntersection(ids) }
                    self.resize()
                    FilesModule.publishStatus()
                }
            }
        // The message row takes room only while it shows something.
        modelChanges = model.$message.map { $0 != nil }
            .combineLatest(model.$progress.map { $0 != nil })
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resize() } }
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// 7.12 (preview only): three shelves, the pinned one with a missing file.
    static func previewSample() {
        guard PresetManager.isUIPreview else { return }
        let store = FilesShelfStore.shared
        let folder = FilesStorage.directory.appendingPathComponent("Sample", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String) -> URL {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data("AOM".utf8)) }
            return url
        }
        let talk = store.createShelf(named: "발표 준비")
        store.add([file("발표 슬라이드 v3.key"), file("데모 영상.mov")], to: talk.id)
        let submit = store.createShelf(named: "제출 자료")
        let missing = folder.appendingPathComponent("견적.pdf")
        store.add([file("제안서 최종.pdf"), file("첨부1 예산표.xlsx"), missing, file("회사 소개서.pdf")], to: submit.id)
        store.togglePinned(submit.id)
        shared.show(shelf: submit.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { shared.compress() }
    }

    /// The active shelf changed: its own selection comes back (7.12, NEW-1).
    private func followActiveShelf() {
        let active = store.activeID
        guard model.selectionShelf != active else { return }
        if let previous = model.selectionShelf { model.selections[previous] = model.selection }
        model.selectionShelf = active
        model.selection = model.selections[active] ?? []
        model.quickLookURL = nil
    }

    /// Opens a shelf by id (the launcher's shelf rows).
    func show(shelf id: UUID) {
        store.activate(id)
        followActiveShelf()
        show()
    }

    func switchTo(_ id: UUID) {
        guard id != store.activeID else { return }
        store.activate(id)
        followActiveShelf()
    }

    func createShelf(named name: String) {
        if let previous = model.selectionShelf { model.selections[previous] = model.selection }
        let shelf = store.createShelf(named: name)
        model.selectionShelf = shelf.id
        model.selection = []
        model.show("Made the shelf “\(shelf.name)”")
    }

    /// Deletes a shelf. Received files only it names go to the Trash;
    /// files of yours stay where they are. Undo brings both back.
    func deleteShelf(_ id: UUID) {
        guard let shelf = store.shelf(id) else { return }
        let received = Self.receivedToTrash(store.receivedOnlyIn(id), receivedFolder: FilesStorage.receivedFolder)
        guard let entry = store.deleteShelf(id) else {
            model.show("The last shelf can't be deleted — Clear Shelf empties it", tone: .neutral)
            return
        }
        model.selections[id] = nil
        followActiveShelf()
        let text = received.isEmpty ? "Deleted “\(shelf.name)”"
            : "Deleted “\(shelf.name)” and moved \(Self.count(received.count)) AOM received to the Trash"
        guard !received.isEmpty else {
            model.show(text, undoTitle: "Undo") { [weak self] in self?.store.restoreShelf(entry); self?.followActiveShelf() }
            return
        }
        Task {
            let trash = await FilesFileActions.trash(received)
            // 7.13 (GPT F18): the message counts what really went to the Trash.
            let shown = Self.trashSummary(trash.failures, moved: trash.trashed.count,
                                          success: "Deleted “\(shelf.name)” and moved \(Self.count(trash.trashed.count)) AOM received to the Trash")
            model.show(shown.text, tone: shown.tone, undoTitle: "Undo") { [weak self] in
                Task {
                    let back = await FilesFileActions.moveBack(trash.trashed)
                    guard let self else { return }
                    // 7.14 (Codex 7.13 S1): a file that couldn't go back (its old
                    // place is taken) is pointed at where it really is — the
                    // Trash — as Remove's Undo does; a row whose file is gone is dropped.
                    var restored = entry
                    let kept = Self.itemsToRestore(entry.shelf.items.enumerated().map { ($0.offset, $0.element) },
                                                   trashed: trash.trashed, putBack: back)
                    restored.shelf.items = kept.map(\.item)
                    self.store.restoreShelf(restored)
                    self.followActiveShelf()
                    let dropped = entry.shelf.items.count - kept.count
                    if let failure = back.failures.first {
                        let others = back.failures.count > 1 ? " (and \(back.failures.count - 1) more)" : ""
                        self.model.show("Restored “\(entry.shelf.name)”. “\(failure.url.lastPathComponent)”\(others) stayed in the Trash because \(failure.reason)"
                                        + (dropped > 0 ? "; \(Self.count(dropped)) no longer exist" : ""), tone: .danger)
                    } else if dropped > 0 {
                        self.model.show("Restored “\(entry.shelf.name)” without \(Self.count(dropped)) that no longer exist", tone: .neutral)
                    }
                }
            }
        }
    }

    /// "Also Add to": the selection (or the whole shelf) on another shelf too.
    func addSelection(to target: UUID) {
        let ids = model.selection.isEmpty ? Set(store.items.map(\.id)) : model.selection
        let added = store.copy(ids, to: target)
        guard let name = store.shelf(target)?.name, !added.isEmpty else { return }
        model.show("Added \(Self.count(added.count)) to “\(name)”")
    }

    /// Opens the shelf beside `point` (screen coordinates), or beside the
    /// pointer. It appears without taking focus.
    func show(at point: NSPoint? = nil) {
        // 7.0: one floating surface at a time.
        AOMOverlayCoordinator.shared.present(.dropShelf, dismiss: { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return }
            panel.allowsKey = false
            panel.orderOut(nil)
        }) { _ in }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: Self.width, height: currentHeight)
        let origin = point ?? NSEvent.mouseLocation
        let frame = FilesScreenGeometry.frame(at: origin, size: size, visibleFrames: NSScreen.screens.map(\.visibleFrame))
        panel.setFrame(frame, display: true)
        presentation &+= 1
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AOMMotion.systemReduceMotion ? 0.08 : 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
            // Shown again while it was fading out: back to full opacity.
            if panel.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = AOMMotion.systemReduceMotion ? 0.04 : 0.1
                    panel.animator().alphaValue = 1
                }
            }
        }
        NSAccessibility.post(element: panel, notification: .created)
    }

    func toggle() { isVisible ? hide() : show() }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.allowsKey = false
        presentation &+= 1
        let ticket = presentation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AOMMotion.systemReduceMotion ? 0.06 : 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard FilesShelfPanelController.shared.presentation == ticket else { return }
                panel.orderOut(nil)
            }
        })
    }

    /// The person clicked into the shelf: it becomes key (without
    /// activating AOM) so its keys work.
    func takeFocus() {
        guard let panel else { return }
        panel.allowsKey = true
        panel.makeKey()
    }

    static func height(count: Int, showsMessage: Bool) -> CGFloat {
        let list = count == 0 ? 132 : CGFloat(min(max(count, 2), 6)) * FilesShelfView.rowHeight + AOMSpace.x2
        return 48 + list + (showsMessage ? 40 : 0) + 52
    }

    private var currentHeight: CGFloat {
        Self.height(count: store.items.count, showsMessage: model.message != nil || model.progress != nil)
    }

    private func resize() {
        guard let panel else { return }
        var frame = panel.frame
        let height = currentHeight
        guard abs(frame.height - height) > 0.5 else { return }
        // The top edge stays where it is; the shelf grows or shrinks downward.
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel() -> FilesShelfWindow {
        let panel = FilesShelfWindow(size: CGSize(width: Self.width, height: currentHeight), label: "Drop Shelf")
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.hide() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let container = FilesShelfDropView()
        container.onTargeted = { [weak self] in self?.model.isTargeted = $0 }
        container.onDrop = { [weak self] urls, promises in self?.receive(urls: urls, promises: promises) ?? false }
        let hosting = FilesHostingView(rootView: FilesShelfView(controller: self, store: store, model: model))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        return panel
    }

    // MARK: Drops

    /// Files keep their place: the shelf stores where they are. Promised
    /// files (an image from Safari) are written into the module's Received
    /// folder first.
    private func receive(urls: [URL], promises: [NSFilePromiseReceiver]) -> Bool {
        // 7.12 (NEW-1): files that arrive late belong to the shelf they were dropped on.
        let shelfID = store.activeID
        let added = store.add(urls)
        if !added.isEmpty { model.selection = Set(added.map(\.id)) }
        guard !promises.isEmpty else { return !added.isEmpty }
        let destination = FilesStorage.receivedFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            model.show("Couldn't receive the files because \(FilesFileActions.reason(error))", tone: .danger)
            return !added.isEmpty
        }
        // 7.3: the first promise to arrive cleared "Receiving…" and selected
        // only its file. The row now counts them in, and when the last one is
        // done every file of the drop is selected and failures are summed up.
        let total = promises.reduce(0) { $0 + max(1, $1.fileNames.count) }
        let batch = FilesReceiveBatch(total: total, alreadyAdded: added.map(\.id))
        receiving.append(batch)
        showReceiveProgress()
        let queue = Self.promiseQueue
        // 7.13 (Gemini 7.12.1 #13): an app that never delivers can't leave
        // "Receiving…" up for good (it blocks Compress and the auto-hide).
        // Files that still come later are added quietly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, batch.finished < batch.total, !batch.gaveUp else { return }
                batch.gaveUp = true
                self.showReceiveProgress()
                self.model.show("Received \(batch.received.count) of \(batch.total) — the app that sent the rest hasn't delivered them", tone: .danger)
            }
        }
        for promise in promises {
            promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let controller = FilesShelfPanelController.shared
                        if let error {
                            batch.failures.append(.init(url: url, reason: FilesFileActions.reason(error)))
                        } else {
                            batch.received.append(contentsOf: controller.store.add([url], received: true, to: shelfID).map(\.id))
                        }
                        batch.finished += 1
                        guard !batch.gaveUp else { return }
                        controller.showReceiveProgress()
                        guard batch.finished >= batch.total else { return }
                        if controller.store.activeID == shelfID {
                            controller.model.selection = Set(batch.alreadyAdded + batch.received)
                        } else {
                            controller.model.selections[shelfID] = Set(batch.alreadyAdded + batch.received)
                        }
                        if let failure = batch.failures.first {
                            let others = batch.failures.count > 1 ? " (and \(batch.failures.count - 1) more)" : ""
                            controller.model.show("Received \(batch.received.count) of \(batch.total). Couldn't receive “\(failure.url.lastPathComponent)”\(others) because \(failure.reason)", tone: .danger)
                        }
                        FilesActivityLog.shared.record("Received \(batch.received.count) of \(batch.total) promised files", tool: "Drop Shelf",
                                                       files: controller.store.items(Set(batch.received), in: shelfID).map(\.url), failures: batch.failures)
                    }
                }
            }
        }
        return true
    }

    // MARK: Actions (on the selection, or every item when nothing is selected)

    /// 7.12 (Codex FIX-2): what an action asked for, missing files included,
    /// taken when the action starts. The selection, or every item when
    /// nothing is selected.
    var requestedItems: [FilesShelfItem] {
        let selected = store.items(model.selection)
        return selected.isEmpty ? store.items : selected
    }

    /// The requested items whose files are still there.
    var targetItems: [FilesShelfItem] { requestedItems.filter(\.exists) }

    var targetURLs: [URL] { targetItems.map(\.url) }

    func airDrop() {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        if !FilesFileActions.airDrop(urls) { model.show("Couldn't send with AirDrop because it isn't available", tone: .danger) }
    }

    func copyPaths() {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        FilesFileActions.copyPaths(urls)
        model.show(urls.count == 1 ? "Copied the path" : "Copied \(urls.count) paths")
    }

    func reveal() { FilesFileActions.reveal(targetURLs) }

    func quickLook() {
        let urls = targetURLs
        guard let first = urls.first else { return }
        model.quickLookURLs = urls
        model.quickLookURL = model.quickLookURL == nil ? first : nil
    }

    func moveTo() { transfer(move: true) }
    func copyTo() { transfer(move: false) }

    private func transfer(move: Bool) {
        let items = requestedItems
        guard !items.isEmpty else { return }
        guard items.contains(where: \.exists) else {
            model.show(Self.allMissingMessage(items, verb: move ? "move" : "copy"), tone: .danger)
            return
        }
        guard !PresetManager.isUIPreview else { return }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = move ? "Move" : "Copy"
        open.message = move ? "Move \(Self.count(items.count)) to:" : "Copy \(Self.count(items.count)) to:"
        AOMOverlayActivation.activateForOverlay()
        open.begin { [weak self] response in
            guard response == .OK, let folder = open.url else { return }
            MainActor.assumeIsolated { self?.runTransfer(items, to: folder, move: move) }
        }
    }

    /// One shelf item's move, kept for Undo by the item's id (a path can
    /// name a different shelf item by then).
    struct ShelfMove: Equatable {
        var itemID: UUID
        var move: FilesTransfer.Move
    }

    func runTransfer(_ items: [FilesShelfItem], to folder: URL, move: Bool) {
        model.progress = move ? "Moving…" : "Copying…"
        let shelfID = store.activeID
        Task {
            let result = await FilesFileActions.transfer(items.map(\.url), to: folder, move: move)
            model.progress = nil
            let folderName = FileManager.default.displayName(atPath: folder.path)
            guard move else {
                let copies = store.add(result.done.map(\.to), to: shelfID)
                if store.activeID == shelfID { model.selection = Set(copies.map(\.id)) }
                let (text, tone) = Self.transferMessage(result, move: false, total: items.count, folderName: folderName)
                model.show(text, tone: tone)
                FilesActivityLog.shared.record(text, tool: "Drop Shelf", files: result.done.map(\.to), failures: result.failures)
                return
            }
            var moves: [ShelfMove] = []
            var relocations: [(UUID, URL)] = []
            // 7.3: items looked up in a map and saved once (7.2.3 searched and
            // saved shelf.json once per file).
            let byPath = Dictionary(items.map { (FilesPath.key($0.path), $0) }, uniquingKeysWith: { first, _ in first })
            for done in result.done {
                guard let item = byPath[FilesPath.key(done.from.path)] else { continue }
                relocations.append((item.id, done.to))
                if done.from != done.to { moves.append(ShelfMove(itemID: item.id, move: done)) }
            }
            store.relocate(relocations)
            let (text, tone) = Self.transferMessage(result, move: true, total: items.count, folderName: folderName)
            FilesActivityLog.shared.record(text, tool: "Drop Shelf", files: result.done.map(\.to), failures: result.failures,
                                           undo: moves.isEmpty ? nil : { [weak self] in self?.undoMove(moves) })
            // 7.2.3 (audit B10): a failure no longer drops the Undo of the
            // files that did move.
            guard !moves.isEmpty || result.failures.isEmpty else {
                model.show(text, tone: tone)
                return
            }
            model.show(text, tone: tone, undoTitle: "Undo") {
                self.undoMove(moves)
            }
        }
    }

    /// "Moved 3 items to Desktop", or which file failed and why, after how
    /// many of the others went.
    static func transferMessage(_ result: FilesTransfer, move: Bool, total: Int, folderName: String) -> (text: String, tone: AOMTone) {
        let verb = move ? "move" : "copy"
        let past = move ? "Moved" : "Copied"
        guard let failure = result.failures.first else {
            return ("\(past) \(count(result.done.count)) to \(folderName)", .success)
        }
        let others = result.failures.count > 1 ? " (and \(result.failures.count - 1) more)" : ""
        let why = "Couldn't \(verb) “\(failure.url.lastPathComponent)”\(others) because \(failure.reason)"
        guard !result.done.isEmpty else { return (why, .danger) }
        return ("\(past) \(result.done.count) of \(count(total)) to \(folderName). \(why)", .danger)
    }

    /// 7.12 (FIX-2): every requested file is gone, so nothing is made.
    static func allMissingMessage(_ items: [FilesShelfItem], verb: String) -> String {
        guard items.count > 1 else { return "Couldn't \(verb) “\(items.first?.name ?? "")” because it's no longer where the shelf saw it" }
        return "Couldn't \(verb) — none of the \(items.count) files are where the shelf saw them"
    }

    /// 7.12 (FIX-2): "“견적.pdf” is missing — 1 of 4" (it fits the 320 pt panel).
    static func missingMessage(_ missing: [FilesShelfItem], of total: Int) -> String {
        guard let first = missing.first else { return "" }
        let others = missing.count > 1 ? " +\(missing.count - 1)" : ""
        return "“\(first.name)”\(others) missing — \(missing.count) of \(total)"
    }

    private func undoMove(_ moves: [ShelfMove]) {
        Task {
            let result = await FilesFileActions.moveBack(moves.map(\.move))
            let byPath = Dictionary(moves.map { (FilesPath.key($0.move.to.path), $0) }, uniquingKeysWith: { first, _ in first })
            store.relocate(result.done.compactMap { done in byPath[FilesPath.key(done.from.path)].map { ($0.itemID, done.to) } })
            FilesActivityLog.shared.record("Moved \(Self.count(result.done.count)) back", tool: "Drop Shelf",
                                           files: result.done.map(\.to), failures: result.failures)
            if let failure = result.failures.first {
                // The shelf item keeps naming the file where it really is.
                let entry = moves.first { FilesPath.key($0.move.to.path) == FilesPath.key(failure.url.path) }
                let stillThere = entry.map { Self.isStill($0.move) } ?? false
                let still = stillThere ? ". It's still in \(FileManager.default.displayName(atPath: failure.url.deletingLastPathComponent().path))" : ""
                let others = result.failures.count > 1 ? " (and \(result.failures.count - 1) more)" : ""
                let moved = result.done.isEmpty ? "" : "Moved \(Self.count(result.done.count)) back. "
                model.show("\(moved)Couldn't move “\(failure.url.lastPathComponent)”\(others) back because \(failure.reason)\(still)", tone: .danger)
            } else {
                model.show("Moved \(Self.count(result.done.count)) back")
            }
        }
    }

    func compress() {
        let requested = requestedItems
        guard !requested.isEmpty, compressHandle == nil else { return }
        let present = requested.filter(\.exists)
        guard !present.isEmpty else {
            model.show(Self.allMissingMessage(requested, verb: "compress"), tone: .danger)
            return
        }
        let missing = requested.filter { !$0.exists }
        guard missing.isEmpty else {
            // Asked first: the ZIP would silently hold fewer files than chosen.
            model.show(Self.missingMessage(missing, of: requested.count), tone: .danger,
                       undoTitle: "Zip the Other \(present.count)") { [weak self] in
                self?.compress(present.map(\.url))
            }
            return
        }
        compress(present.map(\.url))
    }

    func compress(_ urls: [URL]) {
        guard !urls.isEmpty, compressHandle == nil else { return }
        let shelfID = store.activeID
        let handle = FilesProcess.Handle()
        compressHandle = handle
        model.progress = "Compressing \(Self.count(urls.count))…"
        model.cancelProgress = { handle.cancel() }
        Task {
            defer {
                compressHandle = nil
                model.progress = nil
                model.cancelProgress = nil
            }
            do {
                let archive = try await FilesFileActions.compress(urls, handle: handle)
                let added = store.add([archive], to: shelfID)
                if store.activeID == shelfID { model.selection = Set(added.map(\.id)) }
                model.show("Compressed \(Self.count(urls.count)) into \(archive.lastPathComponent)")
            } catch {
                if handle.isCancelled { model.show("Compressing stopped", tone: .neutral); return }
                model.show("Couldn't compress because \(error.localizedDescription)", tone: .danger)
            }
        }
    }

    /// Takes items off the shelf (their files stay where they are). Files the
    /// shelf received itself go to the Trash with them; Undo brings both back.
    func remove(_ ids: Set<UUID>? = nil) {
        let targets = ids ?? (model.selection.isEmpty ? Set(store.items.map(\.id)) : model.selection)
        guard !targets.isEmpty else { return }
        let removed = store.remove(targets)
        model.selection.subtract(targets)
        // 7.3 (Codex probe): only a received file still in the Received
        // folder goes to the Trash. One moved to a folder of yours — or a
        // different file that took its name there — stays where it is.
        // 7.12 (NEW-1): a received file another shelf still names stays.
        let shelfID = store.activeID
        let received = Self.receivedToTrash(removed.map(\.item).filter { !store.isReferenced($0.path, outside: shelfID) },
                                            receivedFolder: FilesStorage.receivedFolder)
        let text = removed.count == store.items.count + removed.count && removed.count > 1 ? "Cleared the shelf" : "Removed \(Self.count(removed.count))"
        guard !received.isEmpty else {
            model.show(text, undoTitle: "Undo") { [weak self] in self?.store.restore(removed, to: shelfID) }
            return
        }
        Task {
            let trash = await FilesFileActions.trash(received)
            // 7.13 (Gemini 7.12.1 #14): a file the Trash refused is named, not hidden.
            let shown = Self.trashSummary(trash.failures, moved: trash.trashed.count, success: text)
            model.show(shown.text, tone: shown.tone, undoTitle: "Undo") { [weak self] in
                guard let self else { return }
                Task {
                    let back = await FilesFileActions.moveBack(trash.trashed)
                    self.store.restore(Self.itemsToRestore(removed, trashed: trash.trashed, putBack: back), to: shelfID)
                    if let failure = back.failures.first {
                        let others = back.failures.count > 1 ? " (and \(back.failures.count - 1) more)" : ""
                        self.model.show("Couldn't put “\(failure.url.lastPathComponent)”\(others) back because \(failure.reason)", tone: .danger)
                    }
                }
            }
        }
    }

    /// Pure: the message after received files went to the Trash.
    static func trashSummary(_ failures: [FilesTransfer.Failure], moved: Int,
                                         success: String) -> (text: String, tone: AOMTone) {
        guard let failure = failures.first else { return (success, .success) }
        let others = failures.count > 1 ? " (and \(failures.count - 1) more)" : ""
        return ("\(success.components(separatedBy: " and moved").first ?? success) — moved \(count(moved)) to the Trash; couldn't move “\(failure.url.lastPathComponent)”\(others) because \(failure.reason)",
                .danger)
    }

    /// Pure: the received items whose files are still inside AOM's Received folder.
    nonisolated static func receivedToTrash(_ items: [FilesShelfItem], receivedFolder: URL) -> [URL] {
        items.filter(\.received).map(\.url).filter { url in
            FileManager.default.fileExists(atPath: url.path) && FolderRulesSafety.isInside(url, receivedFolder)
        }
    }

    /// The move is still undone-able: its file is at `to` and is the one
    /// that was moved there.
    nonisolated static func isStill(_ move: FilesTransfer.Move) -> Bool {
        guard FolderRulesSafety.exists(move.to.path) else { return false }
        return move.identity == nil || FolderRulesSafety.identity(move.to) == move.identity
    }

    /// What Undo of a removal puts back on the shelf (7.2.3, audit B10). An
    /// item whose received file came back out of the Trash returns as it
    /// was; one whose file couldn't (its old place was taken) names the
    /// file in the Trash instead of whatever took its name; one whose file
    /// is gone stays off.
    nonisolated static func itemsToRestore(_ removed: [(index: Int, item: FilesShelfItem)], trashed: [FilesTransfer.Move],
                                           putBack: FilesTransfer) -> [(index: Int, item: FilesShelfItem)] {
        removed.compactMap { entry in
            let key = FilesPath.key(entry.item.path)
            guard let move = trashed.first(where: { FilesPath.key($0.from.path) == key }) else { return entry }
            if putBack.done.contains(where: { FilesPath.key($0.from.path) == FilesPath.key(move.to.path) }) { return entry }
            guard isStill(move) else { return nil }
            var item = entry.item
            item.path = FilesPath.key(move.to.path)
            return (entry.index, item)
        }
    }

    func clear() { remove(Set(store.items.map(\.id))) }

    func selectAll() { model.selection = Set(store.items.map(\.id)) }

    /// Click, ⌘-click (toggle) and ⇧-click (range) like the Finder.
    func select(_ item: FilesShelfItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
        } else if modifiers.contains(.shift), let anchor = store.items.firstIndex(where: { model.selection.contains($0.id) }),
                  let index = store.items.firstIndex(of: item) {
            let range = min(anchor, index)...max(anchor, index)
            model.selection = Set(store.items[range].map(\.id))
        } else {
            model.selection = [item.id]
        }
        takeFocus()
    }

    /// The URLs a drag from `item` carries: the selection when the item is
    /// part of it, else the item alone.
    /// 7.3 (Yoink's "hide after dragging out", off unless chosen in Files
    /// settings): the shelf goes once its files were dropped somewhere,
    /// never while it is receiving, moving or undoing.
    func dragEnded(delivered: Bool) {
        guard delivered, FilesSettings.shared.hideShelfAfterDragOut, model.progress == nil else { return }
        hide()
    }

    func dragURLs(from item: FilesShelfItem) -> [URL] {
        if model.selection.contains(item.id), model.selection.count > 1 {
            return store.items(model.selection).filter(\.exists).map(\.url)
        }
        return item.exists ? [item.url] : []
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 49 where flags.isEmpty: quickLook(); return true                      // Space
        case 51, 117: remove(); return true                                       // Delete, Forward Delete
        case 0 where flags == .command: selectAll(); return true                 // ⌘A
        case 8 where flags == .command: FilesFileActions.copyFiles(targetURLs); return true // ⌘C
        case 6 where flags == .command:                                           // ⌘Z
            guard model.message?.undoTitle == "Undo", let undo = model.undo else { return true }
            // Taken before it runs, as the button does: one ⌘Z, one undo.
            model.undo = nil; model.message = nil
            undo(); return true
        case 13 where flags == .command: hide(); return true                     // ⌘W
        default: return false
        }
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
}

/// The shelf's window: routes its keys to the controller.
final class FilesShelfWindow: FilesFloatingPanel {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// The shelf's drop target: Finder files and promised files (an image or a
/// PDF dragged out of Safari or Mail). Drops are taken as copies, so the
/// source app never removes anything.
final class FilesShelfDropView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onDrop: (([URL], [NSFilePromiseReceiver]) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError("FilesShelfDropView is created in code") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { accepts(sender) ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        // Drags that start on the shelf itself don't come back onto it.
        if let source = sender.draggingSource as? NSView, source.window === window { return false }
        // 7.3 (Codex 7.2.3 report): one file URL in the drag made 7.2.3 skip
        // every promise in it, so a mixed drop (Finder files and an image
        // from Safari) lost the promised ones. Each dragged item is read on
        // its own — as a file URL when it has one, else as a promise — so an
        // item that offers both is taken once.
        var urls: [URL] = []
        var promises: [NSFilePromiseReceiver] = []
        sender.enumerateDraggingItems(options: [], for: nil, classes: [NSURL.self, NSFilePromiseReceiver.self],
                                      searchOptions: [.urlReadingFileURLsOnly: true]) { item, _, _ in
            if let url = item.item as? URL { urls.append(url) }
            else if let promise = item.item as? NSFilePromiseReceiver { promises.append(promise) }
        }
        return onDrop?(urls, promises) ?? false
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        if let source = sender.draggingSource as? NSView, source.window === window { return false }
        let types = sender.draggingPasteboard.types ?? []
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)
        return types.contains(.fileURL) || types.contains { promiseTypes.contains($0.rawValue) }
    }
}

/// The shelf's content.
struct FilesShelfView: View {
    static let rowHeight: CGFloat = 44
    let controller: FilesShelfPanelController
    @ObservedObject var store: FilesShelfStore
    @ObservedObject var model: FilesShelfViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            AOMDivider()
            // 7.3: a shelf.json that couldn't be read is kept, never replaced.
            if let problem = store.problem {
                AOMNotice(problem.blocksSaving ? .error : .warning, problem.title, detail: problem.detail) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([problem.file]) }
                }
                .padding(AOMSpace.x2)
            }
            content
            if let progress = model.progress { progressRow(progress) }
            else if let message = model.message { messageRow(message) }
            AOMDivider()
            actions
        }
        .frame(width: FilesShelfPanelController.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .aomDropTarget(model.isTargeted, radius: AOMRadius.panel)
        .aomFloatingSurface(.panel)
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop Shelf, \(FilesShelfPanelController.count(store.items.count))")
    }

    private var header: some View {
        HStack(spacing: AOMSpace.x2) {
            ZStack {
                if store.items.isEmpty {
                    Image(systemName: "tray.and.arrow.down")
                        .font(AOMFont.title)
                        .foregroundStyle(AOMColor.textSecondary)
                } else {
                    ForEach(Array(store.items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                        Image(nsImage: FilesIcons.icon(item.path))
                            .resizable()
                            .frame(width: 28, height: 28)
                            .offset(x: CGFloat(index) * 4, y: CGFloat(-index) * 3)
                    }
                }
            }
            .frame(width: 40, height: 36)
            .background {
                if !store.items.isEmpty {
                    FilesFileDragSource(urls: { store.items.filter(\.exists).map(\.url) },
                                        onEnd: { controller.dragEnded(delivered: $0) })
                }
            }
            .help(store.items.isEmpty ? "Drop files on the shelf" : "Drag all items out")
            .accessibilityLabel(store.items.isEmpty ? "Empty shelf" : "Drag all \(FilesShelfPanelController.count(store.items.count))")
            VStack(alignment: .leading, spacing: 0) {
                shelfMenu
                Text(subtitle).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x1)
            AOMIconButton("xmark", label: "Close Drop Shelf") { controller.hide() }
        }
        .padding(.leading, AOMSpace.x3)
        .padding(.trailing, AOMSpace.x2)
        .frame(height: 48)
    }

    /// 7.12 (Codex NEW-1, Dropover's shelf list): the shelf's name opens
    /// switch, New Shelf, Rename, Pin and Delete.
    private var shelfMenu: some View {
        let active = store.activeShelf
        return Menu {
            Section("Shelves") {
                ForEach(store.shelves) { shelf in
                    Button {
                        controller.switchTo(shelf.id)
                    } label: {
                        let mark = shelf.id == active.id ? "checkmark" : (shelf.pinned ? "pin" : "tray")
                        Label("\(shelf.name) · \(shelf.items.count)", systemImage: mark)
                    }
                }
            }
            Divider()
            Button("New Shelf…") { FilesShelfNaming.ask(title: "New Shelf", prompt: "Name the shelf", value: "") { controller.createShelf(named: $0) } }
            Button("Rename “\(active.name)”…") {
                FilesShelfNaming.ask(title: "Rename Shelf", prompt: "Name the shelf", value: active.name) { store.rename(active.id, to: $0) }
            }
            Button(active.pinned ? "Unpin “\(active.name)”" : "Pin “\(active.name)”") { store.togglePinned(active.id) }
            if store.shelves.count > 1 {
                Menu("Also Add \(model.selection.isEmpty ? "All" : "Selected") To") {
                    ForEach(store.shelves.filter { $0.id != active.id }) { shelf in
                        Button(shelf.name) { controller.addSelection(to: shelf.id) }
                    }
                }
                .disabled(store.items.isEmpty)
                Divider()
                Button("Delete “\(active.name)”…") { controller.deleteShelf(active.id) }
            }
        } label: {
            // One Text with inline symbols: a borderless menu's label draws a
            // single image, so a separate chevron after a pin was dropped.
            let name = store.shelves.count > 1 || active.name != FilesShelfLibrary.defaultName ? active.name : "Drop Shelf"
            (active.pinned ? Text("\(Image(systemName: "pin.fill")) ").font(AOMFont.caption).foregroundColor(AOMColor.textSecondary) : Text(""))
                + Text(name).font(AOMFont.headline).foregroundColor(AOMColor.text)
                + Text(" \(Image(systemName: "chevron.down"))").font(.system(size: 10, weight: .semibold)).foregroundColor(AOMColor.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch, make, rename, pin or delete shelves")
        .accessibilityLabel("Shelf: \(active.name)")
    }

    private var subtitle: String {
        if store.items.isEmpty { return "Drop files here" }
        if !model.selection.isEmpty { return "\(model.selection.count) of \(store.items.count) selected" }
        return "\(FilesShelfPanelController.count(store.items.count)) · drag the stack to take all"
    }

    @ViewBuilder private var content: some View {
        if store.items.isEmpty {
            VStack(spacing: AOMSpace.x2) {
                Image(systemName: "arrow.down.doc")
                    .font(AOMFont.display)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.isTargeted ? AOMColor.accent : AOMColor.textTertiary)
                Text("Drag files here to hold them while you switch apps or desktops.")
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AOMSpace.x4)
            .frame(maxWidth: .infinity, minHeight: 132)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { item in row(item) }
                }
                .padding(.vertical, AOMSpace.x1)
                .padding(.horizontal, AOMSpace.x1)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ item: FilesShelfItem) -> some View {
        let selected = model.selection.contains(item.id)
        let exists = item.exists
        return HStack(spacing: AOMSpace.x2) {
            Image(nsImage: FilesIcons.icon(item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .opacity(exists ? 1 : 0.4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(AOMFont.body)
                    .foregroundStyle(selected ? Color.white : AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(exists ? FilesShelfView.detail(item) : "Not found")
                    .font(AOMFont.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : (exists ? AOMColor.textSecondary : AOMColor.warningText))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.x2)
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                .fill(selected ? AOMColor.selection : .clear)
        }
        .aomHoverHighlight(radius: AOMRadius.control, enabled: !selected)
        .contentShape(Rectangle())
        .background { FilesFileDragSource(urls: { controller.dragURLs(from: item) }, onEnd: { controller.dragEnded(delivered: $0) }) }
        .onTapGesture {
            // One tap handler: a second click of a double-click opens, so a
            // single click selects at once instead of waiting.
            if NSApp.currentEvent?.clickCount == 2 { FilesFileActions.open([item.url]) }
            else { controller.select(item, modifiers: NSEvent.modifierFlags) }
        }
        .help(item.path)
        .contextMenu {
            Button("Open") { FilesFileActions.open([item.url]) }.disabled(!exists)
            Button("Quick Look") { model.selection = [item.id]; controller.quickLook() }.disabled(!exists)
            Button("Show in Finder") { FilesFileActions.reveal([item.url]) }.disabled(!exists)
            Button("Copy Path") { FilesFileActions.copyPaths([item.url]) }
            if item.url.pathExtension.lowercased() == "zip" {
                Button("Extract Files…") { AOMFileToolsLauncher.openZip(item.url) }.disabled(!exists)
            }
            Divider()
            Button("Remove from Shelf") { controller.remove([item.id]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(exists ? (selected ? "Selected" : "") : "Not found")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Quick Look") { model.selection = [item.id]; controller.quickLook() }
        .accessibilityAction(named: "Remove from Shelf") { controller.remove([item.id]) }
    }

    static func detail(_ item: FilesShelfItem) -> String {
        let folder = FilesPath.abbreviated((item.path as NSString).deletingLastPathComponent)
        if item.received { return "Received \(AOMRelativeTime.string(item.added).lowercased())" }
        return folder
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: AOMSpace.x2) {
            ProgressView().controlSize(.small)
            Text(text).font(AOMFont.callout).foregroundStyle(AOMColor.text).lineLimit(1)
            Spacer(minLength: 0)
            if let cancel = model.cancelProgress {
                Button("Cancel", action: cancel).controlSize(.small)
            }
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(height: 40)
        .accessibilityElement(children: .combine)
    }

    private func messageRow(_ message: FilesShelfViewModel.Message) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: message.tone.symbol)
                .foregroundStyle(message.tone.color)
                .accessibilityHidden(true)
            Text(message.text)
                .font(AOMFont.callout)
                .foregroundStyle(message.tone == .danger ? AOMColor.dangerText : AOMColor.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let title = message.undoTitle {
                Button(title) {
                    model.undo?()
                    model.message = nil
                    model.undo = nil
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        let empty = store.items.isEmpty
        let urls = controller.targetURLs
        return HStack(spacing: AOMSpace.x1) {
            AOMIconButton("dot.radiowaves.left.and.right", label: "AirDrop") { controller.airDrop() }
                .disabled(empty)
            ShareLink(items: urls) {
                Image(systemName: "square.and.arrow.up")
                    .font(AOMFont.body.weight(.medium))
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
            }
            .buttonStyle(.plain)
            .disabled(urls.isEmpty)
            .help("Share…")
            .accessibilityLabel("Share")
            AOMIconButton("doc.zipper", label: "Compress to ZIP") { controller.compress() }
                .disabled(empty || model.progress != nil)
            AOMIconButton("eye", label: "Quick Look (Space)") { controller.quickLook() }
                .disabled(empty)
            Spacer(minLength: 0)
            Menu {
                Button("Copy Paths") { controller.copyPaths() }
                Button("Move To…") { controller.moveTo() }
                Button("Copy To…") { controller.copyTo() }
                Button("Show in Finder") { controller.reveal() }
                // 7.5 (Codex F03, F07, F08): the selection (or the whole shelf) opened in a tool.
                let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
                let folders = urls.filter {
                    let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return values?.isDirectory == true && values?.isPackage != true
                }
                if pdfs.count == 2 || zips.count == 1 || folders.count == 2 {
                    Divider()
                    if pdfs.count == 2 { Button("Compare the Two PDFs") { AOMFileToolsLauncher.comparePDFs(pdfs) } }
                    if zips.count == 1 { Button("Extract Files from \(zips[0].lastPathComponent)…") { AOMFileToolsLauncher.openZip(zips[0]) } }
                    if folders.count == 2 { Button("Compare the Two Folders") { AOMFileToolsLauncher.compareFolders(folders) } }
                }
                Divider()
                Button(model.selection.isEmpty ? "Select All" : "Deselect All") {
                    if model.selection.isEmpty { controller.selectAll() } else { model.selection = [] }
                }
                Divider()
                Button("Remove from Shelf") { controller.remove() }.disabled(model.selection.isEmpty)
                Button("Clear Shelf") { controller.clear() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(AOMFont.body.weight(.medium))
                    .foregroundStyle(AOMColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(empty)
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, AOMSpace.x2)
        .frame(height: 52)
    }
}

/// The name sheet for New Shelf and Rename (an alert with a text field,
/// shown with AOM brought forward so it can take typing).
@MainActor
enum FilesShelfNaming {
    static func ask(title: String, prompt: String, value: String, done: @escaping (String) -> Void) {
        guard !PresetManager.isUIPreview else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        field.placeholderString = "제출 자료"
        alert.accessoryView = field
        alert.addButton(withTitle: title == "New Shelf" ? "Make" : "Rename")
        alert.addButton(withTitle: "Cancel")
        AOMOverlayActivation.activateForOverlay()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || title == "New Shelf" else { return }
        done(name)
    }
}

/// The promised files of one drop, counted in as they arrive (7.3).
@MainActor
final class FilesReceiveBatch {
    let total: Int
    let alreadyAdded: [UUID]
    var finished = 0
    var received: [UUID] = []
    var failures: [FilesTransfer.Failure] = []
    /// Waited too long; later files are added without touching the status row.
    var gaveUp = false

    init(total: Int, alreadyAdded: [UUID]) {
        self.total = total
        self.alreadyAdded = alreadyAdded
    }
}
