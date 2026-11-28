import AppKit
import SwiftUI

/// The Capture page (design-3.4.0 b.2 dashboard): the status header, the ten
/// capture tools in rows that never go ragged (10 → one row or 5 × 2), the
/// Screen Ruler's section, then the history gallery. The gallery is one
/// keyboard target: arrows move the selection, Return edits, Space previews,
/// ⌘C copies and Delete removes from history (b.4).
struct CaptureStudioView: View {
    /// Observed through `observation`, so a hidden Capture page does not
    /// re-render every second of a recording.
    private let history = CaptureHistory.shared
    private let recordingService = ScreenRecordingService.shared
    private let textCapture = TextCaptureSettings.shared
    @StateObject private var observation = AOMPageObservation([
        CaptureHistory.shared.aomChanges, ScreenRecordingService.shared.aomChanges, TextCaptureSettings.shared.aomChanges,
    ])
    @State private var selectedFilter: CaptureFilter = .all
    @State private var hoveredEntryID: UUID?
    @State private var selectedEntryID: UUID?
    @State private var query = ""
    @State private var galleryWidth: CGFloat = 0
    @State private var showingSettingsSheet = false
    @State private var showingClearConfirmation = false
    @FocusState private var galleryFocused: Bool
    @StateObject private var toast = AOMToastModel()
    /// D19/D20: the library on the left, the selected capture's properties
    /// and commands in a trailing inspector when the page has room.
    @AppStorage("AOMCaptureInspector") private var showsInspector = true
    @State private var inspectorFits = false
    @State private var selectedFileBytes: Int64?

    enum CaptureFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case screenshots = "Screenshots"
        case recordings = "Recordings"
        /// Kept in history: never removed by the count or age limits.
        case kept = "Kept"

        var id: String { rawValue }
    }

    private func matches(_ entry: CaptureHistoryEntry, _ filter: CaptureFilter) -> Bool {
        switch filter {
        case .all: return true
        case .screenshots: return entry.kind != .videoRecording
        case .recordings: return entry.kind == .videoRecording
        case .kept: return entry.isPinned
        }
    }

    private var filteredEntries: [CaptureHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.entries.filter { entry in
            guard matches(entry, selectedFilter) else { return false }
            guard !needle.isEmpty else { return true }
            return entry.displayName.localizedStandardContains(needle)
                || entry.kind.displayName.localizedStandardContains(needle)
                || (entry.fileURL?.lastPathComponent.localizedStandardContains(needle) ?? false)
        }
    }

    /// The header title already counts the captures and the chips count each
    /// filter, so the context line only says when the last one was taken.
    private var subtitle: String {
        guard let latest = history.entries.first else { return "Screenshots, recordings, measuring and text recognition" }
        return "Last capture \(AOMRelativeTime.string(latest.capturedAt).lowercased())"
    }

    /// Library thumbnail size: 0 small, 1 medium, 2 large (Bear, Nova).
    @AppStorage("AOMCaptureGridDensity") private var density = 1

    private var gridMinimum: CGFloat { CaptureGalleryMetrics.columnMinimum[min(2, max(0, density))] }

    private func count(_ filter: CaptureFilter) -> Int {
        history.entries.filter { matches($0, filter) }.count
    }

    /// The selected capture, only while it is one of the captures shown.
    private var selectedEntry: CaptureHistoryEntry? {
        guard let id = selectedEntryID else { return nil }
        return filteredEntries.first { $0.id == id }
    }

    private var inspectorShown: Bool { showsInspector && inspectorFits && !history.entries.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            library
                .task { CapturePreviewSamples.seedIfRequested(into: history) }
            if inspectorShown {
                AOMDivider(axis: .vertical)
                captureInspector
                    .frame(width: AOMSize.inspectorIdeal)
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Inspector")
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateInspectorFits(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in updateInspectorFits(width) }
            }
        }
        // D05: a search or filter that hides the selected capture leaves
        // nothing selected; Return, Space, ⌫ and ⌘C then do nothing.
        .onChange(of: filteredEntries.map(\.id)) { _, ids in
            let next = AOMStableSelection.reconcile(selectedEntryID, visible: ids, autoSelectFirst: false)
            if next != selectedEntryID { selectedEntryID = next }
        }
        .task(id: selectedEntry?.fileURL) {
            // The file's size for the inspector, read off the main thread once per selection.
            guard let url = selectedEntry?.fileURL else { selectedFileBytes = nil; return }
            let bytes = await Task.detached(priority: .utility) {
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
            }.value
            guard !Task.isCancelled else { return }
            selectedFileBytes = bytes
        }
        .aomPage("Capture")
        .aomObserving(observation)
        .aomPageToolbar {
            toolbarContent
            AOMToolbarSearchItem(text: $query, prompt: "Search captures")
        }
        .sheet(isPresented: $showingSettingsSheet) {
            ModuleSettingsSheet("Capture Settings", done: { showingSettingsSheet = false }) {
                CaptureSettingsView()
            }
        }
        .alert("Clear capture history?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                history.removeAll()
                selectedEntryID = nil
                toast.show("Capture history cleared")
            }
        } message: {
            Text("Recent captures are removed from history. Screenshot and video files saved in Finder are not deleted.")
        }
        .aomToast(toast)
    }

    // MARK: - Inspector (D20)

    /// The library keeps at least this much beside the inspector.
    private static let libraryMinimum: CGFloat = 560

    private func updateInspectorFits(_ width: CGFloat) {
        let fits = AOMWorkbenchPolicy.sideBySide(
            available: width, minimum: Self.libraryMinimum + AOMSize.inspectorIdeal + AOMWorkbenchPolicy.dividerAllowance,
            current: inspectorFits)
        if fits != inspectorFits { inspectorFits = fits }
    }

    private var captureInspector: some View {
        AOMInspector {
            if let entry = selectedEntry {
                AOMInspectorSection(entry.displayName, showsDivider: false) {
                    AOMInspectorRow("Kind", text: entry.kind.displayName)
                    AOMInspectorRow("Pixels", text: "\(Int(entry.pixelSize.width)) × \(Int(entry.pixelSize.height))")
                    AOMInspectorRow("Points", text: "\(Int(entry.pointSize.width)) × \(Int(entry.pointSize.height)) @\(Double(entry.scale).formatted(.number.precision(.fractionLength(0...1))))x")
                    AOMInspectorRow("Captured", text: entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    AOMInspectorRow("Kept", text: entry.isPinned ? "Yes — past the history limits" : "No")
                }
                AOMInspectorSection("File") {
                    if let url = entry.fileURL {
                        AOMInspectorRow("Name") { Text(url.lastPathComponent).textSelection(.enabled) }
                        AOMInspectorRow("Format", text: url.pathExtension.uppercased())
                        AOMInspectorRow("Size", text: selectedFileBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                        AOMInspectorRow("Where") {
                            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    } else {
                        Text("Not saved to a file. Copy it, or set where captures are saved in Capture Settings.")
                            .font(AOMFont.callout)
                            .foregroundStyle(AOMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                AOMInspectorSection("Actions") {
                    HStack(spacing: AOMSpace.x2) {
                        Button(entry.kind == .videoRecording ? "Edit Recording" : "Annotate") { CapturePreviewActions.edit(entry) }
                            .help("Open it in the editor (Return)")
                        Button("Preview") { QuickAccessExpandedPreview.shared.open(entry: entry) }
                            .help("Quick Look (Space)")
                    }
                    HStack(spacing: AOMSpace.x2) {
                        Button("Copy") { copy(entry) }.help("Copy it (⌘C)")
                        if let url = entry.fileURL {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
            } else {
                AOMInspectorSection("Capture", showsDivider: false) {
                    Text("Select a capture to see its size, file and where it is saved.")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Library (D19: commands on top, the library under them)

    private var library: some View {
        AOMPage {
            header
            if recordingService.isRecording {
                activeRecordingBanner
            }
            // 7.24 (menu bar spec §4.4, CleanShot X / Shottr): one slim row —
            // the five everyday modes and Record, the rest under More — so the
            // captures themselves are the page, not ten tiles above them.
            captureToolbar
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Capture tools")
            VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
                // Nothing to filter or size before the first capture.
                if !history.entries.isEmpty {
                    AOMTipCard(id: "capture.gallery", symbol: "hand.draw",
                               title: "Drag captures anywhere",
                               message: "Drag a capture into any app or the Finder. Double-click to edit it, press Space to preview it, or right-click for more.")
                        .padding(.bottom, AOMSpace.x2)
                    filterBar
                }
                gallerySection
            }
            // The ruler's settings come after the captures they sit beside.
            ScreenRulerSection()
        }
    }

    /// d.9: what Capture holds and when it last ran; recording is a status
    /// (the pill and the strip below), not an error (e.6). With additive copy
    /// on, the pill says so, so the next Copy Text never surprises (b.16).
    private var header: some View {
        let count = history.entries.count
        let status: AOMStatus? = recordingService.isRecording
            ? AOMStatus(recordingService.isPaused ? "Paused" : "Rec",
                        tone: recordingService.isPaused ? .neutral : .recording, symbol: "record.circle")
            : (textCapture.additiveClipboard ? AOMStatus("Copy Text Adds", tone: .info, symbol: "text.append") : nil)
        return AOMPageHeader(recordingService.isRecording ? "Recording the screen"
                             : (count == 0 ? "No captures yet" : "\(count) capture\(count == 1 ? "" : "s") in history"),
                             subtitle: subtitle,
                             status: status,
                             help: "Capture takes screenshots, recordings and text from any app and measures the screen. Each capture opens in Quick Access to copy, save, annotate or drag, and stays in history until you remove it.")
    }

    // MARK: - Toolbar (b.3: More, the one primary Capture action, search)

    private func keys(_ action: CaptureShortcutAction) -> String {
        CaptureShortcuts.shared.shortcut(for: action).map { "  \($0.displayString)" } ?? ""
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                CaptureHistoryWindowController.shared.present()
            } label: {
                Label("History Overlay", systemImage: "clock.arrow.circlepath")
            }
            .help("Open the floating capture history")
            if !history.entries.isEmpty {
                Button {
                    withAnimation(AOMMotion.panel) { showsInspector.toggle() }
                } label: {
                    Label(showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showsInspector ? "Hide the selected capture's details (⌥⌘I)"
                                     : "Show the selected capture's size, file and actions beside the library (⌥⌘I)")
            }
            Menu {
                Button("Open Image…") { AnnotationEditorController.shared.chooseImageOrProject() }
                Button("Toggle Desktop Icons") {
                    CaptureCoordinator.shared.toggleDesktopIcons()
                    toast.show("Desktop icons toggled")
                }
                if CaptureCoordinator.shared.canRestoreQuickAccess {
                    Button("Restore Last Closed Overlay") { CaptureCoordinator.shared.restoreRecentlyClosedOverlay() }
                }
                Divider()
                if !history.entries.isEmpty {
                    Button("Clear History…", role: .destructive) { showingClearConfirmation = true }
                    Divider()
                }
                Button("Capture Settings…") { showingSettingsSheet = true }
            } label: {
                Label("Capture Options", systemImage: "slider.horizontal.3")
            }
            .help("Open an image, desktop icons, history and settings")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                // The same names as the strip on the page, one name per mode.
                Button("All-In-One\(keys(.allInOne))") { CaptureCoordinator.shared.captureAllInOne() }
                Button("Area\(keys(.captureArea))") { CaptureCoordinator.shared.captureArea() }
                Button("Window\(keys(.captureWindow))") { CaptureCoordinator.shared.captureWindowInteractive() }
                Button("Full Screen\(keys(.captureFullscreen))") { CaptureCoordinator.shared.captureFullscreen() }
                Button("Scrolling\(keys(.scrollingCapture))") { CaptureCoordinator.shared.captureScrolling() }
                Button("Previous Area\(keys(.capturePreviousArea))") { CaptureCoordinator.shared.capturePreviousArea() }
                Button("Self-Timer") { CaptureCoordinator.shared.captureWithSelfTimer() }
                Divider()
                Button("Record Screen\(keys(.recordScreen))") { recordingService.promptAndStartRecording() }
                Divider()
                Button("Text\(keys(.ocr))") { CaptureCoordinator.shared.captureText() }
                Button("QR Code") { CaptureCoordinator.shared.captureQRCode() }
                Toggle("Add Copied Text to Clipboard", isOn: Binding(
                    get: { textCapture.additiveClipboard },
                    set: { textCapture.additiveClipboard = $0 }))
                Divider()
                Button("Measure Screen\(keys(.measureScreen))") { ScreenRulerModule.measure() }
            } label: {
                Label("Capture Area", systemImage: "viewfinder")
            } primaryAction: {
                CaptureCoordinator.shared.captureArea()
            }
            .help("Capture an area\(keys(.captureArea)); open the menu for every capture tool")
        }
    }

    private func shortcut(_ action: CaptureShortcutAction) -> String? {
        CaptureShortcuts.shared.shortcut(for: action)?.displayString
    }

    // MARK: - Tools

    /// One capture tool in the strip.
    private struct Tool: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var tint: Color = AOMTheme.text
        var shortcut: String?
        var help: String?
        var disabled = false
        let action: () -> Void
    }

    /// Every capture mode one click away, in CleanShot's order, then Measure.
    private var tools: [Tool] {
        let text = textCapture.additiveClipboard
            ? "Copy Text\(shortcut(.ocr).map { " (\($0))" } ?? ""): adds to the text already on the clipboard"
            : nil
        return [
            Tool(id: "allInOne", title: "All-In-One", symbol: "rectangle.dashed.badge.record", shortcut: shortcut(.allInOne)) {
                CaptureCoordinator.shared.captureAllInOne()
            },
            Tool(id: "area", title: "Area", symbol: "viewfinder", shortcut: shortcut(.captureArea)) {
                CaptureCoordinator.shared.captureArea()
            },
            Tool(id: "window", title: "Window", symbol: "macwindow", shortcut: shortcut(.captureWindow)) {
                CaptureCoordinator.shared.captureWindowInteractive()
            },
            // The same glyph as the status menu's Full Screen item.
            Tool(id: "fullScreen", title: "Full Screen", symbol: "display", shortcut: shortcut(.captureFullscreen)) {
                CaptureCoordinator.shared.captureFullscreen()
            },
            Tool(id: "scrolling", title: "Scrolling", symbol: "arrow.up.and.down.text.horizontal", shortcut: shortcut(.scrollingCapture)) {
                CaptureCoordinator.shared.captureScrolling()
            },
            Tool(id: "timer", title: "Self-Timer", symbol: "timer") {
                CaptureCoordinator.shared.captureWithSelfTimer()
            },
            Tool(id: "record", title: recordingService.isRecording ? "Recording" : "Record Screen", symbol: "record.circle",
                 tint: AOMTheme.danger, shortcut: shortcut(.recordScreen), disabled: recordingService.isRecording) {
                recordingService.promptAndStartRecording()
            },
            Tool(id: "text", title: "Text", symbol: textCapture.additiveClipboard ? "text.append" : "text.viewfinder",
                 shortcut: shortcut(.ocr), help: text) {
                CaptureCoordinator.shared.captureText()
            },
            Tool(id: "qr", title: "QR Code", symbol: "qrcode.viewfinder") {
                CaptureCoordinator.shared.captureQRCode()
            },
            Tool(id: "measure", title: "Measure Screen", symbol: "ruler", shortcut: shortcut(.measureScreen),
                 help: "Measure Screen\(shortcut(.measureScreen).map { " (\($0))" } ?? ""): distances and sizes on screen") {
                ScreenRulerModule.measure()
            },
        ]
    }

    private func toolButton(_ tool: Tool) -> some View {
        AOMModeButton(tool.title, symbol: tool.symbol, tint: tool.tint, shortcut: tool.shortcut, help: tool.help,
                      action: tool.action)
            .disabled(tool.disabled)
    }

    static let toolbarIDs: Set<String> = ["allInOne", "area", "window", "fullScreen", "scrolling", "record"]

    private var captureToolbar: some View {
        let all = tools
        return HStack(spacing: AOMSpace.x1) {
            ForEach(all.filter { Self.toolbarIDs.contains($0.id) }) { tool in
                Button(action: tool.action) {
                    HStack(spacing: AOMSpace.x1) {
                        Image(systemName: tool.symbol).foregroundStyle(tool.tint == AOMTheme.text ? AOMModule.capture.hue : tool.tint)
                        Text(tool.title).font(AOMFont.callout.weight(.medium)).lineLimit(1)
                        if let shortcut = tool.shortcut {
                            Text(shortcut).font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(height: 32)
                    .background(AOMColor.surface, in: RoundedRectangle(cornerRadius: AOMRadius.control + 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AOMRadius.control + 3, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(tool.disabled)
                .help(tool.help ?? (tool.shortcut.map { "\(tool.title) (\($0))" } ?? tool.title))
            }
            Menu {
                ForEach(all.filter { !Self.toolbarIDs.contains($0.id) }) { tool in
                    Button { tool.action() } label: { Label(tool.title + (tool.shortcut.map { "  \($0)" } ?? ""), systemImage: tool.symbol) }
                }
                Divider()
                Button { AnnotationEditorController.shared.chooseImageOrProject() } label: { Label("Open & Annotate…", systemImage: "pencil.and.outline") }
                Button { CaptureHistoryWindowController.shared.present() } label: { Label("History Overlay", systemImage: "clock.arrow.circlepath") }
                Button {
                    CaptureCoordinator.shared.toggleDesktopIcons()
                    toast.show("Desktop icons toggled")
                } label: { Label("Toggle Desktop Icons", systemImage: "menubar.dock.rectangle") }
                Toggle("Append OCR Text", isOn: Binding(get: { textCapture.additiveClipboard }, set: { textCapture.additiveClipboard = $0 }))
                Divider()
                Button { showingSettingsSheet = true } label: { Label("Capture Settings…", systemImage: "slider.horizontal.3") }
            } label: {
                Label("More", systemImage: "ellipsis.circle").font(AOMFont.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Self-Timer, Text, QR Code, Measure, Open & Annotate, settings")
            Spacer(minLength: 0)
        }
    }

    /// What the gallery shows, with the thumbnail size at the trailing end of
    /// the same row (one control row above the grid, not two).
    private var filterBar: some View {
        HStack(spacing: AOMSpace.x3) {
            AOMScopeBar(items: CaptureFilter.allCases.map { filter in
                AOMScopeItem(id: filter, title: filter.rawValue, count: count(filter))
            }, selection: $selectedFilter, accessibilityLabel: "Show")
            Picker("Thumbnail size", selection: $density) {
                Image(systemName: "square.grid.3x3").tag(0).help("Small thumbnails")
                Image(systemName: "square.grid.2x2").tag(1).help("Medium thumbnails")
                Image(systemName: "rectangle.grid.1x2").tag(2).help("Large thumbnails")
                // 7.19 (D19): a list — name, kind, size and time beside a small thumbnail.
                Image(systemName: "list.bullet").tag(3).help("List")
            }
            .aomSegmented()
            .labelsHidden()
            .fixedSize()
            .help("Thumbnail size")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: AOMSize.rowSingle)
    }

    // MARK: - Active Recording Banner

    /// A long-running capture adds a strip under the header (d.2): the
    /// recording colour on the glyph only, the controls beside it. The header
    /// and its pill already say recording or paused, so the strip holds one
    /// line: the elapsed time and the controls.
    private var activeRecordingBanner: some View {
        HStack(spacing: AOMSpace.x3) {
            Image(systemName: "record.circle")
                .font(AOMFont.section)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(recordingService.isPaused ? AOMColor.paused : AOMColor.recording)
                .symbolEffect(.pulse, options: .repeating, isActive: !recordingService.isPaused)
                .accessibilityHidden(true)
            Text(formatElapsed(recordingService.elapsedSeconds))
                .font(AOMFont.headline.monospacedDigit())
                .foregroundStyle(AOMColor.text)
                .contentTransition(.numericText())
                .accessibilityLabel("\(recordingService.isPaused ? "Paused" : "Recording"), \(formatElapsed(recordingService.elapsedSeconds))")
            Spacer(minLength: AOMSpace.x3)
            Button {
                recordingService.togglePause()
            } label: {
                Label(recordingService.isPaused ? "Resume" : "Pause",
                      systemImage: recordingService.isPaused ? "play.fill" : "pause.fill")
            }
            Button("Cancel") {
                recordingService.cancelRecording()
                toast.show("Recording cancelled", tone: .neutral)
            }
            Button {
                Task {
                    do {
                        _ = try await recordingService.stopRecording()
                        toast.show("Recording saved")
                    } catch {
                        toast.show("Couldn't save the recording because \(error.localizedDescription)", tone: .danger)
                    }
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(AOMPrimaryButtonStyle())
            .tint(AOMColor.recording)
        }
        .aomCard()
    }

    // MARK: - Gallery Section

    private var showsList: Bool { density == 3 }

    private var columnCount: Int {
        guard galleryWidth > 0, !showsList else { return 1 }
        return max(1, Int((galleryWidth + AOMSpace.tileGap) / (gridMinimum + AOMSpace.tileGap)))
    }

    @ViewBuilder
    private var gallerySection: some View {
        let entries = filteredEntries
        if entries.isEmpty {
            emptyGallery
        } else {
            Group {
                if showsList {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            listRow(entry)
                            if entry.id != entries.last?.id { AOMRowDivider(inset: AOMSpace.rowInset + 64 + AOMSpace.x3) }
                        }
                    }
                    .aomCard(padding: 0)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMinimum,
                                                           maximum: gridMinimum * CaptureGalleryMetrics.columnStretch),
                                                 spacing: AOMSpace.tileGap)],
                              spacing: AOMSpace.tileGap) {
                        ForEach(entries) { entry in
                            card(entry)
                        }
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { galleryWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in galleryWidth = width }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($galleryFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .delete, "c"],
                        phases: .down) { press in
                handleKey(press, entries: entries)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Captures")
        }
    }

    @ViewBuilder
    private var emptyGallery: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            AOMEmptyState("No Results", systemImage: "magnifyingglass",
                          message: "No capture matches “\(query)”.") {
                Button("Clear Search") { query = "" }
            }
            .frame(minHeight: CaptureGalleryMetrics.emptyMinHeight)
        } else if history.entries.isEmpty || selectedFilter == .all {
            AOMEmptyState("No Captures Yet", systemImage: "camera.badge.ellipsis",
                          message: "Screenshots and recordings you take appear here, ready to annotate, pin, copy or reopen.") {
                Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                    .buttonStyle(AOMPrimaryButtonStyle())
            }
            .frame(minHeight: CaptureGalleryMetrics.emptyMinHeight)
        } else {
            AOMEmptyState("Nothing in \(selectedFilter.rawValue)", systemImage: "camera.badge.ellipsis",
                          message: selectedFilter == .kept
                            ? "Keep a capture from its menu and it stays here past the history limits."
                            : "Captures of this kind appear here.") {
                Button("Show All") { selectedFilter = .all }
            }
            .frame(minHeight: CaptureGalleryMetrics.emptyMinHeight)
        }
    }

    /// 7.19 (D19): one capture as a list row.
    private func listRow(_ entry: CaptureHistoryEntry) -> some View {
        let selected = selectedEntryID == entry.id
        return HStack(spacing: AOMSpace.x3) {
            Image(nsImage: entry.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
                    .strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(entry.displayName).font(AOMFont.bodyEmphasis).lineLimit(1).truncationMode(.middle)
                Text("\(entry.kind.displayName) · \(entry.pixelWidth) × \(entry.pixelHeight)")
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x2)
            if entry.isPinned {
                Image(systemName: "pin.fill").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                    .accessibilityLabel("Kept")
            }
            Text(entry.capturedAt, style: .relative)
                .font(AOMFont.timestamp).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
                    .fill(AOMColor.accent.opacity(galleryFocused ? 0.16 : 0.08))
                    .padding(.horizontal, AOMSpace.x1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { QuickAccessExpandedPreview.shared.open(entry: entry) }
        .onTapGesture { selectedEntryID = entry.id; galleryFocused = true }
        .contextMenu {
            Button("Open & Annotate") { CapturePreviewActions.edit(entry) }
            Button("Copy") { copy(entry) }
            if let url = entry.fileURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button(entry.isPinned ? "Don't Keep" : "Keep in History") { history.togglePin(entry) }
            Divider()
            Button("Delete", role: .destructive) { remove(entry) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func card(_ entry: CaptureHistoryEntry) -> some View {
        CaptureCard(
            entry: entry,
            isHovered: hoveredEntryID == entry.id,
            isSelected: selectedEntryID == entry.id,
            isFocused: galleryFocused,
            onSelect: {
                selectedEntryID = entry.id
                galleryFocused = true
            },
            onEdit: { CapturePreviewActions.edit(entry) },
            onPreview: { QuickAccessExpandedPreview.shared.open(entry: entry) },
            onCopy: { copy(entry) },
            onShowInFinder: entry.fileURL.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
            onPin: {
                PinnedScreenshotController.shared.pin(entry: entry, url: entry.fileURL)
                toast.show("Pinned to the screen")
            },
            onToggleKeep: {
                let kept = !entry.isPinned
                history.togglePin(entry)
                toast.show(kept ? "Kept in history" : "No longer kept in history")
            },
            onRestoreOverlay: { CaptureCoordinator.shared.restoreToQuickAccess(entry) },
            onDelete: { remove(entry) }
        )
        .onHover { isHovering in
            if isHovering { hoveredEntryID = entry.id } else if hoveredEntryID == entry.id { hoveredEntryID = nil }
        }
    }

    // MARK: - Actions

    private func copy(_ entry: CaptureHistoryEntry) {
        CapturePreviewActions.copyReporting(entry) { failure in
            if let failure {
                toast.show("Couldn't copy “\(entry.displayName)”. \(failure)", tone: .danger)
            } else {
                toast.show("Copied “\(entry.displayName)”")
            }
        }
    }

    /// Removing from history leaves the file in the Finder; the selection
    /// moves to the neighbouring capture (#97).
    private func remove(_ entry: CaptureHistoryEntry) {
        let entries = filteredEntries
        if selectedEntryID == entry.id, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let next = entries.indices.contains(index + 1) ? entries[index + 1] : (index > 0 ? entries[index - 1] : nil)
            selectedEntryID = next?.id
        }
        withAnimation(AOMMotion.standard) { history.remove(entry) }
        toast.show(entry.fileURL == nil ? "Removed “\(entry.displayName)” from history"
                                        : "Removed from history; the file stays in the Finder")
    }

    private func handleKey(_ press: KeyPress, entries: [CaptureHistoryEntry]) -> KeyPress.Result {
        let modifiers = press.modifiers.intersection([.command, .option, .control, .shift])
        let index = entries.firstIndex { $0.id == selectedEntryID }
        let selected = index.map { entries[$0] }
        switch press.key {
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard modifiers.isEmpty else { return .ignored }
            let step: Int
            switch press.key {
            case .leftArrow: step = -1
            case .rightArrow: step = 1
            case .upArrow: step = -columnCount
            default: step = columnCount
            }
            let target = index.map { min(entries.count - 1, max(0, $0 + step)) } ?? 0
            selectedEntryID = entries[target].id
            return .handled
        case .return:
            guard modifiers.isEmpty, let selected else { return .ignored }
            CapturePreviewActions.edit(selected)
            return .handled
        case .space:
            guard modifiers.isEmpty, let selected else { return .ignored }
            QuickAccessExpandedPreview.shared.open(entry: selected)
            return .handled
        case .delete:
            guard modifiers.isEmpty || modifiers == .command, let selected else { return .ignored }
            remove(selected)
            return .handled
        default:
            guard press.characters == "c", modifiers == .command, let selected else { return .ignored }
            copy(selected)
            return .handled
        }
    }

    // MARK: - Helpers

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Subviews

private struct CaptureCard: View {
    let entry: CaptureHistoryEntry
    let isHovered: Bool
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onPreview: () -> Void
    let onCopy: () -> Void
    var onShowInFinder: (() -> Void)?
    let onPin: () -> Void
    let onToggleKeep: () -> Void
    let onRestoreOverlay: () -> Void
    let onDelete: () -> Void

    private var isVideo: Bool { entry.kind == .videoRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // A quiet well like every other inset surface on the sheet.
                AOMColor.sunken
                Image(nsImage: entry.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(AOMSpace.x2)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                HStack(spacing: AOMSpace.x1) {
                    if isVideo { badge("Video", "play.fill", AOMColor.recording) }
                    if entry.isPinned { badge("Kept in History", "bookmark.fill", AOMColor.warning) }
                }
                .padding(AOMSpace.x2)
            }
            .overlay(alignment: .bottom) {
                // Accelerators only: every one of these is also in the ⋯ menu
                // and the context menu (b.4, nothing exists only on hover).
                if isHovered {
                    HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                        hoverButton("doc.on.doc", "Copy", action: onCopy)
                        hoverButton(isVideo ? "scissors" : "pencil", isVideo ? "Edit Recording" : "Edit", action: onEdit)
                        if let onShowInFinder { hoverButton("folder", "Show in Finder", action: onShowInFinder) }
                        hoverButton("pin", "Pin to Screen", action: onPin)
                        Spacer(minLength: 0)
                        hoverButton("trash", "Remove from History", role: .destructive, action: onDelete)
                    }
                    .padding(AOMSpace.x2)
                    .transition(.opacity)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: AOMRadius.card, topTrailingRadius: AOMRadius.card,
                                              style: .continuous))

            // One line under the picture: the name, the time and the menu.
            // The kind and pixel size are in the tooltip and the VoiceOver label.
            HStack(spacing: AOMSpace.x2) {
                Text(entry.displayName)
                    .font(AOMFont.bodyEmphasis)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AOMSpace.x1)
                Text(AOMRelativeTime.string(entry.capturedAt))
                    .font(AOMFont.timestamp)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Menu {
                    menuItems
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                .tint(AOMColor.textSecondary)
                .help("Actions")
                .accessibilityLabel("Actions for \(entry.displayName)")
            }
            .padding(.leading, AOMSpace.x3)
            .padding(.trailing, AOMSpace.x1)
            .frame(height: AOMSize.rowSingle + AOMSpace.x1)
        }
        // Hover shifts the fill only; cards never lift or outline (c.6).
        .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, hovering: isHovered)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
                    .strokeBorder(isFocused ? AOMColor.focusRing : AOMColor.textTertiary, lineWidth: 3)
                    .padding(-2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .aomAnimation(.quick, value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
        // One recogniser: the first click selects at once, the second edits.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onEdit() } else { onSelect() }
        }
        .onDrag { CaptureItemActions.dragProvider(entry) }
        .help(details)
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.displayName), \(entry.kind.displayName), \(pixelSizeText)\(entry.isPinned ? ", kept in history" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "Copy", onCopy)
        .accessibilityAction(named: isVideo ? "Edit Recording" : "Edit", onEdit)
        .accessibilityAction(named: "Preview", onPreview)
        .accessibilityAction(named: "Remove from History", onDelete)
    }

    /// Flat, no shortcuts, unavailable items hidden (b.4, #126–#128).
    @ViewBuilder
    private var menuItems: some View {
        Button(isVideo ? "Edit Recording" : "Edit", action: onEdit)
        Button("Copy", action: onCopy)
        Button("Preview", action: onPreview)
        Button("Pin to Screen", action: onPin)
        Button("Reopen in Quick Access", action: onRestoreOverlay)
        if let onShowInFinder { Button("Show in Finder", action: onShowInFinder) }
        Divider()
        Button(entry.isPinned ? "Don't Keep in History" : "Keep in History", action: onToggleKeep)
        Button("Remove from History", role: .destructive, action: onDelete)
    }

    private var pixelSizeText: String { "\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))" }

    /// The card's tooltip: the name, the kind when the name doesn't already
    /// say it, and the pixel size (the footer keeps to one line).
    private var details: String {
        let kind = entry.kind.displayName == entry.displayName ? nil : entry.kind.displayName
        return [entry.displayName, kind, pixelSizeText, entry.isPinned ? "Kept in history" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func badge(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(AOMFont.badge.weight(.bold))
            .foregroundStyle(AOMFeatureColor.onMedia)
            .frame(width: AOMFeatureSize.thumbnailBadge, height: AOMFeatureSize.thumbnailBadge)
            .background(tint, in: Circle())
            .help(title)
    }

    /// Actions over the thumbnail: opaque plates, so they read on any capture
    /// (no material over media in a scrolling grid).
    private func hoverButton(_ symbol: String, _ help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(role == .destructive ? AOMColor.dangerText : AOMColor.text)
                .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                .background(AOMColor.raised, in: Circle())
                .overlay(Circle().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Gallery metrics

/// Gallery sizes the shared scale has no token for.
private enum CaptureGalleryMetrics {
    /// The thumbnail column minimum at the small, medium and large sizes
    /// (3.3.6: 128 / 164 / 240 → 160 / 220 / 320, so a 1320 pt window shows
    /// four medium thumbnails a row at a size you can read, as Photos' medium grid).
    static let columnMinimum: [CGFloat] = [160, 220, 320]
    /// How far a column may grow past its minimum before another one fits.
    static let columnStretch: CGFloat = 1.6
    /// The empty gallery keeps the page from collapsing under the strip.
    static let emptyMinHeight: CGFloat = 200
    /// A tool in the one-row strip needs this much for "Measure Screen" in
    /// Caption; narrower columns use two rows of five.
    static let toolRowMinimum: CGFloat = 92
}

// MARK: - Settings sheet

/// The settings sheet the Capture and Clipboard pages open: the size and the
/// title bar with Done that Settings uses for the same views
/// (`SettingsSheetHost`), so Capture Settings and Clipboard Settings look the
/// same wherever they are opened.
struct ModuleSettingsSheet<Content: View>: View {
    let title: String
    let done: () -> Void
    @ViewBuilder var content: Content

    init(_ title: String, done: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.done = done
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                Text(title)
                    .font(AOMFont.headline)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AOMSpace.x2)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction).buttonStyle(AOMPrimaryButtonStyle())
            }
            .padding(.horizontal, AOMSpace.x4)
            .padding(.vertical, AOMSpace.x3)
            AOMDivider()
            content
        }
        .frame(minWidth: AOMSize.readableWidth, idealWidth: AOMSize.readableWidth, maxWidth: .infinity,
               minHeight: ModuleSettingsSheetMetrics.minHeight, idealHeight: ModuleSettingsSheetMetrics.idealHeight,
               maxHeight: .infinity)
        .onExitCommand(perform: done)
    }
}

/// The settings sheet's height in Settings (`SettingsHub`), which has no token.
private enum ModuleSettingsSheetMetrics {
    static let minHeight: CGFloat = 560
    static let idealHeight: CGFloat = 620
}
