import SwiftUI

// ui.md's dependent-options rule in one place (3.3.3 integration): a row that
// only matters while its parent switch is on stays visible, is disabled and
// dims, so the section title stays readable and the footer can say why.
//
//     Group { rows }.dependentSetting(on: snapOn)
//
// is `.disabled(!snapOn).opacity(snapOn ? 1 : 0.55)`. A row inside a group
// that already dims passes `within:`, so a row whose two parents are both off
// dims once instead of fading further.

enum DependentSetting {
    /// The opacity of a dependent row while its parent is off (ui.md, e.3).
    static let dimmedOpacity: Double = 0.55
}

extension View {
    func dependentSetting(on parentOn: Bool, within outerOn: Bool = true) -> some View {
        disabled(!parentOn)
            .opacity(parentOn || !outerOn ? 1 : DependentSetting.dimmedOpacity)
    }
}
