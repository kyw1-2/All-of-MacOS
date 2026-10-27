# 3.1.0 interface: Liquid Glass and one consistent structure

3.0.14 felt fragmented and heavy: each page drew its own window background,
titlebar and card style, Settings was a long scrolling list, and floating
panels used four different radii. 3.1.0 adopts the macOS 26 design system the
way Apple's own apps do: system chrome and sidebars carry the glass, content
sits on calm grouped surfaces, and Liquid Glass is reserved for controls that
float above content.

## Decisions

1. **System window chrome.** The window keeps its system background and toolbar; the probe no longer forces a transparent titlebar or a custom background (`MainWindow.swift`).
2. **Glass only for floating chrome.** HUDs, the recording bar, the clipboard shelf, the camera bubble and What's New use `glassEffect` on macOS 26 with material fallbacks (`AOMDesignKit.swift`); content uses opaque grouped cards.
3. **One sidebar, one rhythm.** The main sidebar uses the system list style; pages share `AOMSize.contentMaxWidth` (1,120 pt), one spacing scale and one radius set.
4. **Settings like System Settings.** `NavigationSplitView` with a searchable sidebar of categories, grouped rows and a unified toolbar (`SettingsHub.swift`).
5. **Library vs dashboard pages.** Lists (Automation, Clipboard) keep a plain white pane; dashboards (Workspace, Audio, Capture, System Tools) use the canvas with cards.
6. **Audio like SoundSource.** One row per app with volume, mute, Magic Boost and Overdrive in reach; routing and EQ disclose in context (`AudioWorkspaceView.swift`).
7. **Semantic color and type.** Text and fills come from semantic tokens, so the system adapts them to appearance; hard-coded colors that broke dark mode were fixed (clipboard text editor, trigger list).
8. **Own menu bar mark.** A template glyph drawn in code: a trackpad with four fingertips growing along a rising swipe, with paused and off states (`AOMMenuBarIcon.swift`).
9. **Floating chrome never steals focus.** What's New, the camera bubble and the recording bar are non-activating panels.

## References (66 rows, 72 distinct sources)

Items 1–36 are the navigation and density review in
[ux-reference-review-20261027.md](ux-reference-review-20261027.md) (SoundSource,
Audio Hijack, Paste, Maccy, Raycast ×3, Alfred ×2, CleanShot, Figma ×3, Finder
×2, Moom, Rectangle, Notion, Linear, Slack, Ableton, Things, WWDC19 809,
WWDC25 310, Fluent, Atlassian, Carbon, Material, Primer ×2, NN/g ×4, W3C APG,
Vercel). The 30 below were added for this release. Apple sources were read for
this design; the third-party entries are comparisons with each product's
public pages and shipped behaviour.

| # | Reference | Observed | Decision in AOM |
|---|---|---|---|
| 37 | [WWDC25 219 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/) | Glass is a functional layer for controls and navigation that floats above content; it adapts to what is beneath. | Glass only on floating chrome (decision 2). |
| 38 | [WWDC25 356 Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/) | Concentric shapes, fewer custom backgrounds, hierarchy from layout rather than decoration. | Unified radii and removed custom page backgrounds. |
| 39 | [WWDC25 323 Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/) | Standard NavigationSplitView, toolbars and sheets pick up the new look automatically. | Settings rebuilt on NavigationSplitView. |
| 40 | [WWDC25 256 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/) | `glassEffect`, glass button styles and toolbar spacers. | Used behind `#available(macOS 26)` with fallbacks. |
| 41 | [WWDC25 220 New look of app icons](https://developer.apple.com/videos/play/wwdc2025/220/) | Layered, simple marks that read at small sizes. | Menu bar mark reduced to trackpad + fingertips. |
| 42 | [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) | Group glass shapes in containers; avoid glass on glass. | One glass layer per floating panel. |
| 43 | [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) | Remove custom backgrounds behind bars and sidebars; let the system draw them. | Window probe returned to system chrome (decision 1). |
| 44 | [`glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) | Shape-aware glass for custom controls. | HUD and bar surfaces use the floating radius shape. |
| 45 | [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview) | AppKit counterpart for panels. | Same tokens across AppKit-hosted panels. |
| 46 | [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) | Sidebar/detail with system selection and collapse. | Settings categories as a sidebar. |
| 47 | [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | Liquid Glass for the control layer; standard materials for content. | Opaque grouped cards for content. |
| 48 | [HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Sidebar items are destinations, with system icons and short labels. | Sidebar trimmed to destinations; actions moved into pages. |
| 49 | [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Few, grouped items; titles stay readable. | Unified Settings toolbar without a redundant subtitle or toggle. |
| 50 | [HIG Windows](https://developer.apple.com/design/human-interface-guidelines/windows) | Prefer the standard window frame and background. | No forced transparent titlebar. |
| 51 | [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color) | Semantic system colors adapt to appearance and contrast. | Semantic text/fill tokens (decision 7). |
| 52 | [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography) | System text styles, consistent weights. | `AOMType` maps to system styles. |
| 53 | [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | Consistent margins, readable line lengths. | 1,120 pt content width on every page. |
| 54 | [HIG Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | Group related settings; make them searchable. | Sidebar search with keywords in Korean and English. |
| 55 | [HIG The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) | Menu bar extras use template images that adapt to the bar. | Template menu bar mark with three states. |
| 56 | [HIG SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) | Match symbol weight to adjacent text and glyphs. | Mark stroke weight matched to Wi-Fi/battery in renders. |
| 57 | [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Labels, contrast, keyboard access. | Accessibility labels on new controls; status not by color alone. |
| 58 | [HIG Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) | Test both appearances; avoid fixed colors. | Fixed hard-coded colors in the clipboard editor. |
| 59 | [HIG Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) | Search filters in place and explains empty results. | Settings and palette search filter in place. |
| 60 | [HIG Panels](https://developer.apple.com/design/human-interface-guidelines/panels) | Panels float, stay small and do not take focus unnecessarily. | Non-activating panels (decision 9). |
| 61 | [HIG Sliders](https://developer.apple.com/design/human-interface-guidelines/sliders) / [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles) | Sliders for continuous values, switches for on/off. | Volume as a slider; Magic Boost as one switch instead of three levels. |
| 62 | [System Settings](https://support.apple.com/guide/mac-help/change-system-settings-mh15217/mac) | Sidebar with search, grouped detail rows with icons. | Settings layout model. |
| 63 | [Control Center](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac) | Compact glass modules over content. | HUD and recording bar density. |
| 64 | [SoundSource manual](https://rogueamoeba.com/support/manuals/soundsource/) | Per-app rows with volume, Magic Boost, Overdrive, favourites, timed mute and a recent-apps list. | Audio page and mixer service features. |
| 65 | [iStat Menus](https://bjango.com/mac/istatmenus/) / [Ice](https://github.com/jordanbaird/Ice) | Menu bar glyphs stay monochrome, compact and state-bearing. | Paused and off states in the mark itself. |
| 66 | [Craft](https://www.craft.do/), [Bear](https://bear.app/), [Fantastical](https://flexibits.com/fantastical), [NetNewsWire](https://netnewswire.com/), [Mimestream](https://mimestream.com/) | Mac-native apps that adopted the system sidebar and toolbar rather than custom chrome. | Confirms decisions 1, 3 and 4. |

Screenshots of the isolated preview build were reviewed for every page in
light mode during the work (`work/preview.sh`, bundle `com.kyw.allofmacos.preview`).
