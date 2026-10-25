import Foundation

/// User preferences for Mission Control Plus feature parity in AOM.
public final class MissionControlConfiguration: ObservableObject {
    public static let shared = MissionControlConfiguration()

    @Published public var showCloseButtons: Bool {
        didSet { UserDefaults.standard.set(showCloseButtons, forKey: "AOMMissionControlButtons") }
    }

    @Published public var enableHotkeys: Bool {
        didSet { UserDefaults.standard.set(enableHotkeys, forKey: "AOMMissionControlHotkeys") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.showCloseButtons = defaults.object(forKey: "AOMMissionControlButtons") as? Bool ?? true
        self.enableHotkeys = defaults.object(forKey: "AOMMissionControlHotkeys") as? Bool ?? true
    }
}
