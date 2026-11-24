import Foundation
import UniformTypeIdentifiers

// AOM 7.12 (Codex 30-app spec #1, HoudahSpot's search templates): Search
// Files takes conditions — a folder, a kind and how recently a file
// changed — beside the name, and a search is saved by its conditions, not
// its results: "이번 주 견적서" computes "the last 7 days" again each time.

/// What Search Files' field says: `in:~/Documents/견적 kind:pdf modified:7d 견적`.
struct PaletteFileQuery: Equatable, Codable {
    enum Kind: String, CaseIterable, Codable {
        case pdf, image, movie, audio, document, spreadsheet, presentation, text, archive, folder, app

        /// The words that pick it (English and Korean).
        var words: [String] {
            switch self {
            case .pdf: return ["pdf", "피디에프"]
            case .image: return ["image", "images", "photo", "picture", "이미지", "사진", "그림"]
            case .movie: return ["movie", "video", "movies", "videos", "동영상", "영상"]
            case .audio: return ["audio", "music", "sound", "오디오", "음악"]
            case .document: return ["document", "documents", "doc", "docs", "문서"]
            case .spreadsheet: return ["spreadsheet", "sheet", "excel", "xlsx", "스프레드시트", "엑셀"]
            case .presentation: return ["presentation", "slides", "keynote", "pptx", "프레젠테이션", "발표"]
            case .text: return ["text", "txt", "markdown", "md", "텍스트"]
            case .archive: return ["archive", "zip", "압축"]
            case .folder: return ["folder", "folders", "dir", "폴더"]
            case .app: return ["app", "apps", "application", "앱"]
            }
        }

        var title: String {
            switch self {
            case .pdf: return "PDFs"
            case .image: return "Images"
            case .movie: return "Movies"
            case .audio: return "Audio"
            case .document: return "Documents"
            case .spreadsheet: return "Spreadsheets"
            case .presentation: return "Presentations"
            case .text: return "Text Files"
            case .archive: return "Archives"
            case .folder: return "Folders"
            case .app: return "Apps"
            }
        }

        /// The UTType Spotlight's content type tree must include.
        var contentType: String {
            switch self {
            case .pdf: return UTType.pdf.identifier
            case .image: return UTType.image.identifier
            case .movie: return UTType.movie.identifier
            case .audio: return UTType.audio.identifier
            case .document: return "public.composite-content"
            case .spreadsheet: return UTType.spreadsheet.identifier
            case .presentation: return UTType.presentation.identifier
            case .text: return UTType.text.identifier
            case .archive: return UTType.archive.identifier
            case .folder: return UTType.folder.identifier
            case .app: return UTType.application.identifier
            }
        }

        static func named(_ word: String) -> Kind? {
            let lowered = word.lowercased()
            return allCases.first { $0.rawValue == lowered || $0.words.contains(lowered) }
        }
    }

    var name = ""
    var folder: String?
    var kind: Kind?
    /// "modified:7d": changed within this many seconds of the search.
    var within: TimeInterval?

    var hasConditions: Bool { folder != nil || kind != nil || within != nil }
    var isEmpty: Bool { name.isEmpty && !hasConditions }

    /// The folder as a URL (`~` expanded), nil for the home folder.
    var folderURL: URL? {
        folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
    }

    /// Pure. `in:` (또는 `폴더:`), `kind:` (`종류:`), `modified:` (`수정:`); a
    /// path with spaces goes in quotes. Everything else is the name.
    static func parse(_ text: String) -> PaletteFileQuery {
        var query = PaletteFileQuery()
        var words: [String] = []
        for token in tokens(text) {
            let lowered = token.lowercased()
            if let value = value(of: lowered, original: token, keys: ["in:", "폴더:", "folder:"]) {
                if !value.isEmpty { query.folder = value }
            } else if let value = value(of: lowered, original: token, keys: ["kind:", "종류:", "type:"]) {
                if let kind = Kind.named(value) { query.kind = kind } else { words.append(token) }
            } else if let value = value(of: lowered, original: token, keys: ["modified:", "수정:", "changed:"]) {
                if let seconds = duration(value) { query.within = seconds } else { words.append(token) }
            } else {
                words.append(token)
            }
        }
        query.name = words.joined(separator: " ")
        return query
    }

    /// The field text for this query (what a saved search opens with).
    var text: String {
        var parts: [String] = []
        if let folder { parts.append(folder.contains(" ") ? "in:\"\(folder)\"" : "in:\(folder)") }
        if let kind { parts.append("kind:\(kind.rawValue)") }
        if let within { parts.append("modified:\(Self.durationText(within))") }
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " ")
    }

    /// "PDFs · changed in the last 7 days · in ~/Documents/견적".
    var summary: String {
        var parts: [String] = []
        parts.append(kind?.title ?? "Files")
        if !name.isEmpty { parts[0] += " named “\(name)”" }
        if let within { parts.append("changed in the last \(Self.durationWords(within))") }
        parts.append("in \(folder ?? "your home folder")")
        return parts.joined(separator: " · ")
    }

    /// The Spotlight predicate, the dates counted from `now`.
    func predicate(now: Date = Date()) -> NSPredicate {
        var parts: [NSPredicate] = []
        if !name.isEmpty { parts.append(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, name)) }
        if let kind { parts.append(NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", kind.contentType)) }
        if let within { parts.append(NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, now.addingTimeInterval(-min(within.isFinite ? within : Self.maxDuration, Self.maxDuration)) as NSDate)) }
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    // MARK: Helpers

    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle(); continue }
            if character.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func value(of lowered: String, original: String, keys: [String]) -> String? {
        for key in keys where lowered.hasPrefix(key) { return String(original.dropFirst(key.count)) }
        return nil
    }

    /// "7d", "24h", "2w", "1m" (30 days), "1y"; "7일", "2주", "3시간", "1달" too.
    static func duration(_ text: String) -> TimeInterval? {
        let units: [(String, TimeInterval)] = [("h", 3600), ("시간", 3600), ("d", 86_400), ("일", 86_400), ("w", 604_800), ("주", 604_800),
                                               ("m", 2_592_000), ("달", 2_592_000), ("개월", 2_592_000), ("y", 31_536_000), ("년", 31_536_000)]
        let lowered = text.lowercased()
        for (unit, seconds) in units where lowered.hasSuffix(unit) {
            guard let amount = Double(lowered.dropLast(unit.count)), amount > 0, amount.isFinite else { return nil }
            // 7.14 (Codex 7.13 S3): "1e308y" overflowed and crashed the summary's Int().
            let total = amount * seconds
            return total.isFinite && total <= maxDuration ? total : nil
        }
        return nil
    }

    /// The longest "modified:" a search takes: 100 years.
    static let maxDuration: TimeInterval = 100 * 31_536_000

    static func durationText(_ seconds: TimeInterval) -> String {
        // A value saved before 7.14 may be out of range: shown at the limit.
        let seconds = seconds.isFinite ? min(max(seconds, 3600), maxDuration) : maxDuration
        for (unit, size) in [("y", 31_536_000.0), ("m", 2_592_000.0), ("w", 604_800.0), ("d", 86_400.0)] where seconds >= size && seconds.truncatingRemainder(dividingBy: size) == 0 {
            return "\(Int(seconds / size))\(unit)"
        }
        return "\(Int(max(1, seconds / 3600)))h"
    }

    static func durationWords(_ seconds: TimeInterval) -> String {
        let text = durationText(seconds)
        let amount = Int(text.dropLast()) ?? 1
        let unit: String
        switch text.last {
        case "y": unit = amount == 1 ? "year" : "years"
        case "m": unit = amount == 1 ? "month" : "months"
        case "w": unit = amount == 1 ? "week" : "weeks"
        case "d": unit = amount == 1 ? "day" : "days"
        default: unit = amount == 1 ? "hour" : "hours"
        }
        return amount == 1 ? unit : "\(amount) \(unit)"
    }
}

/// One saved search: its name and its conditions.
struct PaletteSavedSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query: PaletteFileQuery
    var created = Date()
}

/// The saved searches, in UserDefaults (`AOMLauncherSavedSearches`).
@MainActor
final class PaletteSavedSearches: ObservableObject {
    static let shared = PaletteSavedSearches()
    static let key = "AOMLauncherSavedSearches"

    @Published private(set) var searches: [PaletteSavedSearch]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searches = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([PaletteSavedSearch].self, from: $0) } ?? []
    }

    /// Saves `query` as `name`; a search with that name is replaced.
    @discardableResult
    func save(_ name: String, query: PaletteFileQuery) -> PaletteSavedSearch {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = searches.firstIndex(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            searches[index].query = query
            persist()
            return searches[index]
        }
        let search = PaletteSavedSearch(name: trimmed, query: query)
        searches.append(search)
        persist()
        return search
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = searches.firstIndex(where: { $0.id == id }) else { return }
        searches[index].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        searches.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(searches) { defaults.set(data, forKey: Self.key) }
    }
}
