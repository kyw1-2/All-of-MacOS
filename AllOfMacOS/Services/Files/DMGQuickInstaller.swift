import Foundation

/// Finder Open With > All of MacOS forwards a DMG to the existing,
/// tested Folder Rules disk-image installer. It mounts read-only, handles
/// license/encryption checks and confirmation before any app replacement.
@MainActor
enum DMGQuickInstaller {
    static func open(_ image: URL) {
        guard image.isFileURL, image.pathExtension.lowercased() == "dmg" else { return }
        FolderRulesEngine.shared.installDiskImage(image,
            trashAfter: UserDefaults.standard.bool(forKey: "AOMDiskImageTrashOnSuccess"))
    }
}
