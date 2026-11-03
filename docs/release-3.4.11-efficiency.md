# All of MacOS 3.4.11 — background efficiency

This update reduces repeated input registrations and background work while preserving existing input and permission recovery behavior.

- Trackpad event observation uses one global and one local NSEvent monitor instead of nine of each. Local events still pass through unchanged; mouse suppression taps retain their existing role.
- Accessibility checks run every 10 seconds while healthy, with a 2-second confirmation/recovery interval after a failed check. Activation and wake check immediately. Permission revocation remains detectable; checks are never permanently disabled after a grant.
- System status publishes one coherent snapshot per sample instead of up to nine separate property notifications. Identical snapshots do not publish. CPU/memory sampling remains at two seconds; disk, battery and network inventory refresh every fifth sample and on reopening.
- Expensive System Tools subprocess reads have a separate minimum 30-second cadence (the four-second UI timer checks whether they are due). Explicit actions invalidate the cache. In-flight results from an older action or visibility session cannot overwrite current state, and hidden pages do not start new refresh batches.
- Power-assertion inspection uses the public IOKit API instead of spawning and parsing pmset. Inactive assertions are excluded, duplicate display rows are collapsed, and read errors remain visible.
- Window-snap geometry, recognition, commit behavior and preview rendering are separate source files. Clipboard state and app metadata are isolated from the shelf view. These are declaration moves, preserving their implementations.

## Validation

Eight focused regression tests cover permission loss/recovery and observer cleanup, stopping during recovery, status publication count, refresh cadence/invalidation, hidden-page behavior, native assertion parsing and mouse-event routing. The signed release workflow runs these and the existing headless macOS suite before building, signing and verifying the DMG. Final execution results are recorded on the GitHub release.

## Evidence and scope

The original static report counted 77 local/global monitor call sites together, not 77 simultaneously active global taps. Source size and @Published counts alone do not establish a measured CPU leak or a build-time cause. Battery and disk-capacity readers already use native APIs. This patch targets confirmed repeated work, rather than converting every observable model or replacing operation-specific tools such as disk verification.

Expected operation-count reductions are visible in code and regression tests; no claim is made about measured CPU percentage, battery life or build-time speedup. There is no runtime performance benchmark on the user's Mac in this release. New menu-bar organization, monitor hardware control, charging limits and hardware sensors are separate feature work.

Public power-assertion contract: https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h (IOPMCopyAssertionsByProcess).
