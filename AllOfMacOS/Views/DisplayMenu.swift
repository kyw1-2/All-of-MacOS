import AppKit
import SwiftUI

/// Always-available display control in the menu bar, following BetterDisplay's
/// app menu: one section per display, each carrying its own brightness and
/// resolution sliders, a High Resolution toggle, and the mode submenus.
///
/// This is deliberately not an action. Brightness and resolution are settings
/// reached for directly, not gestures bound once and forgotten, so they live in
/// the status menu rather than the action list.
///
/// The menu is rebuilt on every open, so it always reflects the displays
/// connected right now and the modes they currently offer. Nothing here is
/// cached between opens.
@MainActor
enum DisplayMenu {

    /// Builds the display section for the status menu, or nil when no display
    /// can be controlled, so the menu can omit the section entirely.
    static func build() -> NSMenuItem? {
        let displays = DisplayControlService.displays()
        guard !displays.isEmpty else { return nil }

        let section = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for (index, display) in displays.enumerated() {
            if index > 0 { submenu.addItem(.separator()) }
            submenu.addItem(displayHeader(display))
            if let mainDisplay = setMainDisplayItem(display) { submenu.addItem(mainDisplay) }
            submenu.addItem(brightnessItem(display))
            if let resolution = resolutionItem(display) { submenu.addItem(resolution) }
            if let toggle = hiDPIToggleItem(display) { submenu.addItem(toggle) }
            if let refresh = refreshRateItem(display) { submenu.addItem(refresh) }
            if let modes = displayModeItem(display) { submenu.addItem(modes) }
            submenu.addItem(modeStatusItem(display))
        }

        section.submenu = submenu
        section.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        return section
    }

    // MARK: - Main Display Selection

    private static func setMainDisplayItem(_ display: DisplayTarget) -> NSMenuItem? {
        guard DisplayControlService.displays().count > 1 else { return nil }
        let isMain = CGDisplayIsMain(display.displayID) != 0
        let item = NSMenuItem(
            title: isMain ? "Main Display" : "Use as Main Display",
            action: isMain ? nil : #selector(DisplayMenuAction.setMainDisplay(_:)),
            keyEquivalent: ""
        )
        item.target = DisplayMenuAction.shared
        item.representedObject = display.displayID
        item.state = isMain ? .on : .off
        item.isEnabled = !isMain
        item.image = NSImage(systemSymbolName: isMain ? "star.fill" : "star", accessibilityDescription: nil)
        return item
    }

    // MARK: - Header

    /// The device header. BetterDisplay marks the main display with an "M", so
    /// a multi-display menu says which one owns the menu bar without being
    /// opened. A single-display menu needs no marker to disambiguate.
    private static func displayHeader(_ display: DisplayTarget) -> NSMenuItem {
        let isMain = CGDisplayIsMain(display.displayID) != 0
        let multiple = DisplayControlService.displays().count > 1
        let suffix = (isMain && multiple) ? "  (M)" : ""
        let item = NSMenuItem(title: display.name + suffix, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(
            systemSymbolName: display.isBuiltIn ? "laptopcomputer" : "display",
            accessibilityDescription: nil
        )
        item.view = DisplayHeaderView(display: display, isMain: isMain, multiple: multiple)
        return item
    }

    // MARK: - Brightness

    /// A live slider rather than a pair of up/down commands, so a level can be
    /// picked directly. The label names the control method because the two are
    /// not equivalent: a hardware slider moves the backlight, a software one
    /// only scales the image.
    ///
    /// Built from AppKit rather than SwiftUI. A SwiftUI `Slider` inside a menu
    /// competes with the menu for the mouse and needs a hosting view that is
    /// laid out on every open; the native control tracks the drag reliably and
    /// keeps its value while the menu stays open.
    private static func brightnessItem(_ display: DisplayTarget) -> NSMenuItem {
        let hardware = DisplayControlService.supportsHardwareBrightness(display.displayID)
        let current = DisplayControlService.brightness(display.displayID) ?? 0.5
        let control = BrightnessControlView(
            title: hardware ? "Brightness" : "Brightness (software)",
            hardware: hardware,
            value: Double(current),
            onChange: { value in
                _ = DisplayControlService.setBrightness(display.displayID, Float(value))
            }
        )
        let item = NSMenuItem()
        item.view = control
        return item
    }

    // MARK: - Resolution

    /// The resolution slider. BetterDisplay's version waits for the knob to be
    /// released before requesting a mode, so a drag across the range does not
    /// reconfigure the display at every step; this keeps that behavior.
    ///
    /// Omitted when the display offers only one size, or when its current mode
    /// cannot be returned to — see `canReturnToCurrentMode`.
    private static func resolutionItem(_ display: DisplayTarget) -> NSMenuItem? {
        let current = DisplayControlService.currentMode(display.displayID)
        // Keep the active backing scale while moving between sizes, so the
        // slider does not silently switch a HiDPI desktop to LoDPI.
        let options = DisplayControlService.resolutionOptions(display.displayID,
                                                              preferringHiDPI: current?.isHiDPI)
        guard options.count > 1 else { return nil }

        let selectable = DisplayControlService.canReturnToCurrentMode(display.displayID)
        let defaultMode = DisplayControlService.defaultMode(display.displayID)

        let view = ResolutionSliderView(
            options: options,
            current: current,
            defaultMode: defaultMode,
            enabled: selectable,
            onCommit: { option in
                _ = DisplayControlService.setMode(display.displayID,
                                                  pointWidth: option.pointWidth,
                                                  pointHeight: option.pointHeight,
                                                  refreshRate: option.refreshRate,
                                                  hiDPI: option.isHiDPI)
            }
        )
        let item = NSMenuItem()
        item.view = NSHostingView(rootView: view)

        guard !selectable else { return item }

        // A display whose current mode is hidden cannot be returned to, so a
        // change would strand it. The slider stays visible but inert, and the
        // reason is stated rather than left to a greyed-out control.
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let warning = NSMenuItem(title: "macOS hides the current mode — changing it cannot be undone from here",
                                 action: nil, keyEquivalent: "")
        warning.isEnabled = false
        submenu.addItem(warning)
        item.submenu = submenu
        return item
    }

    // MARK: - High Resolution

    /// BetterDisplay's High Resolution toggle: switch to the opposite backing
    /// scale at the same point size, holding the desktop's workspace while the
    /// sharpness changes. Omitted when the size has only one scale.
    private static func hiDPIToggleItem(_ display: DisplayTarget) -> NSMenuItem? {
        guard let current = DisplayControlService.currentMode(display.displayID),
              DisplayControlService.canToggleHiDPI(display.displayID) else { return nil }
        let item = NSMenuItem(title: "High Resolution (HiDPI)",
                              action: #selector(DisplayMenuAction.toggleHiDPI(_:)),
                              keyEquivalent: "")
        item.target = DisplayMenuAction.shared
        item.representedObject = HiDPIRequest(displayID: display.displayID, enable: !current.isHiDPI)
        item.state = current.isHiDPI ? .on : .off
        item.isEnabled = DisplayControlService.canReturnToCurrentMode(display.displayID)
        return item
    }

    // MARK: - Refresh rate

    private static func refreshRateItem(_ display: DisplayTarget) -> NSMenuItem? {
        guard let current = DisplayControlService.currentMode(display.displayID) else { return nil }
        let rates = DisplayControlService.refreshRates(display.displayID,
                                                       pointWidth: current.pointWidth,
                                                       pointHeight: current.pointHeight,
                                                       hiDPI: current.isHiDPI)
        guard rates.count > 1 else { return nil }
        let item = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selectable = DisplayControlService.canReturnToCurrentMode(display.displayID)
        for hz in rates {
            let entry = NSMenuItem(title: "\(Int(hz)) Hz",
                                   action: #selector(DisplayMenuAction.setRefreshRate(_:)),
                                   keyEquivalent: "")
            entry.target = DisplayMenuAction.shared
            entry.representedObject = RefreshRequest(displayID: display.displayID, rate: hz)
            if abs(hz - current.refreshRate) < 0.5 { entry.state = .on }
            entry.isEnabled = selectable
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    // MARK: - Display mode

    /// The full mode list, which BetterDisplay keeps separate from the slider
    /// because it is where an unusual combination is reached: a size at a
    /// backing scale the slider collapsed away, or a rate it does not offer.
    ///
    /// Unlike the slider this shows both scales, so it is the only place a
    /// LoDPI mode at a size the slider resolved to HiDPI can be picked.
    private static func displayModeItem(_ display: DisplayTarget) -> NSMenuItem? {
        let all = DisplayControlService.modes(display.displayID)
        guard all.count > 1 else { return nil }
        guard let current = DisplayControlService.currentMode(display.displayID) else { return nil }

        let item = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selectable = DisplayControlService.canReturnToCurrentMode(display.displayID)

        // Grouped by point size, so the two scales of one size sit together
        // rather than being separated by every other size.
        let grouped = Dictionary(grouping: all) { "\($0.pointWidth)x\($0.pointHeight)" }
        let sizes = grouped.keys.sorted {
            let a = grouped[$0]![0], b = grouped[$1]![0]
            return a.pointWidth != b.pointWidth ? a.pointWidth < b.pointWidth
                                                : a.pointHeight < b.pointHeight
        }

        for (index, key) in sizes.enumerated() {
            if index > 0 { submenu.addItem(.separator()) }
            let entries = grouped[key]!.sorted {
                $0.isHiDPI != $1.isHiDPI ? !$0.isHiDPI : $0.refreshRate < $1.refreshRate
            }
            for option in entries {
                let entry = NSMenuItem(title: option.label,
                                       action: #selector(DisplayMenuAction.setResolution(_:)),
                                       keyEquivalent: "")
                entry.target = DisplayMenuAction.shared
                entry.representedObject = ResolutionRequest(displayID: display.displayID, option: option)
                if option.matches(current) { entry.state = .on }
                entry.isEnabled = selectable
                submenu.addItem(entry)
            }
        }

        item.submenu = submenu
        return item
    }

    // MARK: - Status

    private static func modeStatusItem(_ display: DisplayTarget) -> NSMenuItem {
        let current = DisplayControlService.currentMode(display.displayID)
        let detail = current.map { mode -> String in
            let scale = mode.isHiDPI ? " (HiDPI)" : ""
            return "Active: \(mode.pointWidth) × \(mode.pointHeight)\(scale) @ \(Int(mode.refreshRate)) Hz"
        } ?? "Mode unavailable"
        let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        return item
    }
}

// MARK: - Actions

/// Target for the menu's dynamic items. `representedObject` carries the display
/// and value, because NSMenuItem selectors cannot take arguments.
@MainActor
final class DisplayMenuAction: NSObject {
    static let shared = DisplayMenuAction()

    @objc func setResolution(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ResolutionRequest else { return }
        let option = request.option
        _ = DisplayControlService.setMode(request.displayID,
                                          pointWidth: option.pointWidth,
                                          pointHeight: option.pointHeight,
                                          refreshRate: option.refreshRate,
                                          hiDPI: option.isHiDPI)
    }

    @objc func setRefreshRate(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? RefreshRequest,
              let current = DisplayControlService.currentMode(request.displayID) else { return }
        _ = DisplayControlService.setMode(request.displayID,
                                          pointWidth: current.pointWidth,
                                          pointHeight: current.pointHeight,
                                          refreshRate: request.rate,
                                          hiDPI: current.isHiDPI)
    }

    @objc func toggleHiDPI(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? HiDPIRequest else { return }
        _ = DisplayControlService.setHiDPI(request.displayID, request.enable)
    }

    @objc func setMainDisplay(_ sender: NSMenuItem) {
        guard let displayID = sender.representedObject as? CGDirectDisplayID else { return }
        _ = DisplayControlService.setMainDisplay(displayID)
    }
}

/// Menu items are recreated on every open, so these are plain value carriers
/// rather than retained state.
final class ResolutionRequest: NSObject {
    let displayID: CGDirectDisplayID
    let option: DisplayModeOption
    init(displayID: CGDirectDisplayID, option: DisplayModeOption) {
        self.displayID = displayID; self.option = option
    }
}

final class RefreshRequest: NSObject {
    let displayID: CGDirectDisplayID
    let rate: Double
    init(displayID: CGDirectDisplayID, rate: Double) {
        self.displayID = displayID; self.rate = rate
    }
}

final class HiDPIRequest: NSObject {
    let displayID: CGDirectDisplayID
    let enable: Bool
    init(displayID: CGDirectDisplayID, enable: Bool) {
        self.displayID = displayID; self.enable = enable
    }
}

// MARK: - Views

/// Apple-native device header card displaying display identity and Main status.
final class DisplayHeaderView: NSView {
    init(display: DisplayTarget, isMain: Bool, multiple: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 32))
        build(display: display, isMain: isMain, multiple: multiple)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    private func build(display: DisplayTarget, isMain: Bool, multiple: Bool) {
        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: display.isBuiltIn ? "laptopcomputer" : "display",
            accessibilityDescription: nil
        )
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: display.name)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        var trailingConstraint = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)

        if isMain && multiple {
            let badge = NSTextField(labelWithString: "MAIN")
            badge.font = .systemFont(ofSize: 9, weight: .bold)
            badge.textColor = .controlAccentColor
            badge.alignment = .center
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            addSubview(badge)

            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 42),
                badge.heightAnchor.constraint(equalToConstant: 16),
            ])
            trailingConstraint = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingConstraint
        ])
    }
}

/// Control Center-style 2-row brightness control: clean typography and full-width slider.
final class BrightnessControlView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let readoutLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let onChange: (Double) -> Void

    init(title: String, hardware: Bool, value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
        build(title: title, hardware: hardware, value: value)
    }

    required init?(coder: NSCoder) {
        self.onChange = { _ in }
        super.init(coder: coder)
    }

    private func build(title: String, hardware: Bool, value: Double) {
        let clamped = min(1, max(0, value))

        // 1. Icon
        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: hardware ? "sun.max.fill" : "sun.min.fill",
            accessibilityDescription: title
        )
        iconView.contentTintColor = hardware ? .controlAccentColor : .systemOrange
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // 2. Title Label (Crisp primary label)
        titleLabel.stringValue = "Brightness"
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 3. Method Badge (Hardware / Software)
        badgeLabel.stringValue = hardware ? "Hardware" : "Software"
        badgeLabel.font = .systemFont(ofSize: 9, weight: .medium)
        badgeLabel.textColor = hardware ? .secondaryLabelColor : .systemOrange
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 3
        badgeLabel.layer?.backgroundColor = (hardware
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            : NSColor.systemOrange.withAlphaComponent(0.15)).cgColor
        addSubview(badgeLabel)

        // 4. Percentage Readout (Sharp monospaced digits)
        readoutLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        readoutLabel.textColor = .labelColor
        readoutLabel.alignment = .right
        readoutLabel.stringValue = "\(Int((clamped * 100).rounded()))%"
        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(readoutLabel)

        // 5. Slider
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = clamped
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        NSLayoutConstraint.activate([
            // Top Row
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            badgeLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            badgeLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            badgeLabel.widthAnchor.constraint(equalToConstant: hardware ? 54 : 52),
            badgeLabel.heightAnchor.constraint(equalToConstant: 14),

            readoutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            readoutLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            readoutLabel.widthAnchor.constraint(equalToConstant: 44),

            // Bottom Row (Full width slider)
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            slider.heightAnchor.constraint(equalToConstant: 16),
        ])

        toolTip = hardware
            ? "Adjusts the panel backlight directly (DDC/CI)."
            : "This display has no backlight control; brightness is applied via software gamma."
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let value = sender.doubleValue
        readoutLabel.stringValue = "\(Int((value * 100).rounded()))%"
        onChange(value)
    }
}

/// Clean Apple-style resolution slider card with crisp mode labels and HiDPI badge.
struct ResolutionSliderView: View {
    let options: [DisplayModeOption]
    let current: DisplayModeOption?
    let defaultMode: DisplayModeOption?
    let enabled: Bool
    let onCommit: (DisplayModeOption) -> Void

    @State private var index: Double

    init(options: [DisplayModeOption],
         current: DisplayModeOption?,
         defaultMode: DisplayModeOption?,
         enabled: Bool,
         onCommit: @escaping (DisplayModeOption) -> Void) {
        self.options = options
        self.current = current
        self.defaultMode = defaultMode
        self.enabled = enabled
        self.onCommit = onCommit
        let start = options.firstIndex { option in
            guard let current else { return false }
            return option.matchesSize(current)
        } ?? 0
        _index = State(initialValue: Double(start))
    }

    private var selected: DisplayModeOption? {
        let i = Int(index.rounded())
        guard options.indices.contains(i) else { return nil }
        return options[i]
    }

    private var percentage: Int? {
        guard let selected, let defaultMode, defaultMode.pointWidth > 0 else { return nil }
        return Int((Double(selected.pointWidth) / Double(defaultMode.pointWidth) * 100).rounded())
    }

    private var isDefault: Bool {
        guard let selected, let defaultMode else { return false }
        return selected.matchesSize(defaultMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: Icon + Dimensions + Badges
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)

                if let selected {
                    Text("\(selected.pointWidth) × \(selected.pointHeight)")
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundStyle(Color(nsColor: .labelColor))

                    if selected.isHiDPI {
                        Text("HiDPI")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor))
                    }

                    if isDefault {
                        Text("Default")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    } else if let percentage {
                        Text("\(percentage)%")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
                Spacer()
            }

            // Slider track
            Slider(value: $index, in: 0...Double(max(0, options.count - 1)), step: 1) { editing in
                if !editing, let selected { onCommit(selected) }
            }
            .disabled(!enabled)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 280)
        .help(enabled
              ? "Drag to a size; the mode is applied when you release"
              : "The current mode is hidden by macOS, so changing it cannot be undone from here")
    }
}
