import AppKit

/// 7.4 (Raycast "Search Browser Tabs"): the open tabs of every running
/// Safari and Chromium browser, read with one JavaScript for Automation call
/// per browser, and ↩ brings a tab to the front. Browsers that aren't
/// running are left alone; each one asks once for Automation permission.
enum PaletteBrowserTabs {
    struct Browser: Equatable {
        let bundleID: String
        let name: String
        /// Safari names a tab's title `name`; Chromium browsers `title`.
        let isSafari: Bool
        /// Arc selects a tab with `select`, not `active tab index`.
        let isArc: Bool
    }

    struct Tab: Identifiable, Equatable {
        let browser: Browser
        let window: Int
        let index: Int
        let title: String
        let url: String

        var id: String { "\(browser.bundleID)|\(window)|\(index)|\(url)" }
        var host: String { URL(string: url)?.host ?? url }
    }

    static let browsers: [Browser] = [
        .init(bundleID: "com.apple.Safari", name: "Safari", isSafari: true, isArc: false),
        .init(bundleID: "com.google.Chrome", name: "Chrome", isSafari: false, isArc: false),
        .init(bundleID: "company.thebrowser.Browser", name: "Arc", isSafari: false, isArc: true),
        .init(bundleID: "com.microsoft.edgemac", name: "Edge", isSafari: false, isArc: false),
        .init(bundleID: "com.brave.Browser", name: "Brave", isSafari: false, isArc: false),
        .init(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", isSafari: false, isArc: false),
    ]

    /// The JXA that prints {"titles": [[…]], "urls": [[…]]}.
    static func readScript(_ browser: Browser) -> String {
        let title = browser.isSafari ? "name" : "title"
        return """
        const app = Application(\(jsString(browser.bundleID)));
        const titles = [], urls = [];
        for (const w of app.windows()) {
          try { titles.push(w.tabs.\(title)()); urls.push(w.tabs.url()); } catch (e) { titles.push([]); urls.push([]); }
        }
        JSON.stringify({titles, urls});
        """
    }

    /// Pure: the script's JSON to tabs (window and tab numbers from 1).
    static func parse(_ json: String, browser: Browser) -> [Tab] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let titles = object["titles"] as? [[Any]], let urls = object["urls"] as? [[Any]] else { return [] }
        var tabs: [Tab] = []
        for (w, windowTitles) in titles.enumerated() where w < urls.count {
            let windowURLs = urls[w]
            for (t, rawTitle) in windowTitles.enumerated() where t < windowURLs.count {
                let url = windowURLs[t] as? String ?? ""
                let title = (rawTitle as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
                guard !url.isEmpty else { continue }
                tabs.append(Tab(browser: browser, window: w + 1, index: t + 1, title: title, url: url))
            }
        }
        return tabs
    }

    /// AppleScript that shows the tab and brings its window and browser forward.
    static func activateScript(_ tab: Tab) -> String {
        let app = "application id \"\(tab.browser.bundleID)\""
        if tab.browser.isSafari {
            return "tell \(app)\nset current tab of window \(tab.window) to tab \(tab.index) of window \(tab.window)\nset index of window \(tab.window) to 1\nactivate\nend tell"
        }
        if tab.browser.isArc {
            return "tell \(app)\ntell window \(tab.window) to tell tab \(tab.index) to select\nactivate\nend tell"
        }
        return "tell \(app)\nset active tab index of window \(tab.window) to \(tab.index)\nset index of window \(tab.window) to 1\nactivate\nend tell"
    }

    struct Scan: Equatable {
        var tabs: [Tab]
        /// "Safari: not allowed to control it" for browsers that refused.
        var problems: [String]
    }

    /// Every running browser's tabs, read in parallel.
    static func scan() async -> Scan {
        if PresetManager.isUIPreview { return Scan(tabs: samples, problems: []) }
        let running = await MainActor.run {
            browsers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
        }
        return await withTaskGroup(of: (Browser, Result<String, AOMAIError>).self) { group in
            for browser in running {
                group.addTask { (browser, await run(["-l", "JavaScript", "-e", readScript(browser)])) }
            }
            var scan = Scan(tabs: [], problems: [])
            for await (browser, result) in group {
                switch result {
                case .success(let json): scan.tabs += parse(json, browser: browser)
                case .failure(let problem): scan.problems.append("\(browser.name): \(problem.message)")
                }
            }
            let order = Dictionary(uniqueKeysWithValues: browsers.enumerated().map { ($1.bundleID, $0) })
            scan.tabs.sort { (order[$0.browser.bundleID] ?? 0, $0.window, $0.index) < (order[$1.browser.bundleID] ?? 0, $1.window, $1.index) }
            scan.problems.sort()
            return scan
        }
    }

    static func activate(_ tab: Tab) {
        Task.detached { _ = await run(["-e", activateScript(tab)]) }
    }

    /// osascript with a 10 s limit; the error names a missing permission.
    /// Output is read while it runs, so a long tab list can't fill the pipe.
    private static func run(_ arguments: [String]) async -> Result<String, AOMAIError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = arguments
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do { try process.run() } catch {
                    continuation.resume(returning: .failure(AOMAIError(message: error.localizedDescription))); return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
                let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                deadline.cancel()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(out.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else if err.contains("-1743") || err.localizedCaseInsensitiveContains("not authorized") {
                    continuation.resume(returning: .failure(AOMAIError(message: "allow AOM in System Settings › Privacy & Security › Automation")))
                } else if process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: .failure(AOMAIError(message: "didn't answer within 10 seconds")))
                } else {
                    continuation.resume(returning: .failure(AOMAIError(message: err.split(separator: "\n").last.map(String.init) ?? "osascript failed")))
                }
            }
        }
    }

    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data()
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    static let samples: [Tab] = [
        Tab(browser: browsers[0], window: 1, index: 1, title: "Apple Developer Documentation", url: "https://developer.apple.com/documentation"),
        Tab(browser: browsers[1], window: 1, index: 1, title: "All-of-MacOS · GitHub", url: "https://github.com/"),
        Tab(browser: browsers[1], window: 1, index: 2, title: "Google AI Studio", url: "https://aistudio.google.com/"),
    ]
}
