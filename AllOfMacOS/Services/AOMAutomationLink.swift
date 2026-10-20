import Foundation

enum AOMAutomationLink: Equatable {
    case trigger(String), showMenu(String), editMenus, hideMenus
    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "aom",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        let items = parts.queryItems ?? []
        switch parts.host?.lowercased() {
        case "trigger", "trigger_named", "show-menu":
            guard items.count == 1, let item = items.first,
                  item.name == "name" || (parts.host == "trigger_named" && item.name == "trigger_name"),
                  let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= 128 else { return nil }
            return parts.host?.lowercased() == "show-menu" ? .showMenu(value) : .trigger(value)
        case "edit-menus" where items.isEmpty: return .editMenus
        case "hide-menus" where items.isEmpty: return .hideMenus
        default: return nil
        }
    }
}
