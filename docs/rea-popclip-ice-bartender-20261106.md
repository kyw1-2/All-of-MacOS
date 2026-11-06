# AOM 3.4.18: Oracle-host REA verification — PopClip, Ice, Bartender

Analyzed exclusively on Oracle Linux aarch64, 2026-11-06. All three applications were obtained from their official distribution locations and extracted statically, **not executed**. PopClip and Ice were officially distributed as ZIP rather than DMG. Bartender 7 was actually distributed in a DMG with an APFS filesystem.

| App | Verified bundle | Observed features |
| --- | --- | --- |
| PopClip | com.pilotmoon.popclip, 2026.8.1 | PopSelectionWrapper, selectionBounds, getBarRect:textRect:attributes:, PopClipEventMonitor; draggable selection context and floating action control |
| Ice | com.jordanbaird.Ice, 0.11.12 | IceBarPanel, MenuBarItemManager, MenuBarSearchPanel, MenuBarItemImageCache; floating bar and searchable items |
| Bartender | com.surteesstudios.Bartender, 7.1.0 | AXMenuBarItemMetadata, BartenderBarFloatingPanel, MenuBarItemVisibilityController, MenuBarWindowSnapshotInfo; secondary bar and metadata-driven item management |

## Evidence provenance

Distributions and extracted applications live at /data/re/20261106-aom-popclip-menubar/. SHA256 of thinned, original arm64 Mach-O executable images:
- PopClip 54a61407a8bb9cc5006731785c03ce3eb167cae19e82ec09a11a1a32a728651b
- Ice c3b27339a640994c5225a4391c6a14a3c10978f9fea8a1a39e20cc4a3ae6bbfc
- Bartender 538dd2efedc248cf55bb7992e3fbffd51a78f3be442a6b8cb25b364c9d279b0a

REA/Ghidra 12.1.4 source metadata analysis: PopClip-2026.8.1-ghidra.json, Ice-0.11.12-ghidra.json, Bartender-7.1.0-ghidra.json. REA inspect-macho requires macOS and does not execute on Oracle Linux; only Ghidra ARM64 static analysis was used. Symbol/strings metadata prove class names and concepts, not algorithmic equivalence or reliable behavior of proprietary apps.

## AOM feature specification and acceptance criteria

**#1 PopClip**: Reuse the existing 3.4 Text Actions UI and AX selection reader. AOM now waits 0.42 seconds after a double-click before showing the bar so a subsequent third click can cancel it. Drag and triple-click timing remain unchanged. User-configurable ChatGPT instructions can interpolate selected text using {text}, or append the selection. Nothing is sent remotely automatically; user must explicitly invoke the action and paste from clipboard. Text Actions remain disabled unless enabled by user and continue to honor AX secure text and excluded apps. Tests cover settings migration and app prompt output.

**#4 Ice/Bartender**: Accessible menu bar extras are enumerated by AXExtrasMenuBar / AXMenuBar. A searchable, pinned, secondary floating panel can activate an item through AXPress after resolving its identifier again. Hover activation is opt-in, requires the pointer at screen top center for at least 0.45 seconds, and uses no additional event tap. Menu bar icons remain in their original owning apps: macOS 27 may consolidate extras into one WindowServer layer, so forcibly moving/blanking other apps' NSStatusItems or synthesizing clicks based on arbitrary window positions is not safe or implementable via supported API. This release does **not** claim genuine cross-app status item hiding. It implements the useful secondary bar, search and launch independently.

**Audio reliability**: Existing tap handling already maintains 100% gain in-place, creates capture-only aggregates with sub-tap drift compensation, and uses a limiter. Main physical output should not be inserted as a capture aggregate's main subdevice. Release muted taps before sleep; delay rebuilding 1.5 seconds after wake to let CoreAudio re-enumerate, release empty local AVAudioEngine graphs after 15 seconds. The user-set native AirPlay bypass remains unchanged, since macOS/Chrome/HomePod CoreAudio overrun errors can occur even when AOM captures nothing. No claim of root-cause resolution without live listening confirmation.

All modifications are independent AOM source, not copied reverse-engineered code or icons. Ice's GPL code is not redistributed.
