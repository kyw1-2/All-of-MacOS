import AppKit
import SwiftUI
import IOKit.ps

struct SystemConditions {
    var batteryPercent: Int?
    var powerSource: String?
    var displayCount: Int

    static func current() -> SystemConditions {
        var result = SystemConditions(displayCount: NSScreen.screens.count)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return result }
        if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            result.powerSource = source == kIOPSACPowerValue ? "ac" : source == kIOPSBatteryPowerValue ? "battery" : nil
        }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                result.batteryPercent = min(100, max(0, current * 100 / maximum))
            }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                result.powerSource = state == kIOPSACPowerValue ? "ac" : state == kIOPSBatteryPowerValue ? "battery" : nil
            }
        }
        return result
    }
    static func matches(_ p: ActionParameters, snapshot: SystemConditions?) -> Bool {
        if let min = p.minimumBatteryPercent, (snapshot?.batteryPercent ?? -1) < min { return false }
        if let max = p.maximumBatteryPercent, (snapshot?.batteryPercent ?? 101) > max { return false }
        if let power = p.powerSource, snapshot?.powerSource != power { return false }
        if let min = p.minimumDisplayCount, (snapshot?.displayCount ?? 0) < min { return false }
        if let max = p.maximumDisplayCount, (snapshot?.displayCount ?? Int.max) > max { return false }
        return true
    }
}

/// Small named string state shared by workflows. Writes are event-driven, not polled.
/// Persist only explicitly configured variables; cap storage to prevent unbounded growth.
enum WorkflowVariables {
    private static let lock = NSLock()
    private static let defaults = TriggerSuppression.defaultsForCurrentProcess(tag: "Variables")
    private static var values: [String: String] = defaults.dictionary(forKey: "AOMWorkflowVariables") as? [String: String] ?? [:]
    static let changed = Notification.Name("AOMWorkflowVariablesChanged")

    static func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
    static func remove(_ name: String) {
        lock.lock()
        let removed = values.removeValue(forKey: name) != nil
        if removed { defaults.set(values, forKey: "AOMWorkflowVariables") }
        lock.unlock()
        if removed { notify() }
    }
    private static func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// BTT's "place variables into string": `{{var:name}}` becomes the
    /// variable's value, so one action's result (a script's output, an image
    /// match, Ask for Input) feeds the next action's text, URL or message.
    /// Unknown names are left exactly as written, and nothing is replaced
    /// without the explicit `var:` prefix, so existing text is unchanged.
    static func interpolate(_ text: String, lookup: (String) -> String? = { value($0) }) -> String {
        guard text.contains("{{var:"), let expression = interpolationExpression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in expression.matches(in: text, range: range).reversed() {
            guard let whole = Range(match.range, in: result), let nameRange = Range(match.range(at: 1), in: text),
                  let replacement = lookup(String(text[nameRange])) else { continue }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }
    private static let interpolationExpression = try? NSRegularExpression(pattern: #"\{\{var:([A-Za-z0-9_]{1,64})\}\}"#)

    /// The action with variables placed into its text-bearing parameters.
    static func interpolated(_ action: TriggerAction, lookup: (String) -> String? = { value($0) }) -> TriggerAction {
        var result = action
        func apply(_ key: WritableKeyPath<ActionParameters, String?>) {
            if let text = result.parameters[keyPath: key], text.contains("{{var:") {
                result.parameters[keyPath: key] = interpolate(text, lookup: lookup)
            }
        }
        apply(\.text); apply(\.url); apply(\.hudText); apply(\.notificationTitle); apply(\.variableValue)
        apply(\.menuPath); apply(\.windowTitleQuery)
        return result
    }

    static func value(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[name]
    }
    @discardableResult
    static func set(_ name: String, value: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, value.count <= 512,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return false }
        lock.lock()
        guard values[name] != nil || values.count < 128 else { lock.unlock(); return false }
        let changed = values[name] != value
        values[name] = value
        defaults.set(values, forKey: "AOMWorkflowVariables")
        lock.unlock()
        if changed { notify() }
        return true
    }
}

/// Evaluates an If/Else action at execution time, independently of its
/// Run Only When filter. Both branches have normal ordering and cancellation.
enum WorkflowBranchCondition {
    /// Operators, in the order the editor lists them. The first six are the
    /// original set and keep their exact meaning (equals is case-sensitive).
    /// `is` / `isNot` compare case-insensitively, and numerically when both sides
    /// are numbers (so "3" is "3.0"). `like` takes `*` and `?` wildcards and must
    /// match the whole text.
    static let operators: [(id: String, title: String)] = [
        ("equals", "equals"), ("notEquals", "does not equal"), ("contains", "contains"),
        ("regex", "matches regex"), ("greater", "is greater than"), ("less", "is less than"),
        ("is", "is"), ("isNot", "is not"), ("notContains", "does not contain"),
        ("beginsWith", "begins with"), ("endsWith", "ends with"), ("like", "is like (* ?)"),
        ("greaterOrEqual", "is at least"), ("lessOrEqual", "is at most")]

    static func wildcardMatches(_ pattern: String, _ source: String) -> Bool {
        // Bounded dynamic programming avoids regex backtracking for patterns
        // such as *a*a*...b. Never accept a truncated prefix as a whole match.
        let patternCharacters = Array(pattern.prefix(257))
        let characters = Array(source.prefix(1025))
        guard patternCharacters.count <= 256, characters.count <= 1024 else { return false }
        let literals = characters.map(String.init)
        var previous = [Bool](repeating: false, count: characters.count + 1)
        previous[0] = true
        for token in patternCharacters {
            let literal = String(token)
            var current = [Bool](repeating: false, count: characters.count + 1)
            current[0] = token == "*" && previous[0]
            for index in characters.indices {
                if token == "*" { current[index + 1] = previous[index + 1] || current[index] }
                else if previous[index] && (token == "?" || literal.caseInsensitiveCompare(literals[index]) == .orderedSame) {
                    current[index + 1] = true
                }
            }
            previous = current
        }
        return previous[characters.count]
    }
    static func compare(_ source: String, with value: String, operation: String) -> Bool {
        func numbers() -> (Double, Double)? {
            guard let a = Double(source.trimmingCharacters(in: .whitespaces)), let b = Double(value.trimmingCharacters(in: .whitespaces)),
                  a.isFinite, b.isFinite else { return nil }
            return (a, b)
        }
        switch operation {
        case "equals": return source == value
        case "notEquals": return source != value
        case "contains": return source.localizedCaseInsensitiveContains(value)
        case "notContains": return !source.localizedCaseInsensitiveContains(value)
        case "regex":
            guard value.count <= 256,
                  let expression = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return false }
            let safeSource = String(source.prefix(1024))
            return expression.firstMatch(in: safeSource, range: NSRange(safeSource.startIndex..., in: safeSource)) != nil
        case "is", "isNot":
            let same = numbers().map { $0 == $1 } ?? (source.caseInsensitiveCompare(value) == .orderedSame)
            return operation == "is" ? same : !same
        case "beginsWith": return !value.isEmpty && source.lowercased().hasPrefix(value.lowercased())
        case "endsWith": return !value.isEmpty && source.lowercased().hasSuffix(value.lowercased())
        case "like": return wildcardMatches(value, source)
        case "greater": return numbers().map { $0 > $1 } ?? false
        case "less": return numbers().map { $0 < $1 } ?? false
        case "greaterOrEqual": return numbers().map { $0 >= $1 } ?? false
        case "lessOrEqual": return numbers().map { $0 <= $1 } ?? false
        default: return false
        }
    }
    static func matches(_ parameters: ActionParameters, app: String, title: String,
                        mouseX: Double, mouseY: Double, variable: (String) -> String?,
                        clipboard: () -> String? = { nil }, appName: String = "") -> Bool {
        let source: String
        switch parameters.conditionKind ?? "variable" {
        case "variable":
            guard let name = parameters.variableName, let result = variable(name) else { return false }
            source = result
        case "app": source = app
        case "appName": source = appName
        case "window": source = title
        case "clipboard": source = clipboard() ?? ""
        case "mouseX": source = String(mouseX)
        case "mouseY": source = String(mouseY)
        default: return false
        }
        return compare(source, with: parameters.conditionValue ?? "", operation: parameters.conditionOperator ?? "equals")
    }
    static func cursorFraction() -> (x: Double, y: Double) {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              screen.frame.width > 0, screen.frame.height > 0 else { return (-1, -1) }
        return (Double((point.x - screen.frame.minX) / screen.frame.width),
                Double((screen.frame.maxY - point.y) / screen.frame.height))
    }
}

/// Monotonic deadlines, no catch-up bursts, and at most one action in flight.
/// Tests inject a clock and drive tick(), without relying on wall-clock scheduling.
final class HoldRepeater {
    private let delay: TimeInterval
    private let interval: TimeInterval
    private let isHeld: () -> Bool
    private let perform: (@escaping (Bool) -> Void) -> Void
    private let now: () -> TimeInterval
    private let automatic: Bool
    private var timer: DispatchSourceTimer?
    private var finish: (() -> Void)?
    private var running = false
    private var started = false
    private var cancelled = false
    private var iteration = 0
    private var next = TimeInterval.infinity
    init(delayMs: Int, intervalMs: Int, isHeld: @escaping () -> Bool,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automatic: Bool = true, perform: @escaping (@escaping (Bool) -> Void) -> Void) {
        delay = Double(max(100, delayMs)) / 1000
        interval = Double(max(50, intervalMs)) / 1000
        self.isHeld = isHeld; self.perform = perform; self.now = now; self.automatic = automatic
    }
    func start(completion: @escaping () -> Void) {
        guard !started, !cancelled else { return }
        started = true; finish = completion
        guard isHeld() else { cancel(); return }
        next = now() + delay
        if automatic {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
        run(first: true)
    }
    func tick() {
        guard started, !cancelled else { return }
        guard isHeld() else { cancel(); return }
        if !running, now() >= next { run(first: false) }
    }
    private func run(first: Bool) {
        guard !cancelled, isHeld() else { cancel(); return }
        running = true; iteration += 1
        let token = iteration
        let startedAt = now()
        // The first repeat is anchored to the original press, subsequent repeats
        // to their start. Slow actions get a full interval after completion.
        if !first { next = startedAt + interval }
        perform { [weak self] ok in
            let complete = { [weak self] in
                guard let self, !self.cancelled, self.running, self.iteration == token else { return }
                self.running = false
                guard ok, self.isHeld() else { self.cancel(); return }
                if self.now() > self.next { self.next = self.now() + self.interval }
            }
            if Thread.isMainThread { complete() } else { DispatchQueue.main.async(execute: complete) }
        }
    }
    func cancel() {
        guard !cancelled else { return }; cancelled = true
        timer?.cancel(); timer = nil
        let callback = finish; finish = nil; callback?()
    }
    deinit { timer?.cancel() }
}

/// Protect the entire residual touch, not just its first click. A short tail
/// covers delayed macOS tap events; the hard limit fails open if frames stop.
struct TipTapClickShield {
    private var device: UInt64?
    private var hardDeadline: TimeInterval = 0
    private var releasedAt: TimeInterval?
    mutating func arm(device: UInt64, now: TimeInterval) {
        self.device = device; hardDeadline = now + 2; releasedAt = nil
    }
    mutating func observe(device: UInt64, count: Int, now: TimeInterval) {
        guard self.device == device, releasedAt == nil, count == 0 else { return }
        releasedAt = now
    }
    func contains(_ now: TimeInterval) -> Bool {
        device != nil && now < min(hardDeadline, releasedAt.map { $0 + 0.35 } ?? hardDeadline)
    }
    mutating func reset() { device = nil; hardDeadline = 0; releasedAt = nil }
}

final class GestureHUD {
    static let shared = GestureHUD()
    private var panel: NSPanel?
    private var sheet: NSPanel?
    private var observer: NSObjectProtocol?
    private var generation = UUID()

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .gestureDidFire, object: nil, queue: .main) { [weak self] notification in
            guard UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true,
                  notification.userInfo?["quiet"] as? Bool != true,
                  let name = notification.userInfo?["name"] as? String else { return }
            let actions = notification.userInfo?["actions"] as? String ?? ""
            self?.show(title: name, detail: actions.isEmpty ? nil : actions)
        }
    }

    private func makePanel(size: NSSize, interactive: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = !interactive
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private static func makeCornerMask(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius)
        NSColor.black.setFill()
        path.fill()
        image.unlockFocus()
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func show(_ text: String) {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = lines.first.map(String.init) ?? text
        let detail = lines.count > 1 ? String(lines[1]) : nil
        show(title: title, detail: detail)
    }

    func show(title: String, detail: String? = nil, icon: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.show(title: title, detail: detail, icon: icon)
            }
            return
        }
        guard NSApp != nil else { return }

        // Apple-style native OSD HUD card: 200 x 160 pt, balanced & ultra-translucent.
        // A detail longer than its one-line badge (an outcome with a reason or
        // an instruction) gets a wider card, several lines and more time;
        // until 3.3.1 about 25 characters of it were visible for 1.1 s.
        let notice = Self.isNotice(detail)
        let size = notice ? NSSize(width: 320, height: 210) : NSSize(width: 200, height: 160)
        let panel = panel ?? makePanel(size: size, interactive: false)
        panel.setContentSize(size)
        self.panel = panel
        let token = UUID()
        generation = token

        // Genuine Apple-native HUD with behind-window frosted glass blur + corner mask to eliminate square artifacts
        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.makeCornerMask(size: size, radius: 20)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 20
        effectView.layer?.masksToBounds = true

        let content = NSHostingView(
            rootView: BTTHUDView(
                title: String(title.prefix(80)),
                detail: detail.map { String($0.prefix(notice ? 320 : 120)) },
                customIcon: icon,
                notice: notice
            )
        )
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        effectView.addSubview(content)
        panel.contentView = effectView

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // Apple-style smooth pop-in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 1.0
        }

        // Auto-dismiss after 1.1 s (a notice: long enough to read) with smooth fade
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration(detail)) { [weak self, weak panel] in
            guard self?.generation == token, let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 0.0
            } completionHandler: {
                if self?.generation == token {
                    panel.orderOut(nil)
                }
            }
        }
    }

    /// A detail that does not fit the one-line badge of the 200 pt card.
    static func isNotice(_ detail: String?) -> Bool { (detail?.count ?? 0) > 30 }

    /// 1.1 s for a gesture badge; a notice stays about as long as it takes
    /// to read (2.5 s plus 1 s per 25 characters, at most 8 s).
    static func displayDuration(_ detail: String?) -> TimeInterval {
        guard isNotice(detail), let detail else { return 1.1 }
        return min(8, 2.5 + Double(min(detail.count, 320)) / 25)
    }

    /// Takes the HUD down immediately, without waiting for its auto-dismiss.
    ///
    /// A capture countdown uses this so the last number is gone before the
    /// selection overlay appears — otherwise the overlay would photograph the HUD.
    func dismiss() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.dismiss() }
            return
        }
        // Bumping the generation invalidates any pending auto-dismiss, so the
        // scheduled fade-out cannot hide a HUD that was shown again since.
        generation = UUID()
        panel?.orderOut(nil)
    }

    func toggleCheatSheet() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.toggleCheatSheet()
            }
            return
        }
        if let sheet, sheet.isVisible {
            sheet.orderOut(nil)
            return
        }
        let size = NSSize(width: 680, height: 520)
        let panel = sheet ?? makePanel(size: size, interactive: true)
        sheet = panel
        let front = ActionExecutor.externalBundleID
        let triggers = ActionExecutor.cheatSheetTriggers()
        panel.contentView = NSHostingView(
            rootView: CheatSheetView(
                triggers: triggers,
                app: front ?? "All Apps",
                close: { [weak panel] in panel?.orderOut(nil) }
            )
        )
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }
}

/// Apple-native translucent frosted glass HUD with vibrant typography and high background legibility.
struct BTTHUDView: View {
    let title: String
    let detail: String?
    var customIcon: String? = nil
    /// Several lines of plain detail instead of the one-line badge.
    var notice = false

    // Translucent glass backing plate: default 15% black keeps the background desktop/video visible
    @AppStorage("AOMHUDBackgroundOpacity") private var backgroundOpacity: Double = 0.06

    init(title: String, detail: String? = nil, customIcon: String? = nil, notice: Bool = false) {
        self.title = title
        self.detail = detail
        self.customIcon = customIcon
        self.notice = notice
    }

    init(text: String) {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        self.title = lines.first.map(String.init) ?? text
        self.detail = lines.count > 1 ? String(lines[1]) : nil
        self.customIcon = nil
    }

    private var iconName: String {
        if let customIcon, !customIcon.isEmpty { return customIcon }
        return Self.resolveIcon(title: title, detail: detail ?? "")
    }

    var body: some View {
        VStack(spacing: 10) {
            // Apple-style SF Symbol
            Image(systemName: iconName)
                .font(.system(size: notice ? 30 : 42, weight: .medium))
                .foregroundStyle(.white)
                .frame(height: notice ? 34 : 48)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1.5)

            // Primary gesture / title
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.60), radius: 2.5, y: 1)
                .padding(.horizontal, 10)

            // Detail: a notice's reason or instruction in full, else the action badge
            if let detail, !detail.isEmpty, notice {
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .padding(.horizontal, 6)
            } else if let detail, !detail.isEmpty {
                HStack(spacing: 4) {
                    Text(detail)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5))
                )
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(min(max(backgroundOpacity, 0.0), 0.25)))
                .overlay {
                    // Top specular highlight
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .overlay {
                    // Apple native glass rim highlight
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    static func resolveIcon(title: String, detail: String) -> String {
        let combined = "\(title) \(detail)".lowercased()

        // Volume / Mute
        if combined.contains("mute") || combined.contains("음소거") { return "speaker.slash.fill" }
        if combined.contains("volume") || combined.contains("음량") || combined.contains("소리") { return "speaker.wave.3.fill" }

        // Brightness
        if combined.contains("bright") || combined.contains("밝기") { return "sun.max.fill" }

        // Media controls
        if combined.contains("play") || combined.contains("pause") || combined.contains("재생") || combined.contains("일시정지") { return "playpause.fill" }
        if combined.contains("next track") || combined.contains("다음") { return "forward.fill" }
        if combined.contains("previous") || combined.contains("이전") { return "backward.fill" }

        // Window management & Snap
        if combined.contains("maximize") || combined.contains("최대화") { return "arrow.up.left.and.arrow.down.right" }
        if combined.contains("minimize") || combined.contains("최소화") { return "minus.rectangle.fill" }
        if combined.contains("snap") || combined.contains("스냅") || combined.contains("tile") || combined.contains("left half") || combined.contains("right half") { return "rectangle.split.2x1.fill" }
        if combined.contains("window") || combined.contains("창") { return "macwindow" }

        // Mission Control & Launchpad
        if combined.contains("mission") || combined.contains("control") || combined.contains("미션") || combined.contains("expose") { return "square.grid.3x3.fill" }
        if combined.contains("desktop") || combined.contains("바탕화면") || combined.contains("space") { return "display.2" }
        if combined.contains("launchpad") || combined.contains("런치패드") || combined.contains("app") { return "apps.ipad" }

        // Screenshot & Lock
        if combined.contains("screenshot") || combined.contains("스크린샷") || combined.contains("캡처") { return "camera.viewfinder" }
        if combined.contains("lock") || combined.contains("잠금") || combined.contains("sleep") || combined.contains("잠자기") { return "lock.fill" }

        // Clipboard
        if combined.contains("copy") || combined.contains("복사") { return "doc.on.doc.fill" }
        if combined.contains("paste") || combined.contains("붙여넣기") { return "doc.on.clipboard.fill" }

        // Directional Swipes
        if combined.contains("swipe") || combined.contains("스와이프") {
            if combined.contains("up") || combined.contains("위") { return "arrow.up" }
            if combined.contains("down") || combined.contains("아래") { return "arrow.down" }
            if combined.contains("left") || combined.contains("왼") { return "arrow.left" }
            if combined.contains("right") || combined.contains("오른") { return "arrow.right" }
            return "hand.draw.fill"
        }

        // Pinch / Zoom / Rotate
        if combined.contains("pinch") || combined.contains("핀치") || combined.contains("zoom") || combined.contains("확대") { return "arrow.up.left.and.down.right.magnifyingglass" }
        if combined.contains("rotate") || combined.contains("회전") { return "rotate.right.fill" }

        // Taps & Clicks
        if combined.contains("tiptap") || combined.contains("팁탭") { return "hand.point.up.left.fill" }
        if combined.contains("double") || combined.contains("더블") { return "hand.tap.fill" }
        if combined.contains("tap") || combined.contains("탭") || combined.contains("click") || combined.contains("클릭") { return "hand.tap.fill" }

        // Keyboard & Shortcuts
        if combined.contains("key") || combined.contains("shortcut") || combined.contains("단축키") || combined.contains("press") { return "command" }

        return "sparkles"
    }
}

typealias CompactHUDView = BTTHUDView

private struct CheatSheetView: View {
    let triggers: [Trigger]
    let app: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "command.square.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AOM Cheat Sheet")
                            .font(.headline.bold())
                        Text("Scope: \(app)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)

            Divider()

            // Triggers list
            if triggers.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "hand.tap")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No configured triggers for \(app)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(triggers) { trigger in
                            HStack(spacing: 12) {
                                // Trigger icon & name
                                HStack(spacing: 8) {
                                    Image(systemName: triggerIcon(for: trigger))
                                        .font(.system(size: 14))
                                        .foregroundColor(.accentColor)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(trigger.input.displayName)
                                            .font(.system(size: 13, weight: .semibold))
                                        if trigger.input.category == .keyboard {
                                            Text(trigger.keyboardPhase.rawValue)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        } else if !trigger.modifierLabel.isEmpty {
                                            Text(trigger.modifierLabel)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .frame(width: 200, alignment: .leading)

                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.6))

                                // Actions
                                HStack(spacing: 6) {
                                    ForEach(Array(trigger.actions.filter(\.isEnabled).enumerated()), id: \.offset) { idx, action in
                                        if idx > 0 {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                        Text(action.displayName)
                                            .font(.system(size: 11, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color.primary.opacity(0.08))
                                            )
                                    }
                                }

                                Spacer()

                                // App badge
                                Text(trigger.appBundleID ?? "All Apps")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func triggerIcon(for trigger: Trigger) -> String {
        trigger.input.category.iconName
    }
}

/// Structural comparisons avoid tearing down unrelated event taps on every save.
struct MonitorBindings: Equatable {
    var triggers: [Trigger]
    var groups: [ActivationGroup]
    init(_ triggers: [Trigger], groups: [ActivationGroup], category: TriggerCategory? = nil) {
        self.triggers = triggers.filter { category == nil || $0.input.category == category }.map {
            var runtime = $0; runtime.isFavorite = false; return runtime
        }
        let ids = Set(self.triggers.compactMap(\.activationGroupID))
        self.groups = groups.filter { ids.contains($0.id) || $0.disableGlobalTriggers }
    }
}
struct SnapMonitorSettings: Equatable {
    var zones: [CustomSnapZone]
    var requiresOption: Bool
    var showsPreview: Bool
    var displayIDs: [String]
}

/// A process-lifetime lease prevents installed and development copies from
/// both observing hardware. Kernel cleanup also releases it after a crash.
final class SingleInstanceLease {
    private let descriptor: Int32
    init?(path: String) {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
