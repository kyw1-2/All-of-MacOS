import AppKit
import PDFKit
import SwiftUI

/// 7.5 (Codex F07, PDF Expert's Compare PDFs): two PDFs side by side, each
/// scrolled on its own or linked by page number, with the sides swappable.
/// Both files are only read.
struct PDFCompareSync: Equatable {
    enum Side: Equatable { case left, right }

    /// Page counts (nil while a side is empty, locked or unreadable).
    var counts: [Side: Int] = [:]
    /// 0-based page each side shows.
    var pages: [Side: Int] = [.left: 0, .right: 0]
    var linked = true

    static func other(_ side: Side) -> Side { side == .left ? .right : .left }

    /// Pure: one side went to `page`; with the pages linked the other side
    /// follows to the same page number when it has it, and stays put when
    /// it doesn't (it then says it has no such page).
    mutating func move(_ side: Side, to page: Int) {
        guard let count = counts[side], count > 0 else { return }
        pages[side] = min(max(0, page), count - 1)
        guard linked else { return }
        let other = Self.other(side)
        if let otherCount = counts[other], let target = pages[side], target < otherCount { pages[other] = target }
    }

    /// "No page 7 here · this PDF has 5" when linked and the other side is past this side's end.
    func missingPage(on side: Side) -> String? {
        guard linked, let count = counts[side], let page = pages[Self.other(side)], counts[Self.other(side)] != nil, page >= count else { return nil }
        return "No page \(page + 1) here · this PDF has \(count) page\(count == 1 ? "" : "s")"
    }

    /// Pure: the documents trade places, each keeping its page.
    mutating func swap() {
        let left = (counts[.left], pages[.left]), right = (counts[.right], pages[.right])
        counts[.left] = right.0; pages[.left] = right.1
        counts[.right] = left.0; pages[.right] = left.1
    }
}

@MainActor
final class PDFCompareModel: ObservableObject {
    struct Pane {
        var url: URL?
        var document: PDFDocument?
        var locked = false
        var problem: String?
    }

    @Published private(set) var panes: [PDFCompareSync.Side: Pane] = [.left: Pane(), .right: Pane()]
    @Published var sync = PDFCompareSync()

    func pane(_ side: PDFCompareSync.Side) -> Pane { panes[side] ?? Pane() }

    func open(_ url: URL, side: PDFCompareSync.Side) {
        var pane = Pane(url: url)
        do {
            let document = try PDFTools.open(url)
            pane.document = document
            pane.locked = document.isLocked
        } catch PDFTools.Failure.locked(_) {
            pane.document = PDFDocument(url: url)
            pane.locked = true
        } catch {
            pane.problem = error.localizedDescription
        }
        panes[side] = pane
        sync.counts[side] = pane.locked ? nil : pane.document?.pageCount
        sync.pages[side] = 0
    }

    func choose(_ side: PDFCompareSync.Side) {
        guard let url = AOMFileToolsLauncher.pick("Choose the PDF for the \(side == .left ? "left" : "right") side.", types: ["pdf"])?.first else { return }
        open(url, side: side)
    }

    /// False when the password is wrong; only that side changes.
    func unlock(_ side: PDFCompareSync.Side, password: String) -> Bool {
        guard var pane = panes[side], let document = pane.document, document.unlock(withPassword: password) else { return false }
        pane.locked = false
        panes[side] = pane
        sync.counts[side] = document.pageCount
        sync.pages[side] = 0
        return true
    }

    func swap() {
        let left = panes[.left], right = panes[.right]
        panes[.left] = right
        panes[.right] = left
        sync.swap()
    }

    func step(_ side: PDFCompareSync.Side, by delta: Int) {
        sync.move(side, to: (sync.pages[side] ?? 0) + delta)
    }
}

struct PDFCompareView: View {
    @ObservedObject var model: PDFCompareModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x3) {
                Toggle(isOn: $model.sync.linked) { Label("Link Pages", systemImage: "link") }
                    .toggleStyle(.button)
                    .keyboardShortcut("l", modifiers: .command)
                    .help("Linked: turning a page on one side shows the same page number on the other (⌘L)")
                Button { model.swap() } label: { Label("Swap Sides", systemImage: "arrow.left.arrow.right") }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Spacer()
                Text("Read only: neither PDF is changed").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
            }
            .padding(.horizontal, AOMSpace.x4)
            .padding(.vertical, AOMSpace.x2)
            Divider()
            HStack(spacing: 0) {
                PDFComparePane(model: model, side: .left)
                Divider()
                PDFComparePane(model: model, side: .right)
            }
        }
    }
}

private struct PDFComparePane: View {
    @ObservedObject var model: PDFCompareModel
    let side: PDFCompareSync.Side
    @State private var password = ""
    @State private var wrongPassword = false

    var body: some View {
        let pane = model.pane(side)
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "doc.richtext").foregroundStyle(AOMColor.textSecondary)
                Text(pane.url?.lastPathComponent ?? (side == .left ? "Left" : "Right")).font(AOMFont.headline).lineLimit(1)
                    .help(pane.url?.path ?? "")
                Spacer()
                if let count = model.sync.counts[side] {
                    Button { model.step(side, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled((model.sync.pages[side] ?? 0) == 0)
                        .accessibilityLabel("Previous page")
                    Text("Page \((model.sync.pages[side] ?? 0) + 1) of \(count)").font(AOMFont.callout).monospacedDigit()
                        .foregroundStyle(AOMColor.textSecondary)
                    Button { model.step(side, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled((model.sync.pages[side] ?? 0) >= count - 1)
                        .accessibilityLabel("Next page")
                }
                Button("Open…") { model.choose(side) }
            }
            .padding(.horizontal, AOMSpace.x3)
            .padding(.vertical, AOMSpace.x2)
            Divider()
            ZStack(alignment: .top) {
                if let problem = pane.problem {
                    AOMNotice(.error, "Can't Read This PDF", detail: problem).padding(AOMSpace.x4)
                } else if pane.locked {
                    VStack(spacing: AOMSpace.x3) {
                        Image(systemName: "lock.doc").font(.system(size: 30, weight: .light)).foregroundStyle(AOMColor.textSecondary)
                        Text("This PDF needs its password").font(AOMFont.section)
                        HStack {
                            SecureField("Password", text: $password).frame(width: 200)
                                .onSubmit(unlock)
                            Button("Unlock", action: unlock)
                        }
                        if wrongPassword { Text("That password didn't open it").font(AOMFont.caption).foregroundStyle(AOMColor.dangerText) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let document = pane.document {
                    PDFCompareKitView(document: document, page: model.sync.pages[side] ?? 0) { model.sync.move(side, to: $0) }
                    if let missing = model.sync.missingPage(on: side) {
                        Label(missing, systemImage: "doc.badge.ellipsis")
                            .font(AOMFont.callout)
                            .padding(.horizontal, AOMSpace.x3).padding(.vertical, AOMSpace.x1)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, AOMSpace.x3)
                    }
                } else {
                    VStack(spacing: AOMSpace.x3) {
                        Text("No PDF on this side").foregroundStyle(AOMColor.textSecondary)
                        Button("Open a PDF…") { model.choose(side) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func unlock() {
        wrongPassword = !model.unlock(side, password: password)
        if !wrongPassword { password = "" }
    }
}

/// PDFKit's view, reporting the page it shows and going to the one asked.
private struct PDFCompareKitView: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let changed: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.changed = changed
        if view.document !== document {
            view.document = document
        }
        guard let target = document.page(at: page), let current = view.currentPage, document.index(for: current) != page else { return }
        context.coordinator.moving = true
        view.go(to: target)
        context.coordinator.moving = false
    }

    final class Coordinator: NSObject {
        var changed: (Int) -> Void
        var moving = false
        private var token: NSObjectProtocol?

        init(changed: @escaping (Int) -> Void) { self.changed = changed }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                guard let self, !self.moving, let view, let page = view.currentPage, let document = view.document else { return }
                let index = document.index(for: page)
                DispatchQueue.main.async { self.changed(index) }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
