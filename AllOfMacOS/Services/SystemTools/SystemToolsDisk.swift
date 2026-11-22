import AppKit

/// Volumes with their space (DaisyDisk / Stats style bars), eject, the
/// read-only `diskutil verifyVolume`, Time Machine status and local
/// snapshots through `tmutil`. Output parsers are pure and unit tested.
enum DiskTools {
    struct Volume: Equatable, Identifiable, Sendable {
        var id: String { url.path }
        let url: URL
        let name: String
        let total: Int64
        let available: Int64
        let isInternal: Bool
        let isEjectable: Bool

        var used: Int64 { max(0, total - available) }
        /// 0…1, for the storage bars.
        var usedFraction: Double { DiskTools.usedFraction(total: total, available: available) }
    }

    static func usedFraction(total: Int64, available: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(total - available) / Double(total)))
    }

    /// Browsable volumes the user sees in Finder's sidebar (no hidden
    /// system, VM or Preboot volumes), startup disk first.
    static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return Volume(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent, total: Int64(total), available: available,
                          isInternal: values.volumeIsInternal ?? false,
                          isEjectable: url.path != "/" && (values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false))
        }.sorted { lhs, rhs in
            if (lhs.url.path == "/") != (rhs.url.path == "/") { return lhs.url.path == "/" }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Time Machine

    struct BackupStatus: Equatable {
        let running: Bool
        let phase: String?
        /// 0…1 while copying, nil otherwise (tmutil says -1).
        let progress: Double?
    }

    /// `tmutil status` prints a header line, then an old-style property list
    /// ({ Running = 0; Percent = "-1"; BackupPhase = Copying; … }).
    static func parseBackupStatus(_ text: String) -> BackupStatus? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let body = Data(text[start...end].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else { return nil }
        func double(_ key: String) -> Double? {
            if let number = plist[key] as? NSNumber { return number.doubleValue }
            return (plist[key] as? String).flatMap(Double.init)
        }
        let running = (double("Running") ?? 0) != 0
        let percent = double("Percent") ?? -1
        return BackupStatus(running: running, phase: plist["BackupPhase"] as? String,
                            progress: running && percent >= 0 ? min(1, percent) : nil)
    }

    /// `tmutil listlocalsnapshots /`: a header, then one name per line.
    static func parseLocalSnapshots(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
    }


    /// Asks macOS to purge up to 20 GB of Time Machine local snapshots now,
    /// at the highest urgency.
}
