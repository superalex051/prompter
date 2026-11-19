import SwiftUI

/// Sets `isFoldable` once the device reports a hinge (iPhone Duo, iOS 27.1 and later). It stays set for as long as the
/// view lives: the prompter only needs to know that folds can happen, never the hinge's angle (Apple: don't lay out from
/// the hinge). Below iOS 27.1, and on devices without a hinge, it never changes, so nothing differs there.
struct FoldableDeviceReader: ViewModifier {
    @Binding var isFoldable: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                if new.hinge != nil, !isFoldable { isFoldable = true }
            }
        } else {
            content
        }
    }
}
