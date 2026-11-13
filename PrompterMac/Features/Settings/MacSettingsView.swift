import AppKit
import SwiftUI

enum MacSettingsTab: String, CaseIterable, Hashable, Sendable {
    case general, text, teleprompter, library, help, iphone
}

/// Lets the rest of the app open Settings on a given tab ("Pair an iPhone…" in the library and the File menu): the
/// requested tab is read (and cleared) by the Settings window when it appears or while it is already open.
@MainActor @Observable
final class MacSettingsRouter {
    var requestedTab: MacSettingsTab?

    /// Opens Settings on `tab`.
    func show(_ tab: MacSettingsTab, using openSettings: OpenSettingsAction) {
        requestedTab = tab
        openSettings()
    }
}

private extension View {
    /// A settings tab's page: a fixed size and nothing around it. The grouped Form's grey background reaches up under the
    /// tab bar, so any padding outside the page left the window's darker edges showing beside it as a cut-off box. The
    /// grouped Form insets its own sections, so the page needs no padding of its own.
    func settingsPage(height: CGFloat) -> some View {
        frame(width: 600, height: height)
    }
}

/// The Settings window (⌘,): the prompter settings in tabs, bound straight to `SettingsStore`, so the prompter picks
/// them up as they change.
struct MacSettingsView: View {
    @State private var tab: MacSettingsTab
    @Environment(MacSettingsRouter.self) private var router

    init(initialTab: MacSettingsTab = .general) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: MacSettingsTab.general) {
                GeneralSettingsTab()
                    .settingsPage(height: 400)
            }
            Tab("Text", systemImage: "textformat", value: MacSettingsTab.text) {
                TextSettingsTab()
                    .settingsPage(height: 640)
            }
            Tab("Teleprompter", systemImage: "rectangle.on.rectangle", value: MacSettingsTab.teleprompter) {
                TeleprompterSettingsTab()
                    .settingsPage(height: 640)
            }
            Tab("Library", systemImage: "books.vertical", value: MacSettingsTab.library) {
                LibrarySettingsTab()
                    .settingsPage(height: 470)
            }
            Tab("How to use", systemImage: "questionmark.circle", value: MacSettingsTab.help) {
                MacHelpTab()
                    .settingsPage(height: 660)
            }
            // Pairing and sync with the iPhone. It sits last so it stays out of the way.
            Tab("iPhone", systemImage: "iphone", value: MacSettingsTab.iphone) {
                MacSyncSettingsTab()
                    .settingsPage(height: 500)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: router.requestedTab, initial: true) {
            guard let requested = router.requestedTab else { return }
            tab = requested
            router.requestedTab = nil
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var settingsStore = settingsStore
        let settings = $settingsStore.settings

        Form {
            Section {
                Picker("Pace", selection: settings.scrollMode) {
                    ForEach(Self.modes, id: \.self) { mode in
                        Text(Self.title(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch settingsStore.settings.scrollMode {
                case .speed:
                    SettingsSlider(
                        title: "Speed", value: settings.speedLevel, range: PrompterSettings.speedLevelRange, step: 0.1,
                        valueText: SettingsFormat.tenths(settingsStore.settings.speedLevel)
                    )
                case .finishIn:
                    LabeledContent("Finish in") {
                        Stepper(value: settings.finishInSeconds, in: PrompterSettings.finishInRange, step: 15) {
                            Text(TimeFormatting.clock(settingsStore.settings.finishInSeconds))
                                .monospacedDigit()
                        }
                    }
                case .wpm, .voice:
                    SettingsSlider(
                        title: "Words per minute", value: settings.wordsPerMinute, range: PrompterSettings.wpmRange,
                        step: 1, valueText: "\(Int(settingsStore.settings.wordsPerMinute.rounded())) wpm"
                    )
                }
            } header: {
                Text("Scrolling")
            } footer: {
                Text(Self.footer(for: settingsStore.settings.scrollMode))
            }

            Section {
                Picker("Countdown", selection: settings.countdownSeconds) {
                    ForEach(PrompterSettings.countdownOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) s").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Beep each second", isOn: settings.countdownBeep)
                    .disabled(settingsStore.settings.countdownSeconds == 0)
            } header: {
                Text("Countdown")
            } footer: {
                Text("Gives you time to get into position before the text starts.")
            }
        }
        .formStyle(.grouped)
    }

    /// Voice follow listens through the iPhone's microphone and stays an iPhone feature.
    private static let modes: [PrompterSettings.ScrollMode] = [.wpm, .speed, .finishIn]

    private static func title(for mode: PrompterSettings.ScrollMode) -> String {
        switch mode {
        case .speed: "Speed"
        case .finishIn: "Finish in"
        case .wpm, .voice: "Words per minute"
        }
    }

    private static func footer(for mode: PrompterSettings.ScrollMode) -> String {
        switch mode {
        case .speed: "A steady scroll. It follows the text size, so bigger text still moves at the same lines per second."
        case .finishIn: "Scrolls so the whole script takes this long, and adjusts if you scrub back or forward."
        case .wpm, .voice: "A steady reading pace, counted in words per minute."
        }
    }
}

// MARK: - Text

private struct TextSettingsTab: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var settingsStore = settingsStore
        let settings = $settingsStore.settings
        let current = settingsStore.settings

        Form {
            Section {
                TextPreview(settings: current)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text(current.mirrorHorizontal ? "Preview, mirrored as it shows in the glass." : "Preview.")
            }

            Section {
                SettingsSlider(
                    title: "Size", value: settings.fontSize, range: PrompterSettings.fontSizeRange, step: 1,
                    valueText: "\(Int(current.fontSize.rounded())) pt"
                )
                Picker("Weight", selection: settings.fontWeight) {
                    ForEach(PrompterSettings.Weight.allCases, id: \.self) { weight in
                        Text(Self.title(for: weight)).tag(weight)
                    }
                }
                SettingsSlider(
                    title: "Line spacing", value: settings.lineSpacing, range: PrompterSettings.lineSpacingRange,
                    step: 0.1, valueText: "\(SettingsFormat.tenths(current.lineSpacing))×"
                )
                SettingsSlider(
                    title: "Side margins", value: settings.sideMargin, range: PrompterSettings.sideMarginRange,
                    step: 0.01, valueText: SettingsFormat.percent(current.sideMargin)
                )
                Toggle("Markdown formatting", isOn: settings.markdown)
                    .accessibilityHint("Shows bold text in amber, italics, headings and lists, and hides the symbols.")
            } header: {
                Text("Text")
            } footer: {
                Text(verbatim: "Big, heavy, widely spaced text is easiest to read through the glass. "
                    + (current.markdown ? MarkdownHelp.summary : MarkdownHelp.offSummary))
            }

            Section("Colors") {
                SchemePicker(selection: settings.scheme)
            }
        }
        .formStyle(.grouped)
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
}

// MARK: - Teleprompter

private struct TeleprompterSettingsTab: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var settingsStore = settingsStore
        let settings = $settingsStore.settings
        let current = settingsStore.settings

        Form {
            Section {
                TextPreview(settings: current)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text(current.mirrorHorizontal ? "Preview, mirrored as it shows in the glass." : "Preview.")
            }

            Section {
                Toggle("Mirror (for the glass)", isOn: settings.mirrorHorizontal)
                Toggle("Flip upside down", isOn: settings.flipVertical)
                Picker("Rotation", selection: settings.rotation) {
                    ForEach(PrompterSettings.Rotation.allCases, id: \.self) { rotation in
                        Text("\(rotation.rawValue)°").tag(rotation)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Mirror and rotation")
            } footer: {
                Text("Mirror flips the text left to right so it reads correctly in the glass. If the text is upside down in the glass, set Rotation to 180°.")
            }

            Section {
                SettingsSlider(
                    title: "Position from top", value: settings.readingLinePosition,
                    range: PrompterSettings.readingLineRange, step: 0.01,
                    valueText: SettingsFormat.percent(current.readingLinePosition)
                )
                SettingsSlider(
                    title: "Dim text above", value: settings.dimmedOpacity,
                    range: PrompterSettings.dimmedOpacityRange, step: 0.01,
                    valueText: SettingsFormat.percent(current.dimmedOpacity)
                )
            } header: {
                Text("Reading line")
            } footer: {
                Text("Text above the line is dimmed, so your eye lands on the next line.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Library

private struct LibrarySettingsTab: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ScriptStore.self) private var scriptStore
    @State private var isConfirmingReset = false
    @State private var didRestoreSample = false

    private var sampleExists: Bool {
        scriptStore.script(id: SampleScript.id) != nil
    }

    var body: some View {
        Form {
            Section {
                Button(action: restoreSample) {
                    if didRestoreSample {
                        Label("Sample script restored", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Restore sample script", systemImage: "arrow.counterclockwise")
                    }
                }
                .disabled(sampleExists)
            } header: {
                Text("Sample script")
            } footer: {
                Text(sampleFooter)
            }

            Section {
                Button("Show scripts in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([scriptStore.fileURL])
                }
            } header: {
                Text("Your scripts")
            } footer: {
                Text("Scripts are saved on this Mac, in one file. They are sent only to an iPhone you pair, over your own network.")
            }

            Section {
                Button("Reset all settings…", role: .destructive) {
                    isConfirmingReset = true
                }
            } footer: {
                Text("Text, orientation, countdown and pace go back to their defaults. Your scripts are not changed.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset all settings", role: .destructive) { settingsStore.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text, orientation, countdown and pace go back to their defaults. Your scripts are not changed.")
        }
    }

    private var sampleFooter: String {
        if didRestoreSample { return "“\(SampleScript.title)” is back in your library." }
        if sampleExists { return "“\(SampleScript.title)” is already in your library." }
        return "Adds “\(SampleScript.title)” back to your library."
    }

    private func restoreSample() {
        scriptStore.restoreSampleScript()
        didRestoreSample = sampleExists
    }
}

// MARK: - How to use

private struct MacHelpTab: View {
    var body: some View {
        Form {
            Section("In the library") {
                HelpRow("⌘N", "New script.")
                HelpRow("⇧⌘V", "Paste the clipboard as a new script. The first line becomes its title.")
                HelpRow("⌘O, or drop files on the window", "Import .txt, .md, .rtf and .pdf files.")
                HelpRow("⌘D", "Duplicate the open script.")
                HelpRow("Delete", "Delete the selected script. ⌘Z brings it back.")
                HelpRow("⌘↩", "Prompt the open script.")
            }

            Section("While presenting") {
                HelpRow("Space or Return", "Start or pause. The first press starts the countdown.")
                HelpRow(
                    "Arrow keys, Page Up and Page Down",
                    "Up, left and Page Up go back a line. Down, right and Page Down go forward a line. Hold Shift to move a whole paragraph."
                )
                HelpRow("+ and −", "Faster and slower.")
                HelpRow("0", "Back to the top.")
                HelpRow("Esc", "Pause a running take. Press Esc again to stop presenting.")
            }

            Section {
                HelpRow(
                    "Connect the screen",
                    "Connect the screen over HDMI. Prompt puts the text on that screen and a control view on this one. Esc pauses, a second Esc stops."
                )
                HelpRow(
                    "Text on this Mac instead?",
                    "If the text shows on this Mac instead, turn off Mirror Displays in System Settings → Displays."
                )
            } header: {
                Text("Teleprompter screen")
            }

            Section {
                HelpRow("// note", "A line that starts with // is a note for you. It is dimmed, and it is not read or counted.")
                HelpRow("[pause 2]", "A line with just this holds the text for two seconds. Use any number from 1 to 60.")
            } header: {
                Text("Notes and pauses")
            }

            Section {
                ForEach(MarkdownHelp.rows, id: \.syntax) { row in
                    HelpRow(row.syntax, row.detail)
                }
            } header: {
                Text("Markdown formatting")
            } footer: {
                Text(verbatim: MarkdownHelp.footer)
            }

            Section {
                HelpRow("iPhone", "Tap to start or pause, drag to scrub, pinch to resize, long-press for settings.")
                HelpRow("Apple Watch", "Start or pause, turn the Digital Crown for speed, Back to top, Jump back. Open the prompter on the iPhone first.")
            } header: {
                Text("iPhone and Apple Watch")
            } footer: {
                Text("Pair your iPhone in Settings → iPhone, and your scripts sync between the two while Prompter is open on both.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared pieces

enum SettingsFormat {
    /// One decimal place in the user's locale: "3.0", "1.6".
    static func tenths(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// A fraction as a whole percent: 0.06 → "6%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

/// A title with its live value on the right and a slider under it.
private struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 220)
                    .accessibilityLabel(title)
                    .accessibilityValue(valueText)
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct HelpRow: View {
    let action: String
    let detail: String

    init(_ action: String, _ detail: String) {
        self.action = action
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action)
                .fontWeight(.semibold)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What the prompter text looks like with the current settings: colors, weight, spacing, mirror, flip and rotation.
private struct TextPreview: View {
    let settings: PrompterSettings

    var body: some View {
        let colors = Self.colors(for: settings.scheme)
        // The prompter's size is in iPhone points over a 874-pt-wide screen; the preview is about a third of that.
        let size = min(max(settings.fontSize * 0.36, 12), 46)
        ZStack {
            colors.background
            Text("Look into the lens,\nthen start talking.")
                .font(.system(size: size, weight: Self.weight(for: settings.fontWeight)))
                .lineSpacing(max(settings.lineSpacing - 1, 0) * size * 1.2)
                .multilineTextAlignment(.center)
                .foregroundStyle(colors.text)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 24 + settings.sideMargin * 200)
                .scaleEffect(x: settings.mirrorHorizontal ? -1 : 1, y: settings.flipVertical ? -1 : 1)
                .rotationEffect(.degrees(Double(settings.rotation.rawValue)))
        }
        .frame(height: 130)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(10)
        .accessibilityLabel("Preview of the prompter text")
    }

    static func weight(for weight: PrompterSettings.Weight) -> Font.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    static func colors(for scheme: PrompterSettings.Scheme) -> (text: Color, background: Color) {
        switch scheme {
        case .whiteOnBlack: (.white, .black)
        case .yellowOnBlack: (Color(red: 1.0, green: 0xD6 / 255.0, blue: 0x0A / 255.0), .black)   // #FFD60A
        case .blackOnWhite: (.black, .white)
        }
    }
}

/// Three swatches ("Aa" in each scheme's colors) with the scheme name underneath; the chosen one gets an amber ring.
private struct SchemePicker: View {
    @Binding var selection: PrompterSettings.Scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(PrompterSettings.Scheme.allCases, id: \.self) { scheme in
                SchemeTile(scheme: scheme, isSelected: scheme == selection) { selection = scheme }
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
        let colors = TextPreview.colors(for: scheme)
        Button(action: action) {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(colors.text)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(colors.background, in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
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
}
