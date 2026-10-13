# Paste 7.0.2 clipboard preview and edit interoperability — AOM 1.0.11

Observed static REA subject: /data/academic-workspace/projects/paste-rea-20261013/extracted/Paste.app, archived locally (not committed).
Reference REA files: rea-interface-builder.json, rea-app-inventory.json and the installed app executable.
Reference Mach-O SHA-256: 9423834e88d0024df2515912428f4a3372bd4b6a553091ef65755b8f9643ab74.
REA compiled Interface Builder evidence ID: ev_75acf0691f56ff305b8ff9167e369fa4b404a49b6e8dc0faaa01a7f58d6d1fac (365 decoded graph nodes, 172 edges).
The REA Interface Builder inspector recognized four compiled IB documents, including the Paste Stack storyboard scenes; most clipboard preview components are dynamically authored, therefore UI pixel/layout parity is unverified.

The executable's own readable Swift/ObjC metadata contains ItemPreviewWindowManager, ItemPreviewWindow, ItemPreviewView, isPreviewEditing, ItemPreviewViewModelRouter, TextPreview, ImagePreview, LinkPreview, FilesPreview, ColorPreview, QLPreviewView, edit-item.toolbar.save-changes, edit-item.toolbar.discard-changes, general.action.preview, general.action.edit, and search.filters.section.app. These are static capability hints and not recovered implementation source or evidence of exact gesture/shortcut dispatch.

## AOM changes

- Selection-driven Space -> Preview and Command-E -> Edit Content; Command-R -> Rename.
- Key dispatch is protected from a still-focused SwiftUI search field, without intercepting ordinary typing when no clip is selected.
- Physical Command-E / Command-R work across IME layouts, including Korean.
- Preview sheet renders images, text, and native QuickLookUI file previews, with editing/saving existing text/link/color items.
- App source filter chips and compact menu show the real installed application icon, with an SF Symbol fallback if the source app cannot be resolved.
- New deterministic shortcut/selection tests and native icon fallback tests.

## Limits

Single-file previews use the public macOS QLPreviewView renderer; multi-file clips still use an explicit file list and Reveal in Finder controls rather than the vendor's full multi-item preview workflow. Image markup/rotate/erase and rich-text formatting are not yet feature-complete; proprietary Paste implementation not included in AOM. No claim of identical pixels, animation, focus precedence, or completeness follows from these observations.
