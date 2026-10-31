import Foundation

/// A ready-made rule. One click adds it to its folder, switched off, where it
/// can be edited like any other rule.
struct FolderRuleTemplate: Identifiable {
    enum Folder { case downloads, desktop, screenshots }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let folder: Folder
    let make: (_ folderID: UUID) -> FolderRule

    var folderURL: URL {
        switch folder {
        case .downloads: return FolderRulesLocations.downloads
        case .desktop: return FolderRulesLocations.desktop
        case .screenshots: return FolderRulesLocations.screenshots
        }
    }
}

enum FolderRuleTemplates {
    static let all: [FolderRuleTemplate] = [
        FolderRuleTemplate(
            id: "old-installers", title: "Clear Out Old Installers",
            detail: "Disk images and installer packages in Downloads go to the Trash after 3 days.",
            symbol: "externaldrive.badge.xmark", folder: .downloads) { folder in
            FolderRule(folderID: folder, name: "Clear out old installers",
                       conditions: [.fileExtension(.is, ["dmg", "pkg", "mpkg"]),
                                    .date(.dateAdded, .olderThan, 3, .days)],
                       actions: [.moveToTrash], templateID: "old-installers")
        },
        FolderRuleTemplate(
            id: "file-screenshots", title: "File Screenshots by Month",
            detail: "Screenshots on the Desktop move to Pictures › Screenshots › year-month.",
            symbol: "camera.viewfinder", folder: .desktop) { folder in
            FolderRule(folderID: folder, name: "File screenshots by month",
                       conditions: [.kind(.screenshot)],
                       actions: [.move(to: FolderRulesLocations.pictures.path, subfolders: "Screenshots/{year}-{month}")],
                       templateID: "file-screenshots")
        },
        FolderRuleTemplate(
            id: "receipts", title: "File Receipts and Invoices",
            detail: "PDFs named invoice, receipt, 영수증 or 청구서 move to Documents › Receipts, tagged Receipt.",
            symbol: "doc.text.magnifyingglass", folder: .downloads) { folder in
            FolderRule(folderID: folder, name: "File receipts and invoices",
                       conditions: [.kind(.pdf), .name(.contains, ["invoice", "receipt", "영수증", "청구서"])],
                       actions: [.move(to: FolderRulesLocations.documents.path, subfolders: "Receipts"), .addTags(["Receipt"])],
                       templateID: "receipts")
        },
        FolderRuleTemplate(
            id: "archive-downloads", title: "Archive Old Downloads",
            detail: "Downloads older than 30 days move to Downloads › Archive › year-month.",
            symbol: "archivebox", folder: .downloads) { folder in
            FolderRule(folderID: folder, name: "Archive old downloads",
                       conditions: [.date(.dateAdded, .olderThan, 30, .days), .name(.isNot, ["Archive"])],
                       actions: [.move(to: FolderRulesLocations.downloads.path, subfolders: "Archive/{year}-{month}")],
                       templateID: "archive-downloads")
        },
        FolderRuleTemplate(
            id: "optimize-screenshots", title: "Optimize New Screenshots",
            detail: "New screenshots become smaller JPEGs; the original PNG goes to the Trash.",
            symbol: "photo.badge.checkmark", folder: .screenshots) { folder in
            var optimize = FolderRuleAction(kind: .optimizeImage)
            optimize.image = FolderRuleImageOptions(maxDimension: 3840, quality: 0.85, stripLocation: true,
                                                    screenshotOutput: .jpeg, original: .trash)
            return FolderRule(folderID: folder, name: "Optimize new screenshots",
                              conditions: [.kind(.screenshot), .date(.dateAdded, .newerThan, 1, .days)],
                              actions: [optimize], templateID: "optimize-screenshots")
        },
        FolderRuleTemplate(
            id: "install-disk-images", title: "Install Apps from Disk Images",
            detail: "Offers to install the app from each new disk image in Downloads, then moves the image to the Trash.",
            symbol: "externaldrive.badge.plus", folder: .downloads) { folder in
            FolderRule(folderID: folder, name: "Install apps from disk images",
                       conditions: [.kind(.diskImage), .date(.dateAdded, .newerThan, 1, .days)],
                       actions: [FolderRuleAction(kind: .installApp)], templateID: "install-disk-images")
        }
    ]

    static func template(_ id: String) -> FolderRuleTemplate? { all.first { $0.id == id } }
}
