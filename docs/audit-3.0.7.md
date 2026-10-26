# 3.0.6 release audit → 3.0.7

Baseline: `ccba426edda9cc2b2e6ce1f18196ad9d70bd2384`, latest release
`aom-v3.0.6-b2026102506-gccba426edda9`. At audit start, main matched the release.

## Scope

Repository-wide file inventory and suspicious-code searches covered 204 application
Swift files, 86 test files, 3 extension Swift files, the XPC helper, scripts and
workflows. Searches included unfinished/dummy markers, fatal errors, synchronous
I/O/process calls, timers, detached tasks and disabled code. Focused source review
covered audio transport/rendering/EQ, script execution/XPC, automation links and
control flow, clipboard encryption/thumbnail paths, annotation/shared-image input
validation, recording exports, system file utilities and release workflows.
This is a static audit plus the existing macOS CI suite, not a claim that every
line or every UI/hardware combination has been independently verified.

## Confirmed defects fixed

| Path | Previous behavior | Correction / regression coverage |
| --- | --- | --- |
| System Tools .DS_Store cleanup | Hidden-file skipping excludes the files it promises to delete | Include hidden entries; test root and nested hidden directories |
| Lock/hide file flags | chflags replaces all flags, clearing unrelated flags | Read/modify only the requested bit using lstat/lchflags; preserve UF_HIDDEN/UF_NODUMP across lock/unlock |
| Batch rename | Swallows move errors, returns nonexistent destinations, interprets replacement templates, adds trailing dot | Preflight names/collisions; literal replacements; preserve extensionless names; propagate move failure |
| WebP conversion | ImageIO cannot reliably encode WebP; fallback could be another format | Use bundled libwebp; verify RIFF/WEBP bytes; reject existing output |
| Cache accounting | Reports size before removal even if deletion fails; misses top-level files | Count successful removal only and include regular files |
| Cache isolation | Test deletes actual user caches; case-sensitive own-cache exclusion | Disposable injected root and case-insensitive own-cache exclusion |
| GIF cancellation | Detached worker ignores parent cancellation | Forward cancellation and check before finalizing/publishing; temporary GIF is cleaned up |
| Automation URL alias | Host switch lowercases but alias argument validation does not | Normalize host once; regression for uppercase TRIGGER_NAMED |

## Dummy-code findings and remaining limits

- UpdateChecker deliberately bypasses real URLSession requests and periodic polling
  for custom builds. The private release API also requires authentication. Do not
  interpret its mock-network tests as a working automatic update feature. No
  updater or embedded GitHub credential was enabled in this patch.
- Fatal errors found in programmatic-only NSView initializer paths and the abstract
  AppleScript command base are explicit programmer preconditions, not user-facing
  placeholder features. Concrete script commands override the base route.
- Audio buffers are preallocated and callbacks use try-locks. Existing source
  guards validate external image/document input and encrypt clipboard archives.
  Inspection of these paths alone is not a hardware/security certification.
- System operations such as DNS flush, Finder restart, Wi-Fi interface selection
  and cache deletion still depend on OS permissions and machine configuration;
  this patch does not certify those live operations. Batch rename is preflighted,
  but an external filesystem change during execution can still cause a partially
  completed batch followed by an error (no transactional rollback).
- Interactive HomePod/AirPlay, permissions, ScreenCaptureKit, OCR and UI flows
  require a real Mac session. Linux cannot run AppKit/AVFoundation/Swift tests.

## Validation

- Local: all tracked shell/command scripts passed bash syntax checks;
  git diff whitespace check passed; version/build metadata inspected.
- GitHub Actions: the trusted-main signed-release workflow runs the full Swift
  suite except its existing 15 headless-incompatible OCR integration tests, then
  builds, signs app/XPC, verifies signatures and verifies/packages the DMG.
  Actual run status is available on the release's source commit in GitHub Actions.
- Existing signing policy remains AOM Dev self-signed, without Apple notarization.
