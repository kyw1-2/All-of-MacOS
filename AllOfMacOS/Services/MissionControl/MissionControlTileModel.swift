import Foundation
import CoreGraphics
import AppKit

/// Represents a window tile in the Mission Control / App Exposé view hierarchy.
public struct MissionControlTile: Identifiable, Equatable {
    public let id: String
    public let pid: pid_t
    public let bundleID: String?
    public let windowTitle: String?
    public let frame: CGRect // Screen coordinates in AppKit or AX space
    
    public init(pid: pid_t, bundleID: String? = nil, windowTitle: String? = nil, frame: CGRect) {
        self.id = "\(pid):\(frame.origin.x),\(frame.origin.y)"
        self.pid = pid
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.frame = frame
    }
}
