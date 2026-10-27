# AOM navigation and density: reference review

Reviewed 2026-10-27. These are 36 separate reference documents, not 34 products or 34 wholesale UI copies. Vendor manuals and product pages were read for specific interaction patterns; broader design guidelines inform the design constraints. An item can corroborate a decision without causing a unique code change. Web-specific guidance is adapted to native macOS rather than copied literally.

| # | Reference | Observation / relevance |
|---|---|---|
| 1 | [SoundSource: Applications](https://www.rogueamoeba.com/support/manuals/soundsource/?page=application-adjustments) | Keep app volume, mute and boost close; reveal advanced effects per app. |
| 2 | [Audio Hijack](https://rogueamoeba.com/audiohijack/) | Separate source, device and effects concepts; avoid treating them as one undifferentiated stream of settings. |
| 3 | [Paste for Mac](https://pasteapp.io/help/paste-on-mac) | Show recent content and context, with direct access to the full history. |
| 4 | [Maccy documentation](https://maccyapp.com/documentation) | Search and direct keyboard actions are central to a compact utility. |
| 5 | [Raycast clipboard history](https://manual.raycast.com/clipboard-history) | Search and filter in place; keep secondary item actions contextual. |
| 6 | [Raycast keyboard shortcuts](https://manual.raycast.com/keyboard-shortcuts) | Keep shortcuts discoverable and keyboard navigation predictable. |
| 7 | [Raycast navigation](https://manual.raycast.com/navigation) | Direct destinations reduce trips through nested menus. |
| 8 | [Alfred cheatsheet](https://www.alfredapp.com/help/getting-started/cheatsheet/) | Shortcuts should be discoverable rather than encoded only in icons. |
| 9 | [Alfred snippets](https://www.alfredapp.com/help/features/snippets/) | Common actions and deeper configuration should coexist. |
| 10 | [CleanShot X features](https://cleanshot.com/features) | Native capture and annotation tools should stay directly accessible. |
| 11 | [Figma navigation and sidebar](https://help.figma.com/hc/en-us/articles/360039831974-Explore-the-navigation-bar-and-left-sidebar) | Distinguish persistent navigation, content, and contextual panels. |
| 12 | [Figma keyboard use](https://help.figma.com/hc/en-us/articles/360040328653-Use-Figma-products-with-a-keyboard) | Keep keyboard alternatives and focus behavior in view. |
| 13 | [Figma actions menu](https://help.figma.com/hc/en-us/articles/23570416033943-Use-the-actions-menu-in-Figma-Design) | Group occasional commands while preserving a fast route to them. |
| 14 | [Finder folder views](https://support.apple.com/guide/mac-help/mchldaafb302/mac) | Different views for different tasks and available space. |
| 15 | [Finder Quick Actions](https://support.apple.com/guide/mac-help/perform-quick-actions-in-the-finder-on-mac-mchl97ff9142/mac) | Put relevant actions close to the selected item. |
| 16 | [Moom palette](https://manytricks.com/moom/help/palette.html) | Compact, familiar actions can be offered close to the task. |
| 17 | [Rectangle](https://rectangleapp.com/) | Clear actions and shortcuts make window management quick. |
| 18 | [Notion sidebar](https://www.notion.com/help/navigate-with-the-sidebar) | Provide persistent, labeled places for navigation. |
| 19 | [Linear start guide](https://linear.app/docs/start-guide) | Give people a clear orientation to the workspace and its areas. |
| 20 | [Slack quick start](https://slack.com/help/articles/360059928654-How-to-use-Slack--your-quick-start-guide) | Consistent places and search support movement between tasks. |
| 21 | [Ableton Live browser](https://help.ableton.com/hc/en-us/articles/12927340213660-The-Live-12-Browser) | Organize tools, effects and content by purpose. |
| 22 | [Things features](https://culturedcode.com/things/features/) | Calm visual hierarchy and clear overview of what matters. |
| 23 | [Apple: Designing iPad Apps for Mac](https://developer.apple.com/videos/play/wwdc2019/809/) | Native Mac structure, grouped sidebar and efficient navigation. |
| 24 | [Apple: Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/) | Use system window structure and controls for macOS appearance. |
| 25 | [Microsoft Fluent tablist](https://fluent2.microsoft.design/components/web/react/core/tablist/usage/) | Split related content into small peer sections to reduce scrolling. |
| 26 | [Atlassian tabs](https://atlassian.design/components/tabs/usage) | Group related information with short, descriptive labels. |
| 27 | [IBM Carbon tabs](https://www.carbondesignsystem.com/building-blocks/core/components/tabs/guidelines) | Maintain a shared context across related sections. |
| 28 | [Material tabs](https://m3.material.io/components/tabs/guidelines) | Make peer destinations explicit and succinct. |
| 29 | [GitHub Primer progressive disclosure](https://primer.github.io/design/ui-patterns/progressive-disclosure/) | Reveal details in context and pair disclosure with understandable labels. |
| 30 | [GitHub Primer navigation](https://www.primer.style/product/ui-patterns/navigation/) | Keep the current location clear and choices limited. |
| 31 | [Nielsen Norman Group: progressive disclosure](https://www.nngroup.com/articles/progressive-disclosure/) | Keep frequent controls visible and put advanced settings behind a clear disclosure. |
| 32 | [Nielsen Norman Group: scrolling](https://www.nngroup.com/articles/scrolling-and-scrollbars/) | Use visible, standard scrolling and avoid unnecessary two-axis exploration. |
| 33 | [Nielsen Norman Group: complex applications](https://www.nngroup.com/articles/usability-heuristics-complex-applications/) | System status, clear recovery and consistency are essential in complex tools. |
| 34 | [Nielsen Norman Group: empty states](https://www.nngroup.com/articles/empty-state-interface-design/) | Empty searches need an explanation and a recovery action. |
| 35 | [W3C interaction patterns](https://www.w3.org/WAI/ARIA/apg/patterns/) | Explicit labels, state, and keyboard operation for controls. |
| 36 | [Vercel interface guidelines](https://vercel.com/design/guidelines) | Accessible control names, focus and legible status beyond color. |

## Applied to this iteration

- Audio uses three labeled peer sections: Mixer, Devices and Effects. The mixer keeps output volume, output boost, app volume and mute within reach. Routing, app EQ, boost strength and recovery remain in each app's explicit Details; the EQ opens in a focused sheet without shifting the app list. Devices holds input, output, alert sounds and AirPlay; Effects holds the output boost and master EQ.
- The Workspace moves audio status and a direct mixer entry above the larger cards. Capture and Workspace mode launchers use a shorter labeled row, preserving shortcut hints.
- Existing macOS sidebar, automation list/detail structure, clipboard filtering and capture gallery are retained. This is not a whole-app redesign, a claim of user-testing with others, or pixel parity with any reference.
