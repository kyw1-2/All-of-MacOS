import Compression
import Foundation
import zlib

/// 7.5 (Codex F03, BetterZip's selective extract): reads a ZIP's central
/// directory and extracts only the entries picked, so one PDF comes out of
/// a big download without unpacking the rest. Entries are told apart by
/// their place in the directory, so two "report.pdf" in different folders
/// are two entries. Stored and Deflate entries are read; anything else
/// (password-protected, other methods, links, paths that climb out of the
/// folder) is listed with why it can't be extracted.
///
/// Writing never replaces anything: each file is inflated into a hidden
/// temporary file next to where it goes, its CRC-32 and size are checked,
/// and it is renamed to a free name with RENAME_EXCL ("report 2.pdf" when
/// taken). Every path is checked to stay inside the chosen folder, with
/// symbolic links in the folders on the way resolved.
enum ZipArchive {
    struct Entry: Identifiable, Equatable, Hashable {
        /// Place in the central directory.
        let id: Int
        /// "Contracts/2026/report.pdf" (decoded, `/`-separated, as stored).
        let path: String
        /// The path's parts used for writing (nil when it isn't safe).
        let components: [String]?
        let size: Int64
        let compressedSize: Int64
        let method: UInt16
        let crc: UInt32
        let localHeaderOffset: Int64
        let isDirectory: Bool
        let modified: Date?
        /// Why it can't be extracted; nil when it can.
        let unsupported: String?

        var name: String { components?.last ?? path.split(separator: "/").last.map(String.init) ?? path }
        /// The folder inside the archive ("" at the top).
        var folder: String {
            guard let components, components.count > 1 else { return "" }
            return components.dropLast().joined(separator: "/")
        }
    }

    enum Failure: LocalizedError, Equatable {
        case notZip
        case damaged(String)
        case unsupported(String)
        case outside(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return "This isn't a ZIP archive, or its end is missing"
            case .damaged(let detail): return "The archive is damaged: \(detail)"
            case .unsupported(let detail): return detail
            case .outside(let path): return "“\(path)” would be written outside the folder you chose"
            }
        }
    }

    // MARK: Reading the directory

    /// Every entry in the archive, AppleDouble files (`__MACOSX/`) left out.
    static func entries(of url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = Int64(try handle.seekToEnd())
        let tailLength = Int(min(length, 65_557))
        try handle.seek(toOffset: UInt64(length - Int64(tailLength)))
        let tail = [UInt8](try handle.read(upToCount: tailLength) ?? Data())
        guard let eocd = lastIndex(of: 0x0605_4b50, in: tail), eocd + 22 <= tail.count else { throw Failure.notZip }
        var count = Int64(le16(tail, eocd + 10))
        var directorySize = Int64(le32(tail, eocd + 12))
        var directoryOffset = Int64(le32(tail, eocd + 16))
        // 64-bit fields of a damaged or hostile archive can exceed Int64.max.
        func int64(_ value: UInt64) throws -> Int64 {
            guard value <= UInt64(Int64.max) else { throw Failure.damaged("a size or offset is out of range") }
            return Int64(value)
        }
        // ZIP64: the locator sits just before the end record.
        if eocd >= 20, le32(tail, eocd - 20) == 0x0706_4b50 {
            let recordOffset = try int64(le64(tail, eocd - 20 + 8))
            guard recordOffset >= 0, recordOffset + 56 <= length else { throw Failure.damaged("the ZIP64 end record points past the end") }
            try handle.seek(toOffset: UInt64(recordOffset))
            let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard record.count >= 56, le32(record, 0) == 0x0606_4b50 else { throw Failure.damaged("the ZIP64 end record is missing") }
            count = try int64(le64(record, 32))
            directorySize = try int64(le64(record, 40))
            directoryOffset = try int64(le64(record, 48))
        }
        guard directoryOffset >= 0, directorySize >= 0, directorySize <= length, directoryOffset <= length - directorySize,
              count >= 0, count < 2_000_000 else {
            throw Failure.damaged("the directory points past the end of the file")
        }
        try handle.seek(toOffset: UInt64(directoryOffset))
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        var entries: [Entry] = []
        var at = 0
        for index in 0..<Int(count) {
            guard at + 46 <= directory.count, le32(directory, at) == 0x0201_4b50 else {
                throw Failure.damaged("entry \(index + 1) of \(count) can't be read")
            }
            let madeBy = le16(directory, at + 4)
            let flags = le16(directory, at + 8)
            let method = le16(directory, at + 10)
            let time = le16(directory, at + 12), date = le16(directory, at + 14)
            let crc = le32(directory, at + 16)
            var compressed = Int64(le32(directory, at + 20))
            var size = Int64(le32(directory, at + 24))
            let nameLength = Int(le16(directory, at + 28)), extraLength = Int(le16(directory, at + 30)), commentLength = Int(le16(directory, at + 32))
            let external = le32(directory, at + 38)
            var offset = Int64(le32(directory, at + 42))
            let nameStart = at + 46, extraStart = nameStart + nameLength
            guard extraStart + extraLength + commentLength <= directory.count else { throw Failure.damaged("entry \(index + 1) runs past the directory") }
            let rawName = Array(directory[nameStart..<extraStart])
            var name = decodeName(rawName, utf8Flag: flags & 0x0800 != 0)
            // Extra fields: ZIP64 sizes (0x0001), Info-ZIP's UTF-8 name (0x7075).
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let id = le16(directory, extra), length = Int(le16(directory, extra + 2))
                let body = extra + 4
                guard body + length <= extraStart + extraLength else { break }
                if id == 0x0001 {
                    var field = body
                    if size == 0xFFFF_FFFF, field + 8 <= body + length { size = try int64(le64(directory, field)); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= body + length { compressed = try int64(le64(directory, field)); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= body + length { offset = try int64(le64(directory, field)) }
                } else if id == 0x7075, length > 5, directory[body] == 1 {
                    let nameCRC = le32(directory, body + 1)
                    if nameCRC == rawName.withUnsafeBufferPointer({ UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }),
                       let unicode = String(bytes: directory[(body + 5)..<(body + length)], encoding: .utf8) {
                        name = unicode
                    }
                }
                extra = body + length
            }
            at = extraStart + extraLength + commentLength
            let normalized = name.replacingOccurrences(of: "\\", with: "/")
            if normalized.hasPrefix("__MACOSX/") { continue }
            let isDirectory = normalized.hasSuffix("/")
            let host = madeBy >> 8
            let mode = (external >> 16) & 0xF000
            let components = safeComponents(normalized)
            var problem: String?
            if components == nil { problem = "Points outside the folder it would go in" }
            else if flags & 0x0001 != 0 || method == 99 { problem = "Password-protected; AOM doesn't open encrypted entries" }
            // Unix (3) and OS X (19) keep the file type in the high bits.
            else if host == 3 || host == 19, mode == 0xA000 { problem = "A symbolic link; links aren't extracted" }
            else if !isDirectory, method != 0, method != 8 { problem = "Compressed with method \(method), which AOM can't read; Archive Utility may" }
            entries.append(Entry(id: index, path: normalized, components: components, size: size, compressedSize: compressed,
                                 method: method, crc: crc, localHeaderOffset: offset, isDirectory: isDirectory,
                                 modified: dosDate(date: date, time: time), unsupported: problem))
        }
        // AppleDouble files ("._report.pdf" beside "report.pdf") hold Finder
        // metadata, not something to pick.
        let paths = Set(entries.map(\.path))
        return entries.filter { entry in
            let name = entry.name
            guard name.hasPrefix("._"), name.count > 2 else { return true }
            let sibling = (entry.folder.isEmpty ? "" : entry.folder + "/") + name.dropFirst(2)
            return ![sibling, sibling + "/", "/" + sibling, "/" + sibling + "/"].contains(where: paths.contains)
        }
    }

    /// Pure: a stored path's parts, or nil when it would climb out ("..")
    /// or is empty. A leading "/" is dropped (the path stays inside).
    static func safeComponents(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(where: { $0.contains("\0") }) else { return nil }
        return parts
    }

    /// Pure: UTF-8 when flagged or when the bytes are valid UTF-8 (macOS
    /// writes it unflagged), else Korean Windows (CP949), else DOS (CP437).
    static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text.precomposedStringWithCanonicalMapping }
        let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        if !utf8Flag, let text = String(bytes: bytes, encoding: korean) { return text }
        let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        return String(bytes: bytes, encoding: dos) ?? String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Extracting

    struct Outcome: Equatable {
        var written: [URL] = []
        /// "name: reason" for entries that weren't written.
        var failures: [String] = []
        var cancelled = false
    }

    /// Extracts `picked` into `folder`: with `keepFolders` under their
    /// folders inside the archive, else all at the top (a taken name gets a
    /// number). Unsupported entries are reported, never written.
    static func extract(_ picked: [Entry], from archive: URL, into folder: URL, keepFolders: Bool = true,
                        isCancelled: () -> Bool = { false }, progress: (Int64) -> Void = { _ in }) -> Outcome {
        var outcome = Outcome()
        let root = folder.standardizedFileURL
        guard let handle = try? FileHandle(forReadingFrom: archive) else {
            outcome.failures = picked.map { "\($0.name): the archive can't be opened" }
            return outcome
        }
        defer { try? handle.close() }
        var done: Int64 = 0
        for entry in picked where !entry.isDirectory {
            if isCancelled() { outcome.cancelled = true; break }
            guard entry.unsupported == nil, let components = entry.components else {
                outcome.failures.append("\(entry.name): \(entry.unsupported ?? "can't be extracted")")
                continue
            }
            let parts = keepFolders ? components : [components[components.count - 1]]
            do {
                let parent = try makeFolders(parts.dropLast(), in: root)
                let written = try write(entry, from: handle, toFolder: parent, name: parts[parts.count - 1], root: root,
                                        isCancelled: isCancelled) { done += $0; progress(done) }
                outcome.written.append(written)
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch {
                outcome.failures.append("\(entry.name): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Creates the folders on the way (keeping ones already there) and
    /// checks each stays inside `root`.
    private static func makeFolders(_ parts: ArraySlice<String>, in root: URL) throws -> URL {
        var folder = root
        for part in parts {
            folder.appendPathComponent(part, isDirectory: true)
            var status = stat()
            if lstat(folder.path, &status) == 0 {
                // A link already there isn't followed, even to a folder inside the destination.
                guard (status.st_mode & S_IFMT) != S_IFLNK else { throw Failure.unsupported("a link named “\(part)” is where its folder would go") }
                guard (status.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsupported("a file named “\(part)” is where its folder would go") }
            } else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            // A folder already there may be a link to somewhere else.
            guard resolvesInside(folder, root) else { throw Failure.outside(part) }
        }
        return folder
    }

    /// `url` with every link resolved lies in `root` (or is it).
    static func resolvesInside(_ url: URL, _ root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private static func write(_ entry: Entry, from handle: FileHandle, toFolder folder: URL, name: String, root: URL,
                              isCancelled: () -> Bool, wrote: (Int64) -> Void) throws -> URL {
        // The local header's name and extra lengths can differ from the directory's.
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, le32(header, 0) == 0x0403_4b50 else { throw Failure.damaged("\(entry.name)'s header is missing") }
        let dataStart = entry.localHeaderOffset + 30 + Int64(le16(header, 26)) + Int64(le16(header, 28))
        try handle.seek(toOffset: UInt64(dataStart))

        let temporary = folder.appendingPathComponent(".aom-unzip-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
              let output = try? FileHandle(forWritingTo: temporary) else {
            throw Failure.unsupported("the folder can't be written to")
        }
        var committed = false
        defer {
            try? output.close()
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        var crc: uLong = 0
        var produced: Int64 = 0
        let sink: (UnsafeRawBufferPointer) throws -> Void = { bytes in
            produced += Int64(bytes.count)
            guard produced <= entry.size else { throw Failure.damaged("\(entry.name) holds more than its listed size") }
            crc = crc32(crc, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
            // The throwing write: a full disk or a removed drive is an error here, not an exception.
            try output.write(contentsOf: Data(bytes))
            wrote(Int64(bytes.count))
        }
        var remaining = entry.compressedSize
        let chunk = 1 << 20
        if entry.method == 0 {
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                guard let data = try handle.read(upToCount: Int(min(Int64(chunk), remaining))), !data.isEmpty else {
                    throw Failure.damaged("\(entry.name) ends early")
                }
                remaining -= Int64(data.count)
                try data.withUnsafeBytes(sink)
            }
        } else {
            let inflater = try Inflater()
            var ended = false
            while remaining > 0, !ended {
                if isCancelled() { throw CancellationError() }
                guard let data = try handle.read(upToCount: Int(min(Int64(chunk), remaining))), !data.isEmpty else {
                    throw Failure.damaged("\(entry.name) ends early")
                }
                remaining -= Int64(data.count)
                ended = try inflater.process(data, last: remaining == 0, sink: sink)
            }
            guard ended else { throw Failure.damaged("\(entry.name)'s compressed data ends early") }
        }
        guard produced == entry.size else { throw Failure.damaged("\(entry.name) came out \(produced) bytes instead of \(entry.size)") }
        guard UInt32(crc) == entry.crc else { throw Failure.damaged("\(entry.name)'s checksum doesn't match") }
        try output.synchronize()
        try output.close()
        if let modified = entry.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path)
        }
        guard resolvesInside(folder, root) else { throw Failure.outside(name) }
        let final = try commitExclusive(temporary, in: folder, name: name)
        committed = true
        return final
    }

    /// Pure: "report.pdf", then "report 2.pdf"; "README" then "README 2".
    static func numberedName(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty || base.isEmpty ? "\(name) \(number)" : "\(base) \(number).\(ext)"
    }

    /// Renames `temporary` to the first free name, never replacing a file
    /// (RENAME_EXCL; a move to a name free now where the volume lacks it).
    static func commitExclusive(_ temporary: URL, in folder: URL, name: String) throws -> URL {
        for number in 1...999 {
            let candidate = folder.appendingPathComponent(numberedName(name, number))
            if renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            if code == ENOTSUP || code == EXDEV {
                if FileManager.default.fileExists(atPath: candidate.path) { continue }
                do { try FileManager.default.moveItem(at: temporary, to: candidate); return candidate }
                catch where (error as NSError).code == NSFileWriteFileExistsError { continue }
            }
            guard code == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Raw Deflate through the Compression framework.
    private final class Inflater {
        private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
        private let bufferSize = 1 << 16

        init() throws {
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                stream.deallocate(); buffer.deallocate()
                throw Failure.unsupported("Deflate isn't available")
            }
        }

        deinit {
            compression_stream_destroy(stream)
            stream.deallocate()
            buffer.deallocate()
        }

        /// True once the Deflate stream ended.
        func process(_ data: Data, last: Bool, sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Bool {
            try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Bool in
                stream.pointee.src_ptr = input.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
                stream.pointee.src_size = input.count
                while true {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = bufferSize
                    let status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let made = bufferSize - stream.pointee.dst_size
                    if made > 0 { try sink(UnsafeRawBufferPointer(start: buffer, count: made)) }
                    switch status {
                    case COMPRESSION_STATUS_END: return true
                    case COMPRESSION_STATUS_OK:
                        if stream.pointee.src_size == 0, made < bufferSize { return false }
                    default: throw Failure.damaged("the compressed data can't be read")
                    }
                }
            }
        }
    }

    // MARK: Bytes

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    private static func le64(_ bytes: [UInt8], _ at: Int) -> UInt64 { UInt64(le32(bytes, at)) | UInt64(le32(bytes, at + 4)) << 32 }

    private static func lastIndex(of signature: UInt32, in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in stride(from: bytes.count - 4, through: 0, by: -1) where le32(bytes, index) == signature { return index }
        return nil
    }

    private static func dosDate(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var components = DateComponents()
        components.year = 1980 + Int(date >> 9)
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return Calendar.current.date(from: components)
    }
}
