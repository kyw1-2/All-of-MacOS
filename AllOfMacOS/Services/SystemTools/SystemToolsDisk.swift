import AppKit

/// Volumes with their space (DaisyDisk / Stats style bars), eject, the
/// read-only `diskutil verifyVolume`, Time Machine status and local
/// snapshots through `tmutil`. Output parsers are pure and unit tested.
enum DiskTools {
    struct Volume: Equatable, Identifiable {
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

    // MARK: diskutil verifyVolume

    struct VerifyResult: Equatable {
        let ok: Bool
        let summary: String
    }

    /// `diskutil verifyVolume` prints fsck_apfs progress and ends with
    /// "The volume … appears to be OK" or an error line; the exit status is
    /// the final word. Only the last informative line is kept for display.
    static func parseVerify(_ output: String, status: Int32) -> VerifyResult {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let okLine = lines.last { $0.localizedCaseInsensitiveContains("appears to be OK") }
        let problem = lines.last { $0.hasPrefix("Error") || $0.localizedCaseInsensitiveContains("could not be verified")
            || $0.localizedCaseInsensitiveContains("needs to be repaired") }
        if status == 0, problem == nil {
            return VerifyResult(ok: true, summary: okLine ?? "The startup volume appears to be OK")
        }
        return VerifyResult(ok: false, summary: problem ?? lines.last ?? "diskutil exited with status \(status)")
    }

    static func verifyArguments() -> [String] { ["verifyVolume", "/"] }

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

    static func backupStatusText(_ status: BackupStatus) -> String {
        guard status.running else { return "Not backing up" }
        let phase = status.phase.map { " (\($0))" } ?? ""
        if let progress = status.progress { return "Backing up\(phase), \(Int((progress * 100).rounded()))%" }
        return "Backing up\(phase)"
    }

    /// `tmutil destinationinfo` says "No destinations configured" (exit 0 on
    /// some versions, non-zero on others) when Time Machine isn't set up.
    static func hasDestination(_ output: SystemToolsCommand.Output) -> Bool {
        output.succeeded && !(output.stdout + output.stderr).localizedCaseInsensitiveContains("No destinations configured")
            && (output.stdout.contains("Name") || output.stdout.contains("ID"))
    }

    /// `tmutil listlocalsnapshots /`: a header, then one name per line.
    static func parseLocalSnapshots(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
    }

    /// Snapshots Time Machine made (and can thin); the others belong to
    /// macOS updates and are managed by macOS.
    static func isTimeMachineSnapshot(_ name: String) -> Bool { name.hasPrefix("com.apple.TimeMachine.") }

    /// Asks macOS to purge up to 20 GB of Time Machine local snapshots now,
    /// at the highest urgency.
    static let thinArguments = ["thinlocalsnapshots", "/", "20000000000", "4"]
}
