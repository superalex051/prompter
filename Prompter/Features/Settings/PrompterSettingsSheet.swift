import SwiftUI

/// The settings form in a sheet, for use over the prompter: medium and large detents, a "Done" button, edits applied live
/// through the binding. The caller owns the presentation (`.sheet`) and what happens when it closes.
struct PrompterSettingsSheet: View {
    @Binding var settings: PrompterSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PrompterSettingsForm(settings: $settings)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview("Sheet") {
    @Previewable @State var settings = PrompterSettings()
    PrompterSettingsSheet(settings: $settings)
        .preferredColorScheme(.dark)
}
