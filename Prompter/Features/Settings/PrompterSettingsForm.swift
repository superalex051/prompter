import SwiftUI

/// All the prompter settings as a native grouped `Form`. It has no navigation of its own: the caller supplies the
/// `NavigationStack` and any buttons (see `PrompterSettingsSheet` over the prompter and `AppSettingsView` in the library).
/// Edits go straight to the binding, so the prompter behind the sheet updates live.
struct PrompterSettingsForm: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Form {
            PrompterSettingsSections(settings: $settings)
        }
    }
}

/// The settings sections without the surrounding `Form`, so `AppSettingsView` can add its own sections to the same list.
struct PrompterSettingsSections: View {
    @Binding var settings: PrompterSettings

    /// Voice mode only: why it can't listen (from the permission check that runs when Voice is picked).
    @State private var voiceProblem: VoiceProblem?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        scrollingSection
        countdownSection
        textSection
        mirrorSection
        readingLineSection
    }

    // MARK: Scrolling

    private var scrollingSection: some View {
        Section {
            Picker("Mode", selection: $settings.scrollMode) {
                ForEach(PrompterSettings.ScrollMode.allCases, id: \.self) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            }
            .segmentedUnlessLargeText()

            switch settings.scrollMode {
            case .speed:
                SettingsSliderRow(
                    title: "Speed",
                    value: $settings.speedLevel,
                    range: PrompterSettings.speedLevelRange,
                    step: 0.1,
                    valueText: Self.tenths(settings.speedLevel)
                )
            case .finishIn:
                FinishInRow(seconds: $settings.finishInSeconds)
            case .wpm, .voice:
                SettingsSliderRow(
                    title: "Words per minute",
                    value: $settings.wordsPerMinute,
                    range: PrompterSettings.wpmRange,
                    step: 1,
                    valueText: "\(Int(settings.wordsPerMinute.rounded())) wpm"
                )
                if settings.scrollMode == .voice, let voiceProblem, voiceProblem.opensSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .accessibilityHint("Opens Prompter in the Settings app, to turn the permission on.")
                }
            }
        } header: {
            Text("Scrolling")
        } footer: {
            Text(Self.footer(for: settings.scrollMode, voiceProblem: voiceProblem))
        }
        // Picking Voice asks for the microphone (and, where needed, speech recognition) right away, while the presenter
        // is at the phone; coming back from the Settings app checks again.
        .task(id: settings.scrollMode) {
            guard settings.scrollMode == .voice else {
                voiceProblem = nil
                return
            }
            voiceProblem = await VoicePermissions.problem(requesting: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, settings.scrollMode == .voice else { return }
            Task { voiceProblem = await VoicePermissions.problem(requesting: false) }
        }
    }

    // MARK: Countdown

    private var countdownSection: some View {
        Section {
            Picker("Countdown", selection: $settings.countdownSeconds) {
                ForEach(PrompterSettings.countdownOptions, id: \.self) { seconds in
                    Text(seconds == 0 ? "Off" : "\(seconds) s").tag(seconds)
                }
            }
            .segmentedUnlessLargeText()

            Toggle("Beep each second", isOn: $settings.countdownBeep)
                .disabled(settings.countdownSeconds == 0)
        } header: {
            Text("Countdown")
        } footer: {
            Text("Gives you time to get into position before the text starts. Silent mode mutes the beeps.")
        }
    }

    // MARK: Text

    private var textSection: some View {
        Section {
            SettingsSliderRow(
                title: "Size",
                value: $settings.fontSize,
                range: PrompterSettings.fontSizeRange,
                step: 1,
                valueText: "\(Int(settings.fontSize.rounded())) pt"
            )

            Picker("Weight", selection: $settings.fontWeight) {
                ForEach(PrompterSettings.Weight.allCases, id: \.self) { weight in
                    Text(Self.title(for: weight)).tag(weight)
                }
            }

            SettingsSliderRow(
                title: "Line spacing",
                value: $settings.lineSpacing,
                range: PrompterSettings.lineSpacingRange,
                step: 0.1,
                valueText: "\(Self.tenths(settings.lineSpacing))×"
            )

            SettingsSliderRow(
                title: "Side margins",
                value: $settings.sideMargin,
                range: PrompterSettings.sideMarginRange,
                step: 0.01,
                valueText: Self.percent(settings.sideMargin)
            )

            SchemePicker(selection: $settings.scheme)

            Toggle("Markdown formatting", isOn: $settings.markdown)
                .accessibilityHint("Shows bold text in amber, italics, headings and lists, and hides the symbols.")
        } header: {
            Text("Text")
        } footer: {
            Text(verbatim: Self.textFooter(markdown: settings.markdown))
        }
    }

    // MARK: Mirror

    private var mirrorSection: some View {
        Section {
            Toggle("Mirror (for the glass)", isOn: $settings.mirrorHorizontal)
            Toggle("Flip upside down", isOn: $settings.flipVertical)

            RotationPicker(selection: $settings.rotation)

            Toggle("Landscape only", isOn: $settings.lockLandscape)
        } header: {
            Text("Mirror and rotation")
        } footer: {
            Text("Mirror flips the text left to right so it reads correctly in the glass. Landscape only stops the text turning when you pick the phone up or put it down. If the text is upside down in the glass, set Rotation to 180°.")
        }
    }

    // MARK: Reading line

    private var readingLineSection: some View {
        Section {
            SettingsSliderRow(
                title: "Position from top",
                value: $settings.readingLinePosition,
                range: PrompterSettings.readingLineRange,
                step: 0.01,
                valueText: Self.percent(settings.readingLinePosition)
            )
            SettingsSliderRow(
                title: "Dim text above",
                value: $settings.dimmedOpacity,
                range: PrompterSettings.dimmedOpacityRange,
                step: 0.01,
                valueText: Self.percent(settings.dimmedOpacity)
            )
        } header: {
            Text("Reading line")
        } footer: {
            Text("Text above the line is dimmed, so your eye lands on the next line.")
        }
    }

    // MARK: Text helpers

    private static func title(for mode: PrompterSettings.ScrollMode) -> String {
        switch mode {
        case .speed: "Speed"
        case .finishIn: "Finish in"
        case .wpm: "WPM"
        case .voice: "Voice"
        }
    }

    private static func title(for weight: PrompterSettings.Weight) -> String {
        switch weight {
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        case .heavy: "Heavy"
        case .black: "Black"
        }
    }

    /// The Text section's footer: legibility, then what Markdown formatting does (or that it's off).
    static func textFooter(markdown: Bool) -> String {
        let legibility = "Big, heavy, widely spaced text is easiest to read through the glass."
        return legibility + " " + (markdown ? MarkdownHelp.summary : MarkdownHelp.offSummary)
    }

    static func footer(for mode: PrompterSettings.ScrollMode, voiceProblem: VoiceProblem? = nil) -> String {
        switch mode {
        case .speed: return "A steady scroll. It follows the text size, so bigger text still moves at the same lines per second."
        case .finishIn: return "Scrolls so the whole script takes this long, and adjusts if you scrub back or forward."
        case .wpm: return "A steady reading pace, counted in words per minute."
        case .voice:
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            let about = "The text follows your voice as you read and waits when you stop. Prompter listens only while the "
                + "text is playing, and only on this \(device): nothing is recorded or sent anywhere. Time left is "
                + "estimated at the pace above."
            guard let voiceProblem else { return about }
            // Problem, remedy and explainer are separate paragraphs.
            return [voiceProblem.message, voiceProblem.remedy, about].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    /// One decimal place in the user's locale: "3.0", "1.6".
    private static func tenths(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// A fraction as a whole percent: 0.06 → "6%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Slider row

/// A title with its live value on the right and a slider underneath.
private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(valueText)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

// MARK: - Finish in

/// Minutes and seconds wheels (10 s to 2 h, 5 s steps) under a "Finish in  m:ss" line.
private struct FinishInRow: View {
    @Binding var seconds: Double

    private static let secondOptions = Array(stride(from: 0, through: 55, by: 5))
    private static let minuteOptions = Array(0...Int(PrompterSettings.finishInRange.upperBound) / 60)

    /// The stored value snapped to the 5 s grid the wheels can show.
    private var snappedSeconds: Int {
        Int((seconds / 5).rounded()) * 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabeledContent("Finish in") {
                Text(TimeFormatting.clock(Double(snappedSeconds)))
                    .monospacedDigit()
            }
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                Picker("Minutes", selection: minutes) {
                    ForEach(Self.minuteOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Seconds", selection: secondsPart) {
                    ForEach(Self.secondOptions, id: \.self) { Text("\($0) s").tag($0) }
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(height: 120)
            .compositingGroup()
            .clipped()
        }
    }

    private var minutes: Binding<Int> {
        Binding(
            get: { snappedSeconds / 60 },
            set: { set(minutes: $0, seconds: snappedSeconds % 60) }
        )
    }

    private var secondsPart: Binding<Int> {
        Binding(
            get: { snappedSeconds % 60 },
            set: { set(minutes: snappedSeconds / 60, seconds: $0) }
        )
    }

    private func set(minutes: Int, seconds newSeconds: Int) {
        let range = PrompterSettings.finishInRange
        seconds = min(max(Double(minutes * 60 + newSeconds), range.lowerBound), range.upperBound)
    }
}

// MARK: - Colors

/// Three swatches ("Aa" in each scheme's colors) with the scheme name underneath; the chosen one gets an amber ring.
/// At accessibility text sizes the swatches stack, so each caption has the whole row to wrap in.
private struct SchemePicker: View {
    @Binding var selection: PrompterSettings.Scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))

        VStack(alignment: .leading, spacing: 8) {
            Text("Colors")
            layout {
                ForEach(PrompterSettings.Scheme.allCases, id: \.self) { scheme in
                    SchemeTile(scheme: scheme, isSelected: scheme == selection) {
                        selection = scheme
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SchemeTile: View {
    let scheme: PrompterSettings.Scheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(background, in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }
                // No line limit: the caption wraps as far as it needs to instead of being cut off at large text sizes.
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var title: String {
        switch scheme {
        case .whiteOnBlack: "White on black"
        case .yellowOnBlack: "Yellow on black"
        case .blackOnWhite: "Black on white"
        }
    }

    private var foreground: Color {
        switch scheme {
        case .whiteOnBlack: .white
        case .yellowOnBlack: Color(red: 1.0, green: 0xD6 / 255.0, blue: 0x0A / 255.0)   // #FFD60A
        case .blackOnWhite: .black
        }
    }

    private var background: Color {
        scheme == .blackOnWhite ? .white : .black
    }
}

// MARK: - Adaptive pickers

/// The Rotation choices: segmented under a title, or one menu row at accessibility text sizes (four degree labels do
/// not fit side by side there).
private struct RotationPicker: View {
    @Binding var selection: PrompterSettings.Rotation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Rotation", selection: $selection) { options }
                .pickerStyle(.menu)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rotation")
                Picker("Rotation", selection: $selection) { options }
                    .pickerStyle(.segmented)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        ForEach(PrompterSettings.Rotation.allCases, id: \.self) { rotation in
            Text("\(rotation.rawValue)°").tag(rotation)
        }
    }
}

private extension View {
    /// Segmented, but a menu at accessibility text sizes, where four or five segments would be squeezed or clipped.
    func segmentedUnlessLargeText() -> some View {
        modifier(SegmentedUnlessLargeText())
    }
}

private struct SegmentedUnlessLargeText: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

#Preview("Form") {
    @Previewable @State var settings = PrompterSettings()
    NavigationStack {
        PrompterSettingsForm(settings: $settings)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
    }
    .preferredColorScheme(.dark)
}
