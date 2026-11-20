import AppKit
import SwiftUI

// MARK: - 1. Pixelmator Pro식 Annotation Workbench Shell

struct AOMAnnotateWorkbenchShell<CanvasContent: View, SubBar: View, InspectorContent: View>: View {
    struct ToolItem: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let shortcut: String
    }

    let tools: [ToolItem]
    @Binding var selectedToolID: String
    @Binding var showsInspector: Bool
    let canvas: () -> CanvasContent
    let subBar: () -> SubBar
    let inspector: () -> InspectorContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                // 72% 다크 도트 그리드 워크벤치 캔버스
                AOMCraftColor.workbenchCanvas
                    .overlay(dotGridPattern)
                    .overlay(canvas())

                // 상단 중앙 플로팅 Liquid Glass 도구 필 + 동적 서브 속성 바
                VStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(tools) { tool in
                            let active = tool.id == selectedToolID
                            Button {
                                selectedToolID = tool.id
                            } label: {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                                    .foregroundStyle(active ? .white : .primary)
                                    .frame(width: 32, height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(active ? Color.accentColor : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(tool.label))
                            .accessibilityAddTraits(active ? .isSelected : [])
                            .help("\(tool.label) (\(tool.shortcut))")
                        }

                        Rectangle()
                            .fill(AOMCraftColor.hairline)
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 4)

                        Button {
                            withAnimation(AOMCraftMotion.resolve(AOMCraftMotion.inlineFold, reduceMotion: reduceMotion)) {
                                showsInspector.toggle()
                            }
                        } label: {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 14))
                                .foregroundStyle(showsInspector ? Color.accentColor : .primary)
                                .frame(width: 32, height: 30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Background and export inspector")
                        .keyboardShortcut("i", modifiers: [.option, .command])
                        .help("Background & Export Inspector (⌥⌘I)")
                    }
                    .padding(5)
                    .aomFloatingGlass(radius: 14)

                    subBar()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .aomFloatingGlass(radius: 10)
                }
                .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsInspector {
                Rectangle()
                    .fill(AOMCraftColor.hairline)
                    .frame(width: 1)
                inspector()
                    .frame(width: 280)
                    .background(AOMCraftColor.surface)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var dotGridPattern: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            for x in stride(from: step, to: size.width, by: step) {
                for y in stride(from: step, to: size.height, by: step) {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                        with: .color(.white.opacity(0.08))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 2. CleanShot X 3단계 호버 Quick Access 오버레이 카드

struct AOMQuickAccessCraftCard: View {
    let thumbnail: NSImage
    let onCopy: () -> Void
    let onSave: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        ZStack {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 240, height: 152)
                .clipped()

            if isHovered {
                Color.black.opacity(0.32)

                // 중앙 Copy / Save 듀얼 글래스 캡슐
                HStack(spacing: 8) {
                    glassCapsuleButton("Copy", symbol: "doc.on.doc", action: onCopy)
                    glassCapsuleButton("Save", symbol: "square.and.arrow.down", action: onSave)
                }

                // 네 모서리 보조 액션
                VStack {
                    HStack {
                        cornerCircleButton("xmark", help: "Close", action: onClose)
                        Spacer()
                        cornerCircleButton("pin", help: "Pin to Screen", action: onPin)
                    }
                    Spacer()
                    HStack {
                        cornerCircleButton("pencil.tip.crop.circle", help: "Annotate", action: onAnnotate)
                        Spacer()
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 240, height: 152)
        .clipShape(shape)
        .overlay(shape.strokeBorder(AOMCraftColor.specularEdge, lineWidth: 1))
        .shadow(color: .black.opacity(0.26), radius: 14, y: 6)
        .animation(AOMCraftMotion.resolve(AOMCraftMotion.crossfade, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                Button("Copy", action: onCopy)
                Button("Save", action: onSave)
                Button("Annotate", action: onAnnotate)
                Button("Pin to Screen", action: onPin)
                Button("Close", action: onClose)
            } label: {
                Label("Capture actions", systemImage: "ellipsis.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Capture actions")
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(5)
            .background(AOMCraftColor.surface, in: Capsule())
            .padding(8)
        }
    }

    private func glassCapsuleButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func cornerCircleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
