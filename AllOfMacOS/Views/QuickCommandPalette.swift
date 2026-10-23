import AppKit
import SwiftUI

/// Raycast / Spotlight-style ⌘K Universal Command Palette.
/// Allows searching and executing actions, selecting triggers,
/// searching clipboard memory, and opening recent captures from anywhere.
struct QuickCommandPalette: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    @ObservedObject private var clipboardStore = ClipboardStore.shared
    @ObservedObject private var captureHistory = CaptureHistory.shared

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFieldFocused: Bool

    struct PaletteItem: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let iconColor: Color
        let category: String
        let shortcutHint: String?
        let action: () -> Void

        static func == (lhs: PaletteItem, rhs: PaletteItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []

        // 1. Core System & Capture Launchers
        items.append(PaletteItem(
            id: "capture.area",
            title: "Capture Area",
            subtitle: "Select custom region to screenshot",
            icon: "viewfinder",
            iconColor: .blue,
            category: "Capture Studio",
            shortcutHint: "⇧⌘4",
            action: {
                isPresented = false
                CaptureCoordinator.shared.captureArea()
            }
        ))

        items.append(PaletteItem(
            id: "capture.window",
            title: "Capture Window",
            subtitle: "Capture interactive app window",
            icon: "macwindow",
            iconColor: .indigo,
            category: "Capture Studio",
            shortcutHint: "⇧⌘5",
            action: {
                isPresented = false
                CaptureCoordinator.shared.captureWindowInteractive()
            }
        ))

        items.append(PaletteItem(
            id: "capture.fullscreen",
            title: "Capture Fullscreen",
            subtitle: "Grab entire monitor display",
            icon: "display",
            iconColor: .purple,
            category: "Capture Studio",
            shortcutHint: "⇧⌘3",
            action: {
                isPresented = false
                CaptureCoordinator.shared.captureFullscreen()
            }
        ))

        items.append(PaletteItem(
            id: "capture.ocr",
            title: "Capture Text (OCR)",
            subtitle: "Extract editable text from screen area",
            icon: "character.text.viewfinder",
            iconColor: .orange,
            category: "Capture Studio",
            shortcutHint: "⇧⌘2",
            action: {
                isPresented = false
                CaptureCoordinator.shared.captureText()
            }
        ))

        items.append(PaletteItem(
            id: "capture.record",
            title: "Record Screen Video",
            subtitle: "Start recording video with audio/mic",
            icon: "video.fill",
            iconColor: .red,
            category: "Capture Studio",
            shortcutHint: "⇧⌘6",
            action: {
                isPresented = false
                ScreenRecordingService.shared.promptAndStartRecording()
            }
        ))

        // 2. Common Window Management Actions
        items.append(PaletteItem(
            id: "window.left",
            title: "Tile Window Left 1/2",
            subtitle: "Snap active window to the left half",
            icon: "rectangle.leadinghalf.filled",
            iconColor: .blue,
            category: "Window Management",
            shortcutHint: "Snap",
            action: {
                isPresented = false
                ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowLeft))
            }
        ))

        items.append(PaletteItem(
            id: "window.right",
            title: "Tile Window Right 1/2",
            subtitle: "Snap active window to the right half",
            icon: "rectangle.trailinghalf.filled",
            iconColor: .blue,
            category: "Window Management",
            shortcutHint: "Snap",
            action: {
                isPresented = false
                ActionExecutor.executeAction(TriggerAction(actionType: .snapWindowRight))
            }
        ))

        items.append(PaletteItem(
            id: "window.maximize",
            title: "Maximize Window",
            subtitle: "Fill the entire visible screen area",
            icon: "arrow.up.left.and.arrow.down.right.rectangle",
            iconColor: .blue,
            category: "Window Management",
            shortcutHint: "Snap",
            action: {
                isPresented = false
                ActionExecutor.executeAction(TriggerAction(actionType: .maximizeWindow))
            }
        ))

        // 3. User Gestures & Triggers
        for trigger in appState.currentPreset.triggers {
            items.append(PaletteItem(
                id: "trigger.\(trigger.id.uuidString)",
                title: trigger.displayName,
                subtitle: "\(trigger.input.category.rawValue) • \(trigger.actions.count) actions",
                icon: trigger.input.category.iconName,
                iconColor: .cyan,
                category: "Triggers & Gestures",
                shortcutHint: trigger.modifierLabel.isEmpty ? nil : trigger.modifierLabel,
                action: {
                    isPresented = false
                    appState.selectedTrigger = trigger
                }
            ))
        }

        // 4. Clipboard Items (recent 15)
        for entry in clipboardStore.entries.prefix(15) {
            items.append(PaletteItem(
                id: "clipboard.\(entry.id.uuidString)",
                title: entry.title,
                subtitle: "\(entry.sourceName ?? "Clipboard") • \(entry.previewText.prefix(40))",
                icon: entry.kind.symbol,
                iconColor: .indigo,
                category: "Clipboard History",
                shortcutHint: "Paste",
                action: {
                    isPresented = false
                    _ = try? clipboardStore.write(entryIDs: [entry.id], plainText: false)
                }
            ))
        }

        // 5. Recent Captures (recent 5)
        for capture in captureHistory.entries.prefix(5) {
            items.append(PaletteItem(
                id: "capture.\(capture.id.uuidString)",
                title: capture.displayName,
                subtitle: "\(capture.kind.displayName) • \(Int(capture.pixelSize.width))×\(Int(capture.pixelSize.height))",
                icon: "photo",
                iconColor: .orange,
                category: "Recent Captures",
                shortcutHint: "Open",
                action: {
                    isPresented = false
                    AnnotationEditorController.shared.open(capture: capture, url: capture.fileURL)
                }
            ))
        }

        return items
    }

    private var filteredItems: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return allItems
        }
        return allItems.filter { item in
            item.title.localizedCaseInsensitiveContains(trimmed) ||
            item.subtitle.localizedCaseInsensitiveContains(trimmed) ||
            item.category.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack {
            // Dismiss background overlay
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            VStack(spacing: 0) {
                // Search Input Header
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)

                    TextField("Search actions, gestures, clipboard, captures…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($isFieldFocused)
                        .onChange(of: query) { _, _ in
                            selectedIndex = 0
                        }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("esc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                // Results List
                if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("No matching actions or items")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                    let isSelected = selectedIndex == index

                                    Button {
                                        item.action()
                                    } label: {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .fill(Color.clear)
                                                    .frame(width: 28, height: 28)

                                                Image(systemName: item.icon)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(AOMTheme.textSecondary)
                                            }

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title)
                                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                                    .foregroundStyle(AOMTheme.text)
                                                    .lineLimit(1)

                                                Text(item.subtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer()

                                            Text(item.category)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.tertiary)

                                            if let hint = item.shortcutHint {
                                                Text(hint)
                                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                            }

                                            Image(systemName: "return")
                                                .font(.system(size: 10))
                                                .foregroundStyle(isSelected ? Color.accentColor : .clear)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(isSelected ? AOMTheme.cardAlt : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(index)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: selectedIndex) { _, newIndex in
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }

                Divider()

                // Keyboard Navigation Hints Footer
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("↑↓").font(.system(size: 10, weight: .bold))
                        Text("Navigate").font(.system(size: 11))
                    }
                    HStack(spacing: 4) {
                        Text("↵").font(.system(size: 10, weight: .bold))
                        Text("Execute").font(.system(size: 11))
                    }
                    HStack(spacing: 4) {
                        Text("esc").font(.system(size: 10, weight: .bold))
                        Text("Dismiss").font(.system(size: 11))
                    }
                    Spacer()
                    Text("\(filteredItems.count) items available")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.background.opacity(0.4))
            }
            .frame(width: 580, height: 420)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 24, y: 12)
        }
        .onAppear {
            isFieldFocused = true
            selectedIndex = 0
        }
        .onExitCommand {
            isPresented = false
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredItems.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.return) {
            if !filteredItems.isEmpty && selectedIndex < filteredItems.count {
                filteredItems[selectedIndex].action()
            }
            return .handled
        }
    }
}
