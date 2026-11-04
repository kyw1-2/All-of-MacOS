# Resource efficiency patch — 2026-11-04

Base: a0c8a11 (3.4.11). Scope: local commit only; no push, version bump, workflow dispatch or release.

## Changes and evidence

| Path | Observed work/retention | Change |
| --- | --- | --- |
| ResilientFileWatcher | A one-second timer stats each watched path even when both kernel watches are armed. | Keep kernel event handling immediate; use a 30-second sanity poll with tolerance while both watches are armed. Retry every second when either watch is unavailable. Stop still tears down all sources and timers. |
| ClipboardAppMetadata | File icons are all discarded after the cache fills; app icons, missing-app records, colors and text-contrast decisions have no entry bounds. | Evict least-recently-used entries individually. Caps: 300 file icons, 128 app icons, 128 missing-app entries, 512 colors, 512 contrast decisions. Image representations and display sizes are preserved. |
| AOMStudioBackgroundImages | Four background images have only a count bound, then the entire cache is cleared. Four 4096-square RGBA8 images alone can retain about 256 MiB of decoded pixels. | Limit cached decoded pixel costs to 96 MiB and four entries. Retain hot backgrounds and evict only enough old entries. Disable source-image caching. High-bit-depth thumbnails that exceed the budget are retried at smaller dimensions before insertion, avoiding an uncacheable image being decoded each frame. |
| PaletteBookmarkLoader | Bookmark reads trust a prior file-size query; the browser Local State file is read without a size limit. | Read no more than 32 MiB plus one sentinel byte. Reject oversized data rather than parsing a truncated result. Bound Local State reads too; preserve file-access error handling. |

The new small LRU helper has O(1) hits, scans only when evicting, accounts for replacement/removal costs, and avoids integer overflow. Owners retain their existing main-actor or lock synchronization.

## Validation performed

- Swift 6.0.3 on Linux, in Swift 5.9 language mode: 13 XCTest cases passed, zero failures. The harness compiles exact copies of BoundedLRUCache.swift, BoundedFileData.swift and FileWatcherPolling.swift and the committed ResourceEfficiencyTests.swift. It does not stub or compile the macOS application.
- Tests cover count/cost eviction, hot-entry preservation, replacement and invalidation, oversized entries, extreme costs, deallocation after eviction, 10,000 mixed operations, exact/oversized/empty/missing/replaced files, and healthy/degraded watcher cadence.
- Swift parser checks passed for all ten added/modified Swift implementation and test files. These are syntax checks, not AppKit type checking.
- Shell syntax and git whitespace checks passed.
- Three macOS integration tests were added for immediate atomic-replacement notifications, missing-parent recovery/timer shutdown and Studio hot-image reuse/invalidation. They were not executed because the Mac connection was offline.
- The full macOS build, existing app suite, UI behavior, real idle CPU and resident-memory measurements remain unverified for this commit. No CI was dispatched or source pushed.

## Practical limits

The 96 MiB budget covers pixel storage retained by the background cache, not GPU allocations, transient decode memory or images retained by active renders. Metadata icon caches have entry limits, not byte limits. High-bit-depth backgrounds may be downsampled below 4096 pixels to fit. Normal file events are immediate; a missed kernel event can take up to the 30-second sanity interval plus timer tolerance to be detected. Missing watches retain the one-second retry path. These changes establish resource bounds and reduce scheduled work; no measured CPU/battery improvement is claimed.

Reproduce portable tests with Swift installed:

    bash scripts/test-resource-policies.sh

When macOS is available, run the normal application test suite, including ResourceEfficiencyMacTests and the existing watcher/recording/bookmark tests, before release.
