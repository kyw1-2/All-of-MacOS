import Foundation
import AppKit

struct AppTarget: Identifiable, Codable, Hashable {
    let id: UUID
    var bundleID: String?
    var name: String
    var iconPath: String?

    var isGlobal: Bool { bundleID == nil }

    static let allApps = AppTarget(id: UUID(), bundleID: nil, name: "All Apps", iconPath: nil)

}
