import Foundation

// The Folder Rules data model (3.4.0, Hazel-style folder automation). Every
// type is Codable and decodes leniently: a field added in a later version
// falls back to its default, so an older or hand-edited rules.json still
// loads. Stored in Application Support/AllOfMacOS/FolderRules/rules.json.

/// Everything the user set up: the master switch, the watched folders and
/// their rules. Rules run in array order within their folder.
struct FolderRulesConfig: Codable, Equatable {
    static let currentVersion = 1

    var version = FolderRulesConfig.currentVersion
    /// The module's master switch. Off by default, like every template.
    var isEnabled = false
    var folders: [FolderRuleFolder] = []
    var rules: [FolderRule] = []

    init(isEnabled: Bool = false, folders: [FolderRuleFolder] = [], rules: [FolderRule] = []) {
        self.isEnabled = isEnabled
        self.folders = folders
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case version, isEnabled, folders, rules }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        folders = (try? c.decodeIfPresent([FolderRuleFolder].self, forKey: .folders)) ?? []
        rules = (try? c.decodeIfPresent([FolderRule].self, forKey: .rules)) ?? []
    }

    func rules(in folderID: UUID) -> [FolderRule] { rules.filter { $0.folderID == folderID } }
    func folder(_ id: UUID) -> FolderRuleFolder? { folders.first { $0.id == id } }
}

/// A folder the user picked to watch (Downloads, Desktop, or one added with
/// Add Folder…). Rules only ever act on items inside it.
struct FolderRuleFolder: Codable, Equatable, Identifiable {
    var id: UUID
    /// Absolute, standardized path.
    var path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = (path as NSString).standardizingPath
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { FileManager.default.displayName(atPath: path) }

    enum CodingKeys: String, CodingKey { case id, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = ((try c.decode(String.self, forKey: .path)) as NSString).standardizingPath
    }
}

/// How a rule's conditions combine: "If [all] of the following are true".
enum FolderRuleMatch: String, Codable, CaseIterable, Identifiable {
    case all, any, none
    var id: String { rawValue }
}

/// One rule: conditions, then actions run in order on each matching item.
struct FolderRule: Codable, Equatable, Identifiable {
    var id: UUID
    var folderID: UUID
    var name: String
    /// Every rule starts off; turning it on shows the preview first.
    var isEnabled = false
    var match: FolderRuleMatch = .all
    var conditions: [FolderRuleCondition] = []
    var actions: [FolderRuleAction] = []
    /// Top level only by default (Hazel's default too).
    var includeSubfolders = false
    /// Destructive actions and installs ask first unless this is on.
    var runWithoutAsking = false
    /// The template this rule was made from, if any.
    var templateID: String?

    init(id: UUID = UUID(), folderID: UUID, name: String, isEnabled: Bool = false, match: FolderRuleMatch = .all,
         conditions: [FolderRuleCondition] = [], actions: [FolderRuleAction] = [],
         includeSubfolders: Bool = false, runWithoutAsking: Bool = false, templateID: String? = nil) {
        self.id = id
        self.folderID = folderID
        self.name = name
        self.isEnabled = isEnabled
        self.match = match
        self.conditions = conditions
        self.actions = actions
        self.includeSubfolders = includeSubfolders
        self.runWithoutAsking = runWithoutAsking
        self.templateID = templateID
    }

    enum CodingKeys: String, CodingKey {
        case id, folderID, name, isEnabled, match, conditions, actions, includeSubfolders, runWithoutAsking, templateID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        folderID = try c.decode(UUID.self, forKey: .folderID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Rule"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        match = (try? c.decodeIfPresent(FolderRuleMatch.self, forKey: .match)) ?? .all
        conditions = (try? c.decodeIfPresent([FolderRuleCondition].self, forKey: .conditions)) ?? []
        actions = (try? c.decodeIfPresent([FolderRuleAction].self, forKey: .actions)) ?? []
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? false
        runWithoutAsking = try c.decodeIfPresent(Bool.self, forKey: .runWithoutAsking) ?? false
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
    }

    /// What changes whether an item matches. Hazel re-checks items a rule
    /// already handled when its conditions change; the memory keys on this.
    var conditionSignature: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let parts = conditions.map { condition -> String in
            var plain = condition
            plain.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            return (try? encoder.encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return "\(match.rawValue)|\(includeSubfolders)|" + parts.joined(separator: ";")
    }

    /// The actions that change or remove the item, which ask first unless
    /// the rule runs without asking.
    var actionsNeedingApproval: [FolderRuleAction] { actions.filter(\.needsApproval) }
    var needsApproval: Bool { !runWithoutAsking && !actionsNeedingApproval.isEmpty }

    /// Why the rule can't run yet, in the editor's words. Empty when it can.
    var problems: [String] {
        var found: [String] = []
        if conditions.isEmpty { found.append("Add at least one condition.") }
        if actions.isEmpty { found.append("Add at least one action.") }
        for condition in conditions { if let problem = condition.problem { found.append(problem) } }
        for action in actions { if let problem = action.problem { found.append(problem) } }
        if let trash = actions.firstIndex(where: { $0.kind.endsChain }), trash < actions.count - 1 {
            found.append("“\(actions[trash].kind.title)” must be the last action: the item is gone after it.")
        }
        return found
    }
}

// MARK: - Conditions

enum FolderRuleAttribute: String, Codable, CaseIterable, Identifiable {
    case name
    case fileExtension = "extension"
    case kind, dateAdded, dateCreated, dateModified, dateLastOpened, size, downloadedFrom, tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .fileExtension: return "Extension"
        case .kind: return "Kind"
        case .dateAdded: return "Date Added"
        case .dateCreated: return "Date Created"
        case .dateModified: return "Date Modified"
        case .dateLastOpened: return "Date Last Opened"
        case .size: return "Size"
        case .downloadedFrom: return "Downloaded From"
        case .tags: return "Tags"
        }
    }

    var isDate: Bool { [.dateAdded, .dateCreated, .dateModified, .dateLastOpened].contains(self) }

    /// The operators the attribute offers, the first being its default.
    var comparisons: [FolderRuleComparison] {
        switch self {
        case .name: return [.contains, .doesNotContain, .is, .isNot, .startsWith, .endsWith, .matchesRegex]
        case .fileExtension, .kind: return [.is, .isNot]
        case .dateAdded, .dateCreated, .dateModified, .dateLastOpened: return [.olderThan, .newerThan]
        case .size: return [.greaterThan, .lessThan]
        case .downloadedFrom: return [.contains, .doesNotContain]
        case .tags: return [.has, .hasNot]
        }
    }
}

enum FolderRuleComparison: String, Codable, CaseIterable, Identifiable {
    case contains, doesNotContain, startsWith, endsWith, matchesRegex
    case `is`, isNot
    case olderThan, newerThan
    case greaterThan, lessThan
    case has, hasNot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .matchesRegex: return "matches pattern"
        case .is: return "is"
        case .isNot: return "is not"
        case .olderThan: return "is more than"
        case .newerThan: return "is within the last"
        case .greaterThan: return "is greater than"
        case .lessThan: return "is less than"
        case .has: return "include"
        case .hasNot: return "do not include"
        }
    }

    /// A negative comparison matches when none of the values match.
    var isNegative: Bool { [.doesNotContain, .isNot, .hasNot].contains(self) }
}

/// The kinds a rule can test, by UTType conformance (plus the screenshot flag
/// macOS writes, `kMDItemIsScreenCapture`).
enum FolderRuleKind: String, Codable, CaseIterable, Identifiable {
    case image, screenshot, movie, audio, pdf, archive, diskImage, installerPackage, document, folder, application

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Image"
        case .screenshot: return "Screenshot"
        case .movie: return "Movie"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .archive: return "Archive"
        case .diskImage: return "Disk Image"
        case .installerPackage: return "Installer Package"
        case .document: return "Document"
        case .folder: return "Folder"
        case .application: return "Application"
        }
    }

    /// What `{kind}` expands to in folder patterns ("Images", "PDFs").
    var folderName: String {
        switch self {
        case .image: return "Images"
        case .screenshot: return "Screenshots"
        case .movie: return "Movies"
        case .audio: return "Audio"
        case .pdf: return "PDFs"
        case .archive: return "Archives"
        case .diskImage: return "Disk Images"
        case .installerPackage: return "Installers"
        case .document: return "Documents"
        case .folder: return "Folders"
        case .application: return "Applications"
        }
    }
}

enum FolderRuleTimeUnit: String, Codable, CaseIterable, Identifiable {
    case minutes, hours, days
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .minutes: return 60
        case .hours: return 3600
        case .days: return 86_400
        }
    }
    func title(_ amount: Double) -> String {
        let one = amount == 1
        switch self {
        case .minutes: return one ? "minute" : "minutes"
        case .hours: return one ? "hour" : "hours"
        case .days: return one ? "day" : "days"
        }
    }
}

/// Sizes in Finder's decimal units (1 MB = 1,000,000 bytes).
enum FolderRuleSizeUnit: String, Codable, CaseIterable, Identifiable {
    case kilobytes = "KB", megabytes = "MB", gigabytes = "GB"
    var id: String { rawValue }
    var bytes: Double {
        switch self {
        case .kilobytes: return 1_000
        case .megabytes: return 1_000_000
        case .gigabytes: return 1_000_000_000
        }
    }
}

struct FolderRuleCondition: Codable, Equatable, Identifiable {
    var id: UUID
    var attribute: FolderRuleAttribute
    var comparison: FolderRuleComparison
    /// Names, extensions, hosts or tags. A positive comparison matches when
    /// any value matches; a negative one when none does.
    var values: [String]
    /// The regular expression for "matches pattern".
    var pattern: String
    var kind: FolderRuleKind
    var amount: Double
    var timeUnit: FolderRuleTimeUnit
    var sizeUnit: FolderRuleSizeUnit

    init(id: UUID = UUID(), attribute: FolderRuleAttribute, comparison: FolderRuleComparison? = nil,
         values: [String] = [], pattern: String = "", kind: FolderRuleKind = .image,
         amount: Double = 1, timeUnit: FolderRuleTimeUnit = .days, sizeUnit: FolderRuleSizeUnit = .megabytes) {
        self.id = id
        self.attribute = attribute
        let allowed = attribute.comparisons
        self.comparison = comparison.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed[0]
        self.values = values
        self.pattern = pattern
        self.kind = kind
        self.amount = amount
        self.timeUnit = timeUnit
        self.sizeUnit = sizeUnit
    }

    static func name(_ comparison: FolderRuleComparison, _ values: [String]) -> FolderRuleCondition {
        FolderRuleCondition(attribute: .name, comparison: comparison, values: values)
    }
    static func fileExtension(_ comparison: FolderRuleComparison = .is, _ values: [String]) -> FolderRuleCondition {
        FolderRuleCondition(attribute: .fileExtension, comparison: comparison, values: values)
    }
    static func kind(_ kind: FolderRuleKind, is positive: Bool = true) -> FolderRuleCondition {
        FolderRuleCondition(attribute: .kind, comparison: positive ? .is : .isNot, kind: kind)
    }
    static func date(_ attribute: FolderRuleAttribute, _ comparison: FolderRuleComparison, _ amount: Double,
                     _ unit: FolderRuleTimeUnit) -> FolderRuleCondition {
        FolderRuleCondition(attribute: attribute, comparison: comparison, amount: amount, timeUnit: unit)
    }
    static func size(_ comparison: FolderRuleComparison, _ amount: Double, _ unit: FolderRuleSizeUnit) -> FolderRuleCondition {
        FolderRuleCondition(attribute: .size, comparison: comparison, amount: amount, sizeUnit: unit)
    }
    static func downloadedFrom(_ hosts: [String], _ comparison: FolderRuleComparison = .contains) -> FolderRuleCondition {
        FolderRuleCondition(attribute: .downloadedFrom, comparison: comparison, values: hosts)
    }
    static func tags(_ comparison: FolderRuleComparison, _ tags: [String]) -> FolderRuleCondition {
        FolderRuleCondition(attribute: .tags, comparison: comparison, values: tags)
    }

    /// Values without blanks; extensions without the dot and lower-cased.
    var cleanValues: [String] {
        values.compactMap { raw in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if attribute == .fileExtension {
                while value.hasPrefix(".") { value.removeFirst() }
                value = value.lowercased()
            }
            return value.isEmpty ? nil : value
        }
    }

    var problem: String? {
        switch attribute {
        case .name where comparison == .matchesRegex:
            if pattern.isEmpty { return "Name: enter a pattern." }
            if (try? NSRegularExpression(pattern: pattern)) == nil { return "Name: “\(pattern)” isn't a valid pattern." }
            return nil
        case .name, .fileExtension, .downloadedFrom, .tags:
            return cleanValues.isEmpty ? "\(attribute.title): add a value." : nil
        case .dateAdded, .dateCreated, .dateModified, .dateLastOpened, .size:
            return amount.isFinite && amount >= 0 ? nil : "\(attribute.title): enter a number."
        case .kind:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey { case id, attribute, comparison, values, pattern, kind, amount, timeUnit, sizeUnit }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let attribute = try c.decode(FolderRuleAttribute.self, forKey: .attribute)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  attribute: attribute,
                  comparison: try? c.decodeIfPresent(FolderRuleComparison.self, forKey: .comparison),
                  values: (try? c.decodeIfPresent([String].self, forKey: .values)) ?? [],
                  pattern: try c.decodeIfPresent(String.self, forKey: .pattern) ?? "",
                  kind: (try? c.decodeIfPresent(FolderRuleKind.self, forKey: .kind)) ?? .image,
                  amount: try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1,
                  timeUnit: (try? c.decodeIfPresent(FolderRuleTimeUnit.self, forKey: .timeUnit)) ?? .days,
                  sizeUnit: (try? c.decodeIfPresent(FolderRuleSizeUnit.self, forKey: .sizeUnit)) ?? .megabytes)
    }
}

// MARK: - Actions

enum FolderRuleActionKind: String, Codable, CaseIterable, Identifiable {
    case move, copy, rename, addTags, setColorLabel, moveToTrash, compress, extract, optimizeImage, installApp
    case openWith, notify, runAutomation, runShortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: return "Move to Folder"
        case .copy: return "Copy to Folder"
        case .rename: return "Rename"
        case .addTags: return "Add Tags"
        case .setColorLabel: return "Set Color Label"
        case .moveToTrash: return "Move to Trash"
        case .compress: return "Compress to ZIP"
        case .extract: return "Extract ZIP"
        case .optimizeImage: return "Optimize Image"
        case .installApp: return "Install App"
        case .openWith: return "Open"
        case .notify: return "Show Notification"
        case .runAutomation: return "Run Automation"
        case .runShortcut: return "Run Shortcut"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        case .rename: return "character.cursor.ibeam"
        case .addTags: return "tag"
        case .setColorLabel: return "circle.fill"
        case .moveToTrash: return "trash"
        case .compress: return "doc.zipper"
        case .extract: return "arrow.up.bin"
        case .optimizeImage: return "photo.badge.checkmark"
        case .installApp: return "externaldrive.badge.plus"
        case .openWith: return "arrow.up.forward.app"
        case .notify: return "bell"
        case .runAutomation: return "bolt"
        case .runShortcut: return "square.2.layers.3d"
        }
    }

    /// After this action the item is no longer there to act on.
    var endsChain: Bool { self == .moveToTrash }
}

/// Finder's colour labels, in `URLResourceValues.labelNumber` order
/// (NSWorkspace.fileLabels: None, Gray, Green, Purple, Blue, Yellow, Red, Orange).
enum FolderRuleColorLabel: Int, Codable, CaseIterable, Identifiable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .gray: return "Gray"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }
}

/// Optimize Image (Clop-style): resize above a maximum side, re-encode JPEG
/// and HEIC at a quality, strip location, optionally turn PNG screenshots
/// into JPEG or HEIC.
struct FolderRuleImageOptions: Codable, Equatable {
    enum Output: String, Codable, CaseIterable, Identifiable {
        case keep, jpeg, heic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keep: return "Keep PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            }
        }
    }
    enum Original: String, Codable, CaseIterable, Identifiable {
        case trash, overwrite
        var id: String { rawValue }
        var title: String { self == .trash ? "Keep in the Trash" : "Overwrite" }
    }

    /// The longest side in pixels; 0 never resizes.
    var maxDimension = 2560
    /// JPEG and HEIC quality, 0.1–1.
    var quality = 0.8
    var stripLocation = true
    /// What PNG screenshots become.
    var screenshotOutput: Output = .keep
    var original: Original = .trash

    init(maxDimension: Int = 2560, quality: Double = 0.8, stripLocation: Bool = true,
         screenshotOutput: Output = .keep, original: Original = .trash) {
        self.maxDimension = maxDimension
        self.quality = quality
        self.stripLocation = stripLocation
        self.screenshotOutput = screenshotOutput
        self.original = original
    }

    enum CodingKeys: String, CodingKey { case maxDimension, quality, stripLocation, screenshotOutput, original }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxDimension = try c.decodeIfPresent(Int.self, forKey: .maxDimension) ?? 2560
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.8
        stripLocation = try c.decodeIfPresent(Bool.self, forKey: .stripLocation) ?? true
        screenshotOutput = (try? c.decodeIfPresent(Output.self, forKey: .screenshotOutput)) ?? .keep
        original = (try? c.decodeIfPresent(Original.self, forKey: .original)) ?? .trash
    }

    var clampedQuality: Double { min(1, max(0.1, quality.isFinite ? quality : 0.8)) }
}

/// Install App from Disk Image (Rapidmg-style).
struct FolderRuleInstallOptions: Codable, Equatable {
    var trashDiskImage = true
    var openAfterInstall = false

    init(trashDiskImage: Bool = true, openAfterInstall: Bool = false) {
        self.trashDiskImage = trashDiskImage
        self.openAfterInstall = openAfterInstall
    }

    enum CodingKeys: String, CodingKey { case trashDiskImage, openAfterInstall }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trashDiskImage = try c.decodeIfPresent(Bool.self, forKey: .trashDiskImage) ?? true
        openAfterInstall = try c.decodeIfPresent(Bool.self, forKey: .openAfterInstall) ?? false
    }
}

struct FolderRuleAction: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: FolderRuleActionKind
    /// Move and Copy: the destination folder (absolute path).
    var folderPath: String
    /// Move and Copy: subfolders to sort into ("{year}-{month}"); may be empty.
    var subfolderPattern: String
    /// Rename: the new name ("{name} {date:yyyy-MM-dd}"). Without `{ext}`
    /// the original extension is kept.
    var pattern: String
    var tags: [String]
    var colorLabel: FolderRuleColorLabel
    /// Compress and Extract: the original goes to the Trash afterwards
    /// (Hazel's Archive and Unarchive do the same).
    var trashOriginal: Bool
    /// Open: the app's path; empty opens with the default app.
    var appPath: String
    /// Show Notification: the text, with the same tokens as Rename.
    var message: String
    var automationID: UUID?
    var automationName: String
    var shortcutName: String
    var image: FolderRuleImageOptions
    var install: FolderRuleInstallOptions

    init(id: UUID = UUID(), kind: FolderRuleActionKind, folderPath: String = "", subfolderPattern: String = "",
         pattern: String = "{name}", tags: [String] = [], colorLabel: FolderRuleColorLabel = .none,
         trashOriginal: Bool = true, appPath: String = "", message: String = "", automationID: UUID? = nil,
         automationName: String = "", shortcutName: String = "",
         image: FolderRuleImageOptions = FolderRuleImageOptions(), install: FolderRuleInstallOptions = FolderRuleInstallOptions()) {
        self.id = id
        self.kind = kind
        self.folderPath = folderPath
        self.subfolderPattern = subfolderPattern
        self.pattern = pattern
        self.tags = tags
        self.colorLabel = colorLabel
        self.trashOriginal = trashOriginal
        self.appPath = appPath
        self.message = message
        self.automationID = automationID
        self.automationName = automationName
        self.shortcutName = shortcutName
        self.image = image
        self.install = install
    }

    static func move(to path: String, subfolders: String = "") -> FolderRuleAction {
        FolderRuleAction(kind: .move, folderPath: path, subfolderPattern: subfolders)
    }
    static func copy(to path: String, subfolders: String = "") -> FolderRuleAction {
        FolderRuleAction(kind: .copy, folderPath: path, subfolderPattern: subfolders)
    }
    static func rename(_ pattern: String) -> FolderRuleAction { FolderRuleAction(kind: .rename, pattern: pattern) }
    static func addTags(_ tags: [String]) -> FolderRuleAction { FolderRuleAction(kind: .addTags, tags: tags) }
    static func colorLabel(_ label: FolderRuleColorLabel) -> FolderRuleAction {
        FolderRuleAction(kind: .setColorLabel, colorLabel: label)
    }
    static var moveToTrash: FolderRuleAction { FolderRuleAction(kind: .moveToTrash) }

    /// Changes or removes the item, so it asks first (unless the rule runs
    /// without asking). Installs always count.
    var needsApproval: Bool {
        switch kind {
        case .moveToTrash, .optimizeImage, .installApp: return true
        case .compress, .extract: return trashOriginal
        default: return false
        }
    }

    var problem: String? {
        switch kind {
        case .move, .copy:
            let trimmed = folderPath.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "\(kind.title): choose a folder." }
            if !trimmed.hasPrefix("/") { return "\(kind.title): the folder must be a full path." }
            return FolderRulePatterns.unknownTokens(in: subfolderPattern, allowed: FolderRulePatterns.folderTokens)
                .first.map { "\(kind.title): {\($0)} isn't a folder token." }
        case .rename:
            if pattern.trimmingCharacters(in: .whitespaces).isEmpty { return "Rename: enter a name pattern." }
            return FolderRulePatterns.unknownTokens(in: pattern, allowed: FolderRulePatterns.nameTokens)
                .first.map { "Rename: {\($0)} isn't a name token." }
        case .addTags:
            return tags.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ? nil : "Add Tags: add a tag."
        case .runAutomation:
            return automationID == nil ? "Run Automation: choose an automation." : nil
        case .runShortcut:
            let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return "Run Shortcut: enter the shortcut's name." }
            return name.count > 256 || name.contains("\0") ? "Run Shortcut: the name is too long." : nil
        case .optimizeImage:
            return image.maxDimension < 0 ? "Optimize Image: the size can't be negative." : nil
        case .setColorLabel, .moveToTrash, .compress, .extract, .installApp, .openWith, .notify:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, folderPath, subfolderPattern, pattern, tags, colorLabel, trashOriginal, appPath, message
        case automationID, automationName, shortcutName, image, install
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  kind: try c.decode(FolderRuleActionKind.self, forKey: .kind),
                  folderPath: try c.decodeIfPresent(String.self, forKey: .folderPath) ?? "",
                  subfolderPattern: try c.decodeIfPresent(String.self, forKey: .subfolderPattern) ?? "",
                  pattern: try c.decodeIfPresent(String.self, forKey: .pattern) ?? "{name}",
                  tags: (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? [],
                  colorLabel: (try? c.decodeIfPresent(FolderRuleColorLabel.self, forKey: .colorLabel)) ?? .none,
                  trashOriginal: try c.decodeIfPresent(Bool.self, forKey: .trashOriginal) ?? true,
                  appPath: try c.decodeIfPresent(String.self, forKey: .appPath) ?? "",
                  message: try c.decodeIfPresent(String.self, forKey: .message) ?? "",
                  automationID: try c.decodeIfPresent(UUID.self, forKey: .automationID),
                  automationName: try c.decodeIfPresent(String.self, forKey: .automationName) ?? "",
                  shortcutName: try c.decodeIfPresent(String.self, forKey: .shortcutName) ?? "",
                  image: (try? c.decodeIfPresent(FolderRuleImageOptions.self, forKey: .image)) ?? FolderRuleImageOptions(),
                  install: (try? c.decodeIfPresent(FolderRuleInstallOptions.self, forKey: .install)) ?? FolderRuleInstallOptions())
    }
}
