import AppKit

/// Isolated previews only (`--aom-preview-bench <out.json>`): visits every
/// page a few times and records how long the main thread stays busy after
/// each switch — from the selection change to the first time the run loop
/// is about to wait again (view update, layout and the display commit).
/// Accessibility stays off, unlike timing the window from another process.
/// `first` says whether the switch built the page (the window keeps pages
/// once visited) or showed one already built. `cpu_ms` is the main thread's
/// own CPU time (user + system) over the same interval as `ms`, so it does
/// not grow when other work on the Mac delays the main thread.
@MainActor
enum AOMPageSwitchBench {
    static func runIfRequested(_ appState: AppState) {
        let args = ProcessInfo.processInfo.arguments
        guard PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-bench"),
              args.indices.contains(index + 1) else { return }
        let output = args[index + 1]
        var plan: [AOMMainTab] = []
        // `--aom-preview-bench-only <page title>` alternates that page with
        // Workspace, for profiling one page.
        if let only = args.firstIndex(of: "--aom-preview-bench-only"), args.indices.contains(only + 1),
           let tab = AOMMainTab.allCases.first(where: { $0.title == args[only + 1] }) {
            for _ in 0..<12 { plan += [tab, .home] }
        } else {
            for _ in 0..<3 { plan += AOMMainTab.allCases.filter { $0 != .home } + [.home] }
        }
        var results: [[String: Any]] = []
        func step(_ position: Int) {
            guard position < plan.count else {
                let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted])
                try? data?.write(to: URL(fileURLWithPath: output))
                NSApp.terminate(nil)
                return
            }
            let tab = plan[position]
            let first = !AOMNavigation.shared.createdPages.contains(tab)
            let startCPU = mainThreadCPUSeconds()
            let start = CACurrentMediaTime()
            appState.selectedMainTab = tab
            settle { busy in
                let cpu = mainThreadCPUSeconds() - startCPU
                results.append(["round": position / (AOMMainTab.allCases.count), "page": tab.title,
                                "ms": (busy - start) * 1000, "cpu_ms": cpu * 1000, "first": first])
                // Let timers and deferred work of the page run before moving on.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { step(position + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { step(0) }
    }

    /// The calling thread's user + system CPU time, in seconds.
    private static func mainThreadCPUSeconds() -> Double {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let seconds = info.user_time.seconds + info.system_time.seconds
        let microseconds = info.user_time.microseconds + info.system_time.microseconds
        return Double(seconds) + Double(microseconds) / 1_000_000
    }

    /// Calls back the first time the main run loop is about to sleep.
    private static func settle(_ done: @escaping (CFTimeInterval) -> Void) {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            done(CACurrentMediaTime())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
