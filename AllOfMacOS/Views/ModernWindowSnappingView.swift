import AppKit
import SwiftUI

/// Modern Apple-Native Window Snapping & Tiling Hub.
/// Provides an interactive visual desktop preview, drag-to-snap zones,
/// layout preset collections, and edge margin controls.
struct ModernWindowSnappingView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredLayout: CustomSnapZone.Layout?
    @State private var selectedCollection: CustomSnapZone.Collection = .essentials
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    private let primaryLayouts: [CustomSnapZone.Layout] = [
        .leftHalf, .rightHalf, .maximize,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftThird, .centerThird, .rightThird, .center
    ]

    var body: some View {
        VStack(spacing: 0) {

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Master Status Card
                    statusCard

                    // Interactive Visual Desktop Stage
                    stageSection

                    // Quick Collections Bar
                    collectionsSection

                    // Grid of Available Snap Zones
                    zonesGridSection
                }
                .padding(24)
            }
            .suppressScrollerReservation()
        }
        .toolbar { ToolbarItemGroup(placement: .automatic) { headerBar } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.16))
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .shadow(radius: 6)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {


            Toggle("Window Snapping", isOn: Binding(
                get: { appState.currentPreset.snappingEnabled },
                set: { appState.setSnappingEnabled($0) }
            ))
            .toggleStyle(.switch)
        }
        .labelStyle(.iconOnly)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(appState.currentPreset.snappingEnabled ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: appState.currentPreset.snappingEnabled ? "rectangle.split.2x2" : "rectangle.dashed")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(appState.currentPreset.snappingEnabled ? Color.blue : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.currentPreset.snappingEnabled ? "Drag-to-Snap Active" : "Window Snapping Disabled")
                    .font(.system(size: 14, weight: .bold))

                Text(appState.snapStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.currentPreset.snappingEnabled {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("\(appState.effectiveSnapZones.filter(\.isEnabled).count) Zones Listening")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Interactive Desktop Stage

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Layout Preview", systemImage: "display")
                .font(.headline)
                .foregroundStyle(.secondary)

            ZStack {
                // Simulated macOS Display
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(height: 220)
                    .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)

                // Wallpaper gradient simulation
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.35), Color.indigo.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(8)

                // Menu Bar Simulation
                VStack {
                    HStack {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 10))
                        Text("All of MacOS")
                            .font(.system(size: 9, weight: .bold))
                        Spacer()
                        Text("Mon 9:41 AM")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.2))

                    Spacer()
                }
                .padding(8)

                // Active Layout Preview Overlay
                if let layout = hoveredLayout {
                    GeometryReader { geo in
                        let rect = snapRect(for: layout, in: geo.size)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.8), lineWidth: 2)
                            )
                            .overlay(
                                Text(layout.rawValue)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hoveredLayout)
                    }
                    .padding(8)
                    .padding(.top, 24)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "cursorarrow.and.square.on.square.dashed")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Hover over any snap zone below to preview on screen")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Collections Section

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Collections", systemImage: "square.grid.2x2")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(CustomSnapZone.Collection.allCases) { collection in
                    let isSelected = selectedCollection == collection
                    Button {
                        selectedCollection = collection
                        applyCollection(collection)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(collection.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.blue)
                                }
                            }

                            Text("\(collection.layouts.count) preset snap zones")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? Color.blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(isSelected ? Color.blue.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Zones Grid Section

    private var zonesGridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AVAILABLE SNAP ZONES", systemImage: "rectangle.split.3x3")
                .font(.headline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)], spacing: 12) {
                ForEach(primaryLayouts) { layout in
                    SnapLayoutTile(
                        layout: layout,
                        isHovered: hoveredLayout == layout,
                        onHover: { hovering in
                            hoveredLayout = hovering ? layout : nil
                        },
                        onExecute: {
                            executeSnap(layout)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func applyCollection(_ collection: CustomSnapZone.Collection) {
        let newZones = collection.replacing(appState.effectiveSnapZones)
        appState.updateSnapSettings(
            zones: newZones,
            enabled: appState.currentPreset.snappingEnabled,
            requiresOption: appState.activeSnapProfile?.requiresOption ?? appState.currentPreset.snappingRequiresOption,
            showsPreview: appState.activeSnapProfile?.showsPreview ?? appState.currentPreset.snappingShowsPreview,
            profileID: appState.activeSnapProfile?.id
        )
        showToast("Applied “\(collection.rawValue)” snap layout set")
    }

    private func executeSnap(_ layout: CustomSnapZone.Layout) {
        let actionType: ActionType
        switch layout {
        case .leftHalf: actionType = .snapWindowLeft
        case .rightHalf: actionType = .snapWindowRight
        case .maximize: actionType = .maximizeWindow
        case .topHalf: actionType = .snapWindowTopHalf
        case .bottomHalf: actionType = .snapWindowBottomHalf
        case .topLeft: actionType = .snapWindowTopLeft
        case .topRight: actionType = .snapWindowTopRight
        case .bottomLeft: actionType = .snapWindowBottomLeft
        case .bottomRight: actionType = .snapWindowBottomRight
        case .center:
            var params = ActionParameters()
            params.snapX = 0.15
            params.snapY = 0.15
            params.snapWidth = 0.70
            params.snapHeight = 0.70
            WindowManager.shared.execute(.customSnapWindow, target: nil, parameters: params) { success in
                if success { showToast("Centered window") }
                else { showToast("Could not center window") }
            }
            return
        case .leftThird: actionType = .snapWindowLeftThird
        case .centerThird: actionType = .snapWindowCenterThird
        case .rightThird: actionType = .snapWindowRightThird
        case .leftTwoThirds: actionType = .snapWindowLeftTwoThirds
        case .rightTwoThirds: actionType = .snapWindowRightTwoThirds
        case .nextDisplay: actionType = .moveWindowNextMonitorAndMaximize
        }
        ActionExecutor.executeAction(TriggerAction(actionType: actionType))
        showToast("Tiled window to “\(layout.rawValue)”")
    }

    private func snapRect(for layout: CustomSnapZone.Layout, in size: CGSize) -> CGRect {
        let w = size.width
        let h = size.height
        let y0: CGFloat = 0

        switch layout {
        case .leftHalf:
            return CGRect(x: 0, y: y0, width: w * 0.5, height: h)
        case .rightHalf:
            return CGRect(x: w * 0.5, y: y0, width: w * 0.5, height: h)
        case .topHalf:
            return CGRect(x: 0, y: y0, width: w, height: h * 0.5)
        case .bottomHalf:
            return CGRect(x: 0, y: y0 + h * 0.5, width: w, height: h * 0.5)
        case .maximize:
            return CGRect(x: 0, y: y0, width: w, height: h)
        case .center:
            let cw = w * 0.70
            let ch = h * 0.70
            return CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        case .topLeft:
            return CGRect(x: 0, y: y0, width: w * 0.5, height: h * 0.5)
        case .topRight:
            return CGRect(x: w * 0.5, y: y0, width: w * 0.5, height: h * 0.5)
        case .bottomLeft:
            return CGRect(x: 0, y: y0 + h * 0.5, width: w * 0.5, height: h * 0.5)
        case .bottomRight:
            return CGRect(x: w * 0.5, y: y0 + h * 0.5, width: w * 0.5, height: h * 0.5)
        case .leftThird:
            return CGRect(x: 0, y: y0, width: w / 3, height: h)
        case .centerThird:
            return CGRect(x: w / 3, y: y0, width: w / 3, height: h)
        case .rightThird:
            return CGRect(x: (w / 3) * 2, y: y0, width: w / 3, height: h)
        case .leftTwoThirds:
            return CGRect(x: 0, y: y0, width: (w / 3) * 2, height: h)
        case .rightTwoThirds:
            return CGRect(x: w / 3, y: y0, width: (w / 3) * 2, height: h)
        case .nextDisplay:
            return CGRect(x: 0, y: y0, width: w, height: h)
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                toastMessage = nil
            }
        }
    }
}

private struct SnapLayoutTile: View {
    let layout: CustomSnapZone.Layout
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onExecute: () -> Void

    var body: some View {
        Button(action: onExecute) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.blue.opacity(0.18) : Color.primary.opacity(0.05))
                        .frame(width: 36, height: 36)

                    Image(systemName: layout.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.blue : Color.primary)
                }

                Text(layout.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: Color.black.opacity(isHovered ? 0.10 : 0.03), radius: isHovered ? 4 : 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isHovered ? Color.blue.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { onHover($0) }
    }
}
