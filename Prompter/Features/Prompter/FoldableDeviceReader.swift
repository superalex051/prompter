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

extension GeometryProxy {
    /// The reserved regions over this view that are ACTIVE right now, in its coordinates, margins included: the fold while
    /// the device is partly folded (Book), the cover's camera. The fold of a device lying flat is inactive, so it isn't
    /// here. None before iOS 27.1, and none on a device without a fold or a camera in the screen.
    @MainActor var activeReservedRects: [CGRect] {
        if #available(iOS 27.1, *) {
            // Asked for inactive ones too (the call DuoProbe makes), then only the active ones are kept.
            let regions = Array(reservedRegions(kind: .division, options: .includeInactive))
                + Array(reservedRegions(kind: .occlusion, options: .includeInactive))
            return regions.filter(\.isActive).map(\.frame)
        }
        return []
    }
}
