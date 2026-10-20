import AppKit
import Combine

/// Public, application-scoped Touch Bar adapter. macOS shows these controls
/// while AOM is active; it does not replace other applications' Touch Bars.
@MainActor
final class AOMTouchBar: NSObject, NSTouchBarDelegate {
    static let shared = AOMTouchBar()
    private var observation: AnyCancellable?
    private var menus: [FloatingMenuDefinition] = []
    func start() {
        observation = FloatingMenuStore.shared.$menus.receive(on: DispatchQueue.main).sink { [weak self] menus in
            self?.menus = Array(menus.prefix(8)); self?.rebuild()
        }
    }
    private func rebuild() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.kyw.allofmacos.controls")
        let identifiers = ["clipboard", "capture", "menus"] + menus.map { $0.id.uuidString }
        bar.defaultItemIdentifiers = identifiers.map { NSTouchBarItem.Identifier("com.kyw.allofmacos." + $0) }
        bar.customizationAllowedItemIdentifiers = bar.defaultItemIdentifiers
        NSApp.touchBar = bar
    }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let key = identifier.rawValue.replacingOccurrences(of: "com.kyw.allofmacos.", with: "")
        let title: String
        switch key {
        case "clipboard": title = "Clipboard"
        case "capture": title = "Capture"
        case "menus": title = "Edit Menus"
        default:
            guard let menu = menus.first(where: { $0.id.uuidString == key }) else { return nil }
            title = menu.name
        }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        item.view = button
        return item
    }
    @objc private func pressed(_ button: NSButton) {
        switch button.identifier?.rawValue {
        case "clipboard": ClipboardPanelController.shared.toggle()
        case "capture": CaptureCoordinator.shared.captureAllInOne()
        case "menus": FloatingMenuController.shared.edit()
        case .some(let name): _ = FloatingMenuController.shared.show(name)
        case nil: break
        }
    }
}
