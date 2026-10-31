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
    let store: FilesShelfStore
    let model = FilesShelfViewModel()
    private var panel: FilesShelfWindow?
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

    /// Opens the shelf beside `point` (screen coordinates), or beside the
    /// pointer. It appears without taking focus.
    func show(at point: NSPoint? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: Self.width, height: currentHeight)
        let origin = point ?? NSEvent.mouseLocation
        let frame = FilesScreenGeometry.frame(at: origin, size: size, visibleFrames: NSScreen.screens.map(\.visibleFrame))
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AOMMotion.systemReduceMotion ? 0.08 : 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
        NSAccessibility.post(element: panel, notification: .created)
    }

    func toggle() { isVisible ? hide() : show() }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.allowsKey = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AOMMotion.systemReduceMotion ? 0.06 : 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
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
        model.progress = "Receiving…"
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in promises {
            promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let controller = FilesShelfPanelController.shared
                        controller.model.progress = nil
                        if let error {
                            controller.model.show("Couldn't receive a file because \(FilesFileActions.reason(error))", tone: .danger)
                        } else {
                            let items = controller.store.add([url], received: true)
                            controller.model.selection = Set(items.map(\.id))
                        }
                    }
                }
            }
        }
        return true
    }

    // MARK: Actions (on the selection, or every item when nothing is selected)

    var targetItems: [FilesShelfItem] {
        let selected = store.items(model.selection)
        return (selected.isEmpty ? store.items : selected).filter(\.exists)
    }

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
        let items = targetItems
        guard !items.isEmpty else { return }
        guard !PresetManager.isUIPreview else { return }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = move ? "Move" : "Copy"
        open.message = move ? "Move \(Self.count(items.count)) to:" : "Copy \(Self.count(items.count)) to:"
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard response == .OK, let folder = open.url else { return }
            MainActor.assumeIsolated { self?.runTransfer(items, to: folder, move: move) }
        }
    }

    private func runTransfer(_ items: [FilesShelfItem], to folder: URL, move: Bool) {
        model.progress = move ? "Moving…" : "Copying…"
        Task {
            let result = await FilesFileActions.transfer(items.map(\.url), to: folder, move: move)
            model.progress = nil
            let folderName = FileManager.default.displayName(atPath: folder.path)
            if move {
                for done in result.done {
                    if let item = items.first(where: { FilesPath.key($0.path) == FilesPath.key(done.from.path) }) {
                        store.relocate(item.id, to: done.to)
                    }
                }
            } else {
                let copies = store.add(result.done.map(\.to))
                model.selection = Set(copies.map(\.id))
            }
            if let failure = result.failures.first {
                let verb = move ? "move" : "copy"
                model.show("Couldn't \(verb) “\(failure.url.lastPathComponent)” because \(failure.reason)", tone: .danger)
                return
            }
            guard move else {
                model.show("Copied \(Self.count(result.done.count)) to \(folderName)")
                return
            }
            let moves = result.done
            model.show("Moved \(Self.count(moves.count)) to \(folderName)", undoTitle: "Undo") {
                self.undoMove(moves, items: items)
            }
        }
    }

    private func undoMove(_ moves: [FilesTransfer.Move], items: [FilesShelfItem]) {
        Task {
            let result = await FilesFileActions.moveBack(moves)
            for done in result.done {
                if let item = items.first(where: { FilesPath.key($0.path) == FilesPath.key(done.from.path) })
                    ?? store.items.first(where: { FilesPath.key($0.path) == FilesPath.key(done.from.path) }) {
                    store.relocate(item.id, to: done.to)
                }
            }
            if let failure = result.failures.first {
                model.show("Couldn't move “\(failure.url.lastPathComponent)” back because \(failure.reason)", tone: .danger)
            } else {
                model.show("Moved \(Self.count(result.done.count)) back")
            }
        }
    }

    func compress() {
        let urls = targetURLs
        guard !urls.isEmpty, compressHandle == nil else { return }
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
                let added = store.add([archive])
                model.selection = Set(added.map(\.id))
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
        let received = removed.map(\.item).filter(\.received).map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        let text = removed.count == store.items.count + removed.count && removed.count > 1 ? "Cleared the shelf" : "Removed \(Self.count(removed.count))"
        guard !received.isEmpty else {
            model.show(text, undoTitle: "Undo") { [weak self] in self?.store.restore(removed) }
            return
        }
        Task {
            let trash = await FilesFileActions.trash(received)
            model.show(text, undoTitle: "Undo") {
                Task {
                    _ = await FilesFileActions.moveBack(trash.trashed)
                    self.store.restore(removed)
                }
            }
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
        case 6 where flags == .command: model.undo?(); model.message = nil; return true   // ⌘Z
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
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var promises: [NSFilePromiseReceiver] = []
        if urls.isEmpty {
            promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
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
                    FilesFileDragSource(urls: { store.items.filter(\.exists).map(\.url) })
                }
            }
            .help(store.items.isEmpty ? "Drop files on the shelf" : "Drag all items out")
            .accessibilityLabel(store.items.isEmpty ? "Empty shelf" : "Drag all \(FilesShelfPanelController.count(store.items.count))")
            VStack(alignment: .leading, spacing: 0) {
                Text("Drop Shelf").font(AOMFont.headline).foregroundStyle(AOMColor.text)
                Text(subtitle).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x1)
            AOMIconButton("xmark", label: "Close Drop Shelf") { controller.hide() }
        }
        .padding(.leading, AOMSpace.x3)
        .padding(.trailing, AOMSpace.x2)
        .frame(height: 48)
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
        .background { FilesFileDragSource(urls: { controller.dragURLs(from: item) }) }
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
