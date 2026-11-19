import SwiftUI

/// Sets `isFoldable` once the device reports a hinge (iPhone Duo, iOS 27.1 and later). It stays set for as long as the
/// view lives: the prompter never lays out from the hinge (Apple: don't), it only needs to know that folds can happen,
/// and, for the orientation lock, whether the hinge is closed (`isHingeClosed`: the cover is the screen in use). Below
/// iOS 27.1, and on devices without a hinge, neither ever changes, so nothing differs there.
struct FoldableDeviceReader: ViewModifier {
    @Binding var isFoldable: Bool
    /// nil until the first hinge report; then whether the hinge is closed, kept through a report without a hinge.
    @Binding var isHingeClosed: Bool?

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                guard let hinge = new.hinge else { return }
                if !isFoldable { isFoldable = true }
                let isClosed = hinge.status == .closed
                if isHingeClosed != isClosed { isHingeClosed = isClosed }
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
