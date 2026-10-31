import Darwin
import Foundation
import UniformTypeIdentifiers

/// What a rule can see about one item: a plain value, so matching and
/// planning are pure and unit tested with fixtures.
struct FolderRuleFileInfo: Equatable {
    var url: URL
    /// The full name on disk ("Report.pdf").
    var name: String
    var isDirectory = false
    var isPackage = false
    /// The UTType identifier ("com.adobe.pdf"), nil when macOS doesn't know it.
    var contentType: String?
    /// macOS marks screenshots with `kMDItemIsScreenCapture`.
    var isScreenCapture = false
    /// Bytes; for folders and packages the total of their contents.
    var size: Int64 = 0
    var dateAdded: Date?
    var dateCreated: Date?
    var dateModified: Date?
    var dateLastOpened: Date?
    /// `kMDItemWhereFroms`: the download URL and the page it came from.
    var whereFroms: [String] = []
    var tags: [String] = []
    var device: UInt64 = 0
    var inode: UInt64 = 0
    /// 0 for items at the top level of the watched folder.
    var depth = 0

    init(url: URL, name: String? = nil, isDirectory: Bool = false, isPackage: Bool = false,
         contentType: String? = nil, isScreenCapture: Bool = false, size: Int64 = 0,
         dateAdded: Date? = nil, dateCreated: Date? = nil, dateModified: Date? = nil, dateLastOpened: Date? = nil,
         whereFroms: [String] = [], tags: [String] = [], device: UInt64 = 0, inode: UInt64 = 0, depth: Int = 0) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.contentType = contentType
            ?? (isDirectory && !isPackage ? Optional(UTType.folder.identifier) : UTType(filenameExtension: url.pathExtension)?.identifier)
        self.isScreenCapture = isScreenCapture
        self.size = size
        self.dateAdded = dateAdded
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.dateLastOpened = dateLastOpened
        self.whereFroms = whereFroms
        self.tags = tags
        self.device = device
        self.inode = inode
        self.depth = depth
    }

    /// The name without its extension ("Report"). Folders keep their whole
    /// name; packages (apps, bundles) drop the extension like files.
    var baseName: String {
        guard !(isDirectory && !isPackage) else { return name }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? name : String((name as NSString).deletingPathExtension)
    }

    /// The extension as written on disk, without the dot ("PDF" stays "PDF").
    var fileExtension: String {
        guard !(isDirectory && !isPackage) else { return "" }
        return (name as NSString).pathExtension
    }

    /// The date `{year}`, `{month}`, `{day}` and `{date:…}` use: when the item
    /// arrived in its folder, else when it was created, else when modified.
    var referenceDate: Date? { dateAdded ?? dateCreated ?? dateModified }

    /// Hosts of the download (`kMDItemWhereFroms`), lower-cased.
    var downloadHosts: [String] { FolderRuleMetadata.hosts(from: whereFroms) }

    /// Every kind the item belongs to (a screenshot is also an image, a PDF
    /// is also a document).
    var kinds: Set<FolderRuleKind> { FolderRuleKinds.kinds(contentType: contentType, fileExtension: fileExtension,
                                                           isDirectory: isDirectory, isPackage: isPackage,
                                                           isScreenCapture: isScreenCapture) }

    /// The one kind `{kind}` names, most specific first.
    var primaryKind: FolderRuleKind? {
        let kinds = self.kinds
        return FolderRuleKinds.precedence.first { kinds.contains($0) }
    }
}

enum FolderRuleKinds {
    /// Most specific first: an app is never sorted as a folder, a disk image
    /// never as an archive, a screenshot before an image, a PDF before a document.
    static let precedence: [FolderRuleKind] = [.application, .folder, .diskImage, .installerPackage, .archive, .pdf,
                                                .screenshot, .image, .movie, .audio, .document]

    private static let installerPackage = UTType("com.apple.installer-package-archive")
    private static let sourceCode = UTType("public.source-code")
    // Formats macOS has no type for out of the box.
    private static let archiveExtensions: Set<String> = ["rar", "xz", "zst", "lz4", "lzma", "cab", "tgz", "tbz2"]
    private static let movieExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "m2ts"]
    private static let audioExtensions: Set<String> = ["flac", "ogg", "opus", "wma", "ape"]
    private static let documentExtensions: Set<String> = ["hwp", "hwpx", "doc", "docx", "odt", "ods", "odp", "rtfd", "epub"]

    static func kinds(contentType: String?, fileExtension: String, isDirectory: Bool, isPackage: Bool,
                      isScreenCapture: Bool) -> Set<FolderRuleKind> {
        let ext = fileExtension.lowercased()
        let type = contentType.flatMap(UTType.init) ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext))
        func conforms(_ other: UTType?) -> Bool {
            guard let type, let other else { return false }
            return type.conforms(to: other)
        }
        var kinds: Set<FolderRuleKind> = []
        if conforms(.application) || (isPackage && ext == "app") { kinds.insert(.application) }
        if isDirectory && !isPackage && !kinds.contains(.application) { kinds.insert(.folder) }
        if conforms(.diskImage) { kinds.insert(.diskImage) }
        if conforms(installerPackage) || ext == "pkg" || ext == "mpkg" { kinds.insert(.installerPackage) }
        if (conforms(.archive) || archiveExtensions.contains(ext)),
           !kinds.contains(.diskImage), !kinds.contains(.installerPackage) { kinds.insert(.archive) }
        if conforms(.pdf) { kinds.insert(.pdf) }
        if conforms(.image) {
            kinds.insert(.image)
            if isScreenCapture { kinds.insert(.screenshot) }
        }
        if conforms(.movie) || movieExtensions.contains(ext) { kinds.insert(.movie) }
        if (conforms(.audio) || audioExtensions.contains(ext)) && !kinds.contains(.movie) { kinds.insert(.audio) }
        let documentLike = conforms(.compositeContent) || conforms(.text) || conforms(.spreadsheet)
            || conforms(.presentation) || documentExtensions.contains(ext)
        if documentLike && !conforms(sourceCode) && !kinds.contains(.folder) { kinds.insert(.document) }
        return kinds
    }
}

/// Decoders for the metadata macOS keeps in extended attributes. Pure, so
/// the tests feed them fixture bytes.
enum FolderRuleMetadata {
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    static let lastUsedDateAttribute = "com.apple.lastuseddate#PS"
    static let finderInfoAttribute = "com.apple.FinderInfo"
    /// AOM's marker on images it already optimized, so no rule optimizes
    /// them twice (Clop keeps a similar mark).
    static let optimizedAttribute = "com.kyw.allofmacos.optimized"

    /// The binary property list Safari, Chrome and Firefox write: an array
    /// of strings (download URL first, then the referring page).
    static func decodeWhereFroms(_ data: Data) -> [String] {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return [] }
        if let strings = object as? [String] { return strings.filter { !$0.isEmpty } }
        if let array = object as? [Any] { return array.compactMap { $0 as? String }.filter { !$0.isEmpty } }
        if let string = object as? String, !string.isEmpty { return [string] }
        return []
    }

    /// A property-list Boolean (or number) such as `kMDItemIsScreenCapture`.
    static func decodeBool(_ data: Data) -> Bool? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        if let flag = object as? Bool { return flag }
        if let number = object as? NSNumber { return number.boolValue }
        return nil
    }

    /// `com.apple.lastuseddate#PS`: a `struct timespec` (seconds, nanoseconds).
    static func decodeLastUsedDate(_ data: Data) -> Date? {
        guard data.count >= 16 else { return nil }
        let seconds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
        let nanoseconds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
        let littleSeconds = Int64(littleEndian: seconds)
        let littleNanos = Int64(littleEndian: nanoseconds)
        guard littleSeconds > 0, littleNanos >= 0, littleNanos < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(littleSeconds) + Double(littleNanos) / 1_000_000_000)
    }

    /// Finder marks a file it is still copying with type 'brok' and creator 'MACS'.
    static func isFinderCopyInProgress(_ finderInfo: Data) -> Bool {
        guard finderInfo.count >= 8 else { return false }
        let bytes = [UInt8](finderInfo.prefix(8))
        let brok: [UInt8] = [0x62, 0x72, 0x6F, 0x6B]
        let macs: [UInt8] = [0x4D, 0x41, 0x43, 0x53]
        return Array(bytes[0..<4]) == brok && Array(bytes[4..<8]) == macs
    }

    /// Lower-cased hosts of http(s) and ftp URLs, without duplicates.
    static func hosts(from whereFroms: [String]) -> [String] {
        var seen: [String] = []
        for string in whereFroms {
            guard let host = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
                  !host.isEmpty, !seen.contains(host) else { continue }
            seen.append(host)
        }
        return seen
    }

    /// Reads an extended attribute without following a symbolic link.
    static func attribute(_ name: String, at path: String, limit: Int = 64 * 1024) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length <= limit else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, name, buffer.baseAddress, length, 0, XATTR_NOFOLLOW)
        }
        guard read > 0 else { return nil }
        return data.prefix(read)
    }

    @discardableResult
    static func setAttribute(_ name: String, _ data: Data, at path: String) -> Bool {
        data.withUnsafeBytes { buffer in
            setxattr(path, name, buffer.baseAddress, data.count, 0, XATTR_NOFOLLOW) == 0
        }
    }
}

/// Reads `FolderRuleFileInfo` from disk. Runs off the main thread.
enum FolderRuleFileReader {
    /// The suffixes browsers and download tools give unfinished files.
    static let inProgressExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "filepart"]

    static func isInProgressName(_ name: String) -> Bool {
        inProgressExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static let keys: Set<URLResourceKey> = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .contentTypeKey, .fileSizeKey,
        .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .tagNamesKey
    ]

    /// Nil for items rules never touch: symbolic links, hidden items and
    /// unfinished downloads. `directorySizes` adds up folder contents (only
    /// when a rule tests Size, since it walks the folder).
    static func read(_ url: URL, depth: Int = 0, directorySizes: Bool = false) -> FolderRuleFileInfo? {
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let name = values.name ?? url.lastPathComponent
        if values.isSymbolicLink == true || values.isHidden == true || name.hasPrefix(".") || isInProgressName(name) {
            return nil
        }
        let path = url.path
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        if !isDirectory, let finder = FolderRuleMetadata.attribute(FolderRuleMetadata.finderInfoAttribute, at: path),
           FolderRuleMetadata.isFinderCopyInProgress(finder) {
            return nil
        }
        var size = Int64(values.fileSize ?? 0)
        if isDirectory { size = directorySizes ? directorySize(url) : 0 }
        let whereFroms = FolderRuleMetadata.attribute(FolderRuleMetadata.whereFromsAttribute, at: path)
            .map(FolderRuleMetadata.decodeWhereFroms) ?? []
        let screenCapture = FolderRuleMetadata.attribute(FolderRuleMetadata.screenCaptureAttribute, at: path)
            .flatMap(FolderRuleMetadata.decodeBool) ?? false
        let lastUsed = FolderRuleMetadata.attribute(FolderRuleMetadata.lastUsedDateAttribute, at: path)
            .flatMap(FolderRuleMetadata.decodeLastUsedDate)
        return FolderRuleFileInfo(url: url, name: name, isDirectory: isDirectory, isPackage: isPackage,
                                  contentType: values.contentType?.identifier, isScreenCapture: screenCapture, size: size,
                                  dateAdded: values.addedToDirectoryDate, dateCreated: values.creationDate,
                                  dateModified: values.contentModificationDate, dateLastOpened: lastUsed,
                                  whereFroms: whereFroms, tags: values.tagNames ?? [],
                                  device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino), depth: depth)
    }

    /// The total size of a folder's contents, stopping after 20,000 items.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let item as URL in enumerator {
            count += 1
            if count > 20_000 { break }
            if let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    enum ListingError: Error, Equatable {
        /// macOS refused (Files and Folders, Full Disk Access).
        case denied
        case missing
        case unreadable(String)
    }

    /// The items a rule may look at: the top level, plus subfolders (never
    /// inside packages) when `includeSubfolders`. Unfinished downloads,
    /// hidden items and links are left out by `read`.
    static func list(_ folder: URL, includeSubfolders: Bool, maxItems: Int = 5_000,
                     maxDepth: Int = 8) -> Result<[(url: URL, depth: Int)], ListingError> {
        let fileManager = FileManager.default
        var found: [(url: URL, depth: Int)] = []
        var queue: [(URL, Int)] = [(folder, 0)]
        var first = true
        while !queue.isEmpty, found.count < maxItems {
            let (directory, depth) = queue.removeFirst()
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys:
                                                                [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                                                              options: [.skipsHiddenFiles])
            } catch {
                if first { return .failure(classify(error)) }
                continue
            }
            first = false
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                found.append((entry, depth))
                if found.count >= maxItems { break }
                guard includeSubfolders, depth + 1 <= maxDepth,
                      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true else { continue }
                queue.append((entry, depth + 1))
            }
        }
        return .success(found)
    }

    static func classify(_ error: Error) -> ListingError {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = nsError.domain == NSPOSIXErrorDomain ? nsError.code : (underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : nil)
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return .denied }
        if posix == Int(EPERM) || posix == Int(EACCES) { return .denied }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
            return .missing
        }
        if posix == Int(ENOENT) || posix == Int(ENOTDIR) { return .missing }
        return .unreadable(nsError.localizedDescription)
    }

    /// True when any folder above `url` is a package (an app or bundle):
    /// Folder Rules never watches or acts inside one.
    static func isInsidePackage(_ url: URL) -> Bool {
        var current = url.standardizedFileURL.deletingLastPathComponent()
        while current.path != "/" && !current.path.isEmpty {
            if (try? current.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
            current = current.deletingLastPathComponent()
        }
        return false
    }
}
