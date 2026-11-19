#if DEBUG
import SwiftUI
import UIKit

/// Debug builds: "-duoProbe" logs the window's shape to `Documents/duo-probe.log` (and the console) every time it changes:
/// size, safe area, size classes, the window scene's orientation, the fold (`reservedRegions(kind: .division)`), anything
/// covering the screen (`.occlusion`), the hinge and the scene phase. It is how the foldable QA learns what the app is given
/// in each posture: `xcrun simctl get_app_container <udid> <bundle id> data` holds the log.
struct DuoProbeModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .background {
                // The outer reader keeps the safe area, so its insets are the real ones; the inner one ignores it and
                // measures the whole window (a reader that ignores the safe area reports zero insets).
                GeometryReader { safe in
                    let insets = safe.safeAreaInsets
                    GeometryReader { proxy in
                        let line = DuoProbe.describe(
                            proxy, safeInsets: insets, horizontal: horizontalSizeClass, vertical: verticalSizeClass
                        )
                        Color.clear
                            .onChange(of: line, initial: true) { _, line in DuoProbe.log(line) }
                    }
                    .ignoresSafeArea()
                }
            }
            .modifier(DuoProbeHingeModifier())
            .onChange(of: scenePhase, initial: true) { _, phase in DuoProbe.log("phase \(phase)") }
    }
}

private struct DuoProbeHingeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                if let hinge = new.hinge {
                    DuoProbe.log("hinge \(hinge.status) angle \(Int(hinge.angle.degrees.rounded()))°")
                } else {
                    DuoProbe.log("hinge none")
                }
            }
        } else {
            content
        }
    }
}

@MainActor
enum DuoProbe {
    static func describe(
        _ proxy: GeometryProxy, safeInsets i: EdgeInsets, horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?
    ) -> String {
        let s = proxy.size
        var parts = [
            "size \(Int(s.width))x\(Int(s.height))",
            "safe t\(Int(i.top)) l\(Int(i.leading)) b\(Int(i.bottom)) r\(Int(i.trailing))",
            "classes h:\(name(horizontal)) v:\(name(vertical))",
        ]
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let b = scene.effectiveGeometry.coordinateSpace.bounds
            parts.append("scene \(Int(b.width))x\(Int(b.height)) \(orientation(scene.effectiveGeometry.interfaceOrientation))")
            parts.append("idiom \(scene.traitCollection.userInterfaceIdiom == .pad ? "pad" : "phone")")
        }
        if #available(iOS 27.1, *) {
            for kind in [ReservedRegion.Kind.division, .occlusion] {
                let regions = proxy.reservedRegions(kind: kind, options: .includeInactive)
                let text = regions.map { r in
                    let f = r.frame
                    return "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(r.isActive ? "" : " inactive")"
                }
                parts.append("\(kind): " + (text.isEmpty ? "none" : text.joined(separator: " | ")))
            }
        }
        return parts.joined(separator: " · ")
    }

    static func log(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)"
        print("[DuoProbe] \(stamped)")
        let url = URL.documentsDirectory.appending(path: "duo-probe.log")
        let data = Data((stamped + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func name(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        default: "unknown"
        }
    }

    private static func orientation(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: "unknown"
        }
    }
}

extension View {
    /// `-duoProbe` (debug builds): log the window's shape on every change. See `DuoProbeModifier`.
    @ViewBuilder func duoProbe(_ isOn: Bool) -> some View {
        if isOn { modifier(DuoProbeModifier()) } else { self }
    }
}
#else
import SwiftUI

extension View {
    func duoProbe(_ isOn: Bool) -> some View { self }
}
#endif
