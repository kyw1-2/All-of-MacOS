import Foundation

@MainActor
final class AOMOverlayCoordinator {
    static let shared = AOMOverlayCoordinator()

    enum Surface: Hashable {
        case launcher, clipboardShelf, menuBarPanel, windowSwitcher, dropShelf
    }

    struct Presentation: Equatable {
        let surface: Surface
        fileprivate let id = UUID()
    }

    private var active: (presentation: Presentation, dismiss: () -> Void)?
    private var latestRequest: UUID?
    var activeSurface: Surface? { active?.presentation.surface }

    /// Call before showing a panel. The dismiss closure must hide it synchronously.
    /// Capture the presentation in that showing's close callback.
    func present(_ surface: Surface, dismiss: @escaping () -> Void,
                 show: (Presentation) -> Void) {
        if let current = active, current.presentation.surface == surface {
            show(current.presentation)
            return
        }
        let next = Presentation(surface: surface)
        latestRequest = next.id
        let previous = active
        active = nil
        previous?.dismiss()
        guard latestRequest == next.id else { return }
        active = (next, dismiss)
        show(next)
    }

    func didDismiss(_ presentation: Presentation) {
        if active?.presentation == presentation { active = nil }
    }

    func dismissAll() {
        latestRequest = nil
        let previous = active
        active = nil
        previous?.dismiss()
    }
}
