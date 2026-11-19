import SwiftUI

/// SwiftUI wrapper for `PrompterTextView`. It hands over the text and settings, and wakes the display link whenever the
/// engine's state changes (so commands that reach the engine without touching the view, like the watch's, still move it).
struct PrompterCanvas: UIViewRepresentable {
    let controller: PrompterController
    let settings: PrompterSettings
    let callbacks: PrompterTextView.Callbacks
    /// The device folds (iPhone Duo): relayouts keep the exact reading point (see `PrompterTextView.anchorsReadingPoint`).
    var isFoldable = false

    func makeUIView(context: Context) -> PrompterTextView {
        let view = PrompterTextView(engine: controller.engine)
        controller.textView = view
        view.callbacks = callbacks
        view.anchorsReadingPoint = isFoldable
        view.update(document: controller.document, settings: settings)
        return view
    }

    func updateUIView(_ view: PrompterTextView, context: Context) {
        view.callbacks = callbacks
        view.anchorsReadingPoint = isFoldable
        controller.showMarkdown(settings.markdown)
        view.update(document: controller.document, settings: settings)
        // Reading the state subscribes this update to state changes; the link pauses itself again if nothing moves.
        _ = controller.engine.state
        view.wakeDisplayLink()
    }

    static func dismantleUIView(_ view: PrompterTextView, coordinator: ()) {
        view.stopDisplayLink()
    }
}
