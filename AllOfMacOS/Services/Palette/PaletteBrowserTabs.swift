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
        /// Window and tab positions from 1, as read (they change when tabs move).
        let window: Int
        let index: Int
        let title: String
        let url: String
        /// 7.5 (Codex D04): the browser's own ids where it has them —
        /// Chromium and Arc tabs, every browser's windows. Safari tabs have none.
        var windowID: String? = nil
        var tabID: String? = nil

        var id: String { "\(browser.bundleID)|\(tabID ?? "\(window)/\(index)")|\(url)" }
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

    /// The JXA that prints {"windows": [{index, id, titles, urls, ids} | {index, id, error}]}.
    /// 7.5 (Codex D03): a window's values are all read before its record
    /// is added, so one window that fails can't shift the next one's tabs.
    static func readScript(_ browser: Browser) -> String {
        let title = browser.isSafari ? "name" : "title"
        return """
        const app = Application(\(jsString(browser.bundleID)));
        const windows = [];
        const all = app.windows();
        for (let i = 0; i < all.length; i++) {
          const w = all[i];
          let id = null;
          try { id = String(w.id()); } catch (e) {}
          try {
            const titles = w.tabs.\(title)();
            const urls = w.tabs.url();
            let ids = null;
            \(browser.isSafari ? "" : "try { ids = w.tabs.id().map(String); } catch (e) {}")
            windows.push({index: i + 1, id, titles, urls, ids});
          } catch (e) {
            windows.push({index: i + 1, id, error: String(e)});
          }
        }
        JSON.stringify({windows});
        """
    }

    struct Read: Equatable {
        var tabs: [Tab] = []
        /// Windows whose tabs couldn't be read.
        var failedWindows = 0
    }

    /// Pure: the script's JSON to tabs (window and tab numbers from 1).
    static func parse(_ json: String, browser: Browser) -> Read {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = object["windows"] as? [[String: Any]] else { return Read() }
        var read = Read()
        for window in windows {
            let position = (window["index"] as? Int) ?? 0
            let windowID = window["id"].flatMap { $0 is NSNull ? nil : "\($0)" }
            guard window["error"] == nil, let titles = window["titles"] as? [Any], let urls = window["urls"] as? [Any] else {
                read.failedWindows += 1
                continue
            }
            let ids = (window["ids"] as? [Any]).flatMap { $0.count == urls.count ? $0.map { "\($0)" } : nil }
            for (t, rawURL) in urls.enumerated() {
                guard let url = rawURL as? String, !url.isEmpty else { continue }
                let rawTitle = t < titles.count ? titles[t] as? String : nil
                let title = rawTitle.flatMap { $0.isEmpty ? nil : $0 } ?? url
                read.tabs.append(Tab(browser: browser, window: position, index: t + 1, title: title, url: url,
                                     windowID: windowID, tabID: ids?[t]))
            }
        }
        return read
    }

    // MARK: Showing a tab (7.5, Codex D04)

    enum Resolution: Equatable {
        /// The tab where it is now; `moved` when an id-matched tab shows another address.
        case found(Tab, moved: Bool)
        case closed
        /// Several open tabs fit what was listed (the same address twice).
        case ambiguous(Int)
    }

    /// Pure: the tab the user picked among the tabs open now. An id finds
    /// the tab wherever it went; without one (Safari) the address must
    /// pick out one tab, narrowed by title, window and position.
    static func resolve(_ picked: Tab, in current: [Tab]) -> Resolution {
        let same = current.filter { $0.browser.bundleID == picked.browser.bundleID }
        if let tabID = picked.tabID {
            guard let tab = same.first(where: { $0.tabID == tabID }) else { return .closed }
            return .found(tab, moved: tab.url != picked.url)
        }
        var candidates = same.filter { $0.url == picked.url }
        for narrow in [{ (t: Tab) in t.title == picked.title },
                       { (t: Tab) in picked.windowID != nil && t.windowID == picked.windowID },
                       { (t: Tab) in t.window == picked.window && t.index == picked.index }] where candidates.count > 1 {
            let narrower = candidates.filter(narrow)
            if !narrower.isEmpty { candidates = narrower }
        }
        switch candidates.count {
        case 0: return .closed
        case 1: return .found(candidates[0], moved: false)
        default: return .ambiguous(candidates.count)
        }
    }

    /// JXA that shows the tab and brings its window and browser forward.
    /// With an id the tab is looked up by it when the script runs; the
    /// positions are the ones just read. Prints "ok" or "closed".
    static func activateScript(_ tab: Tab) -> String {
        let find: String
        if let tabID = tab.tabID {
            find = """
            let w = null, k = -1;
            for (const candidate of app.windows()) {
              let ids = [];
              try { ids = candidate.tabs.id().map(String); } catch (e) { continue; }
              const at = ids.indexOf(\(jsString(tabID)));
              if (at >= 0) { w = candidate; k = at; break; }
            }
            """
        } else {
            // No tab ids (Safari): the window by its id when known, then the
            // address checked at the position just read, else looked up in that window.
            let windowID = tab.windowID.map(jsString) ?? "null"
            find = """
            const all = app.windows();
            let w = null, k = -1;
            if (\(windowID) !== null) { for (const c of all) { try { if (String(c.id()) === \(windowID)) { w = c; break; } } catch (e) {} } }
            if (w === null && \(windowID) === null && all.length >= \(tab.window)) { w = all[\(tab.window - 1)]; }
            if (w !== null) {
              let urls = [];
              try { urls = w.tabs.url(); } catch (e) {}
              k = urls[\(tab.index - 1)] === \(jsString(tab.url)) ? \(tab.index - 1) : urls.indexOf(\(jsString(tab.url)));
            }
            """
        }
        let show: String
        if tab.browser.isSafari {
            show = "w.currentTab = w.tabs[k]; w.index = 1;"
        } else if tab.browser.isArc {
            show = "w.tabs[k].select();"
        } else {
            show = "w.activeTabIndex = k + 1; w.index = 1;"
        }
        return """
        const app = Application(\(jsString(tab.browser.bundleID)));
        \(find)
        if (w === null || k < 0 || k >= w.tabs.length) { "closed"; } else {
          \(show)
          app.activate();
          "ok";
        }
        """
    }

    struct Scan: Equatable {
        var tabs: [Tab]
        /// "Safari: not allowed to control it" for browsers that refused,
        /// "Chrome: 1 window couldn't be read" beside the tabs that were.
        var problems: [String]
    }

    /// One browser's tabs now.
    static func read(_ browser: Browser) async -> Result<Read, AOMAIError> {
        await run(["-l", "JavaScript", "-e", readScript(browser)]).map { parse($0, browser: browser) }
    }

    /// Every running browser's tabs, read in parallel.
    static func scan() async -> Scan {
        if PresetManager.isUIPreview { return Scan(tabs: samples, problems: []) }
        let running = await MainActor.run {
            browsers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
        }
        return await withTaskGroup(of: (Browser, Result<Read, AOMAIError>).self) { group in
            for browser in running {
                group.addTask { (browser, await read(browser)) }
            }
            var scan = Scan(tabs: [], problems: [])
            for await (browser, result) in group {
                switch result {
                case .success(let read):
                    scan.tabs += read.tabs
                    if read.failedWindows > 0 {
                        scan.problems.append("\(browser.name): \(read.failedWindows) window\(read.failedWindows == 1 ? "" : "s") couldn't be read")
                    }
                case .failure(let problem): scan.problems.append("\(browser.name): \(problem.message)")
                }
            }
            let order = Dictionary(uniqueKeysWithValues: browsers.enumerated().map { ($1.bundleID, $0) })
            scan.tabs.sort { (order[$0.browser.bundleID] ?? 0, $0.window, $0.index) < (order[$1.browser.bundleID] ?? 0, $1.window, $1.index) }
            scan.problems.sort()
            return scan
        }
    }

    enum ActivateResult: Equatable {
        case shown(moved: String?)
        case closed
        case ambiguous(Int)
        case failed(String)

        /// Nil when the tab came forward as listed.
        var message: String? {
            switch self {
            case .shown(nil): return nil
            case .shown(let host?): return "That tab now shows \(host)"
            case .closed: return "That tab is closed now"
            case .ambiguous(let count): return "\(count) open tabs show that address; open Browser Tabs again to pick one"
            case .failed(let reason): return "Couldn't show the tab: \(reason)"
            }
        }
    }

    /// Reads the browser again, finds the tab picked (by id, or by an
    /// address that picks out one tab) and shows it.
    static func activate(_ tab: Tab) async -> ActivateResult {
        if PresetManager.isUIPreview { return .shown(moved: nil) }
        let current: Read
        switch await read(tab.browser) {
        case .success(let read): current = read
        case .failure(let problem): return .failed(problem.message)
        }
        switch resolve(tab, in: current.tabs) {
        case .closed: return .closed
        case .ambiguous(let count): return .ambiguous(count)
        case .found(let now, let moved):
            switch await run(["-l", "JavaScript", "-e", activateScript(now)]) {
            case .success(let answer) where answer == "ok": return .shown(moved: moved ? now.host : nil)
            case .success: return .closed
            case .failure(let problem): return .failed(problem.message)
            }
        }
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
