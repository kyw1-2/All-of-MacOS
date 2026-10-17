import SwiftUI

/// Top-level navigation hubs for All of MacOS.
enum AOMMainTab: String, CaseIterable, Identifiable {
    case gestures = "Gestures & Automation"
    case snapping = "Window Snapping"
    case capture = "Capture & Studio"
    case clipboard = "Clipboard Memory"
    case insights = "Statistics"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gestures: return "Gestures"
        case .snapping: return "Window Tiling"
        case .capture: return "Capture Studio"
        case .clipboard: return "Clipboard"
        case .insights: return "Insights"
        }
    }

    var subtitle: String {
        switch self {
        case .gestures: return "Trackpad, keyboard, mouse & workflow automation"
        case .snapping: return "Screen split, tile zones & display layouts"
        case .capture: return "Screenshots, recording, annotation & OCR"
        case .clipboard: return "Encrypted pasteboard history, pinboards & search"
        case .insights: return "Gesture frequency and automation analytics"
        }
    }

    var iconName: String {
        switch self {
        case .gestures: return "hand.tap.fill"
        case .snapping: return "macwindow.on.rectangle"
        case .capture: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard.fill"
        case .insights: return "chart.xyaxis.line"
        }
    }

    var accentColor: Color {
        switch self {
        case .gestures: return .cyan
        case .snapping: return .blue
        case .capture: return .orange
        case .clipboard: return .indigo
        case .insights: return .green
        }
    }
}

/// A sleek Apple-style segmented navigation bar for the top tabs.
struct ModernMainTabBar: View {
    @Binding var selectedTab: AOMMainTab
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AOMMainTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? tab.accentColor : .secondary)

                        Text(tab.title)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected
                                  ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                                  : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? tab.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Scroller Reservation Suppression

/// Completely eliminates legacy scrollbar tracks from reserving layout width or flashing,
/// while preserving smooth wheel and trackpad scrolling across all macOS versions.
struct HideScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.verticalScroller?.alphaValue = 0
                scrollView.horizontalScroller?.alphaValue = 0
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = nsView.enclosingScrollView {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.verticalScroller?.alphaValue = 0
                scrollView.horizontalScroller?.alphaValue = 0
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
        }
    }
}

extension View {
    func suppressScrollerReservation() -> some View {
        self
            .scrollIndicators(.hidden)
            .background(HideScroller())
    }
}

