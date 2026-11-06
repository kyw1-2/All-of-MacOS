import Foundation

enum AppRelaunch {
    static func arguments(pid: Int32, bundlePath: String) -> [String] {
        // Parameters are positional, never interpolated shell source. Wait for
        // termination cleanup (HID mappings, output route, settings) to finish.
        ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open \"$2\"",
         "aom-relaunch", String(pid), bundlePath]
    }
}
