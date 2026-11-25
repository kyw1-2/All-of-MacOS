import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Synthetic, in-memory data for the screenshot matrix only.
enum AOMWorkbenchPreviewData {
    static var enabled: Bool {
        PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-preview-sample-data")
    }

    static func clipboard() -> (entries: [ClipboardEntry], boards: [ClipboardPinboard]) {
        let work = ClipboardPinboard(name: "Project Notes", color: "blue")
        let snippets = ClipboardPinboard(name: "모아둔 문구", color: "green")
        let now = Date()
        let strings: [(String, String, String, UUID?)] = [
            ("Release checklist\n\n• Review compact and split layouts\n• Check keyboard navigation\n• Confirm light and dark appearance", "Notes", "com.apple.Notes", work.id),
            ("회의 메모\n다음 검토에서는 검색과 키보드 이동을 확인합니다.", "Notes", "com.apple.Notes", work.id),
            ("https://developer.apple.com/design/human-interface-guidelines/", "Safari", "com.apple.Safari", work.id),
            ("#56796D", "Digital Color Meter", "com.apple.DigitalColorMeter", snippets.id),
            ("다음 주에 다시 확인할 항목", "TextEdit", "com.apple.TextEdit", snippets.id),
            ("https://example.com/workbench", "Safari", "com.apple.Safari", nil),
            ("A little room for the things you use every day.", "TextEdit", "com.apple.TextEdit", snippets.id),
            ("Reusable welcome message", "Notes", "com.apple.Notes", snippets.id),
            ("도구 모음에서 보기 옵션을 엽니다.", "Notes", "com.apple.Notes", nil),
            ("Bring the current window to the left half.", "TextEdit", "com.apple.TextEdit", nil),
            ("Afternoon review agenda", "Notes", "com.apple.Notes", work.id),
            ("https://example.org/notes", "Safari", "com.apple.Safari", nil),
            ("발표 순서 확인", "TextEdit", "com.apple.TextEdit", nil)
        ]
        var entries = strings.enumerated().map { index, sample in
            var entry = ClipboardEntry.captured(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(sample.0.utf8)]],
                sourceName: sample.1, sourceBundleID: sample.2, at: now.addingTimeInterval(-Double(index) * 410))
            if let board = sample.3 { entry.pinboardIDs.insert(board) }
            return entry
        }
        if let png = samplePNG() {
            entries.insert(ClipboardEntry(title: "Color study", kind: .image, sourceName: "Preview",
                sourceBundleID: "com.apple.Preview", createdAt: now.addingTimeInterval(-1025), pinboardIDs: [work.id],
                items: [[NSPasteboard.PasteboardType.png.rawValue: png]]), at: 3)
        }
        let file = URL(fileURLWithPath: "/Preview/Release checklist.pdf")
        entries.insert(ClipboardEntry(title: file.lastPathComponent, kind: .file, sourceName: "Finder",
            sourceBundleID: "com.apple.finder", createdAt: now.addingTimeInterval(-1845), pinboardIDs: [work.id],
            items: [[NSPasteboard.PasteboardType.fileURL.rawValue: Data(file.absoluteString.utf8)]]), at: 6)
        return (entries, [work, snippets])
    }

    private static func samplePNG() -> Data? {
        guard let context = CGContext(data: nil, width: 480, height: 270, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 0.92, green: 0.91, blue: 0.86, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 270))
        context.setFillColor(red: 0.34, green: 0.47, blue: 0.43, alpha: 1)
        context.fillEllipse(in: CGRect(x: 87, y: 43, width: 182, height: 182))
        context.setFillColor(red: 0.71, green: 0.43, blue: 0.34, alpha: 1)
        context.fillEllipse(in: CGRect(x: 230, y: 61, width: 148, height: 148))
        let bytes = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }

    static func automations() -> [Trigger] {
        func hud(_ message: String) -> TriggerAction {
            var action = TriggerAction(actionType: .showHUD)
            action.parameters.hudText = message
            return action
        }
        func make(_ name: String, _ input: TriggerInput, _ actions: [TriggerAction], enabled: Bool = true) -> Trigger {
            var trigger = Trigger(name: name, input: input)
            trigger.actions = actions
            trigger.isEnabled = enabled
            return trigger
        }
        var branch = TriggerAction(actionType: .ifElse)
        branch.parameters.conditionKind = "appName"
        branch.parameters.conditionValue = "Finder"
        branch.parameters.children = [TriggerAction(actionType: .moveWindowLeft), hud("Window aligned")]
        branch.parameters.elseChildren = [TriggerAction(actionType: .maximizeWindow)]
        var wait = TriggerAction(actionType: .wait)
        wait.parameters.waitMs = 250
        var first = make("Tidy the front window", .trackpadGesture(.threeFingerSwipeLeft), [branch, wait, hud("Ready")])
        first.isFavorite = true
        return [first,
                make("집중 작업 준비", .keyboardShortcut(KeyboardShortcut(keyCode: 3, modifiers: [.command, .option])),
                     [TriggerAction(actionType: .maximizeWindow), hud("집중 작업")]),
                make("Mark a review break", .mouseButton(.button4), [wait, hud("Take a break")]),
                make("Draw a quick note", .drawingPattern("Loop"), [hud("New note"), wait], enabled: false),
                make("Review workspace", .namedTrigger("Review"), [TriggerAction(actionType: .moveWindowLeft), hud("Review")]),
                make("Restore a larger window", .trackpadGesture(.fourFingerPinchOut), [TriggerAction(actionType: .maximizeWindow), hud("Maximized")])]
    }
}
