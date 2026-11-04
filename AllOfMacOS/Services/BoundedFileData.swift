import Foundation

enum BoundedFileData {
    enum Failure: Error, Equatable { case tooLarge(limit: Int) }

    /// Read at most limit + 1 bytes. Metadata alone cannot enforce a limit:
    /// a file can grow or be atomically replaced between stat and open.
    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes >= 0 && maximumBytes < Int.max)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= maximumBytes {
            let remaining = maximumBytes + 1 - result.count
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count <= maximumBytes else { throw Failure.tooLarge(limit: maximumBytes) }
        return result
    }
}
