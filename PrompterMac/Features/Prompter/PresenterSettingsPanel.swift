import SwiftUI

/// The live settings in the Presenter view: every change shows on the output at once and is saved (it writes the
/// `SettingsStore`, which the session follows). Voice isn't offered on the Mac; a voice setting shows as WPM.
struct PresenterSettingsPanel: View {
    let session: PresenterSession

    var body: some View {
        @Bindable var store = session.settingsStore

        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button {
                    session.isSettingsPanelOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(PresenterTheme.raised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    paceSection(settings: $store.settings)
                    textSection(settings: $store.settings)
                    readingLineSection(settings: $store.settings)
                    orientationSection(settings: $store.settings)
                    countdownSection(settings: $store.settings)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PresenterTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(PresenterTheme.hairline, lineWidth: 1))
    }

    // MARK: Sections

    private func paceSection(settings: Binding<PrompterSettings>) -> some View {
        let mode = Binding<PrompterSettings.ScrollMode>(
            get: { settings.wrappedValue.scrollMode == .voice ? .wpm : settings.wrappedValue.scrollMode },
            set: { settings.wrappedValue.scrollMode = $0 }
        )
        return PanelSection("Pace") {
            ChipPicker("Pace mode", selection: mode, options: [(.wpm, "Words per minute"), (.speed, "Speed"), (.finishIn, "Finish in")])
            switch mode.wrappedValue {
            case .speed:
                SliderRow("Speed", value: settings.speedLevel, in: PrompterSettings.speedLevelRange, step: 0.1) {
                    $0.formatted(.number.precision(.fractionLength(1)))
                }
            case .finishIn:
                SliderRow("Finish in", value: settings.finishInSeconds, in: 10...3600, step: 10) {
                    TimeFormatting.clock($0)
                }
            case .wpm, .voice:
                SliderRow("Words per minute", value: settings.wordsPerMinute, in: PrompterSettings.wpmRange, step: 5) {
                    "\(Int($0.rounded()))"
                }
            }
        }
    }

    private func textSection(settings: Binding<PrompterSettings>) -> some View {
        PanelSection("Text") {
            SliderRow("Size", value: settings.fontSize, in: PrompterSettings.fontSizeRange, step: 1) { "\(Int($0.rounded()))" }
            SliderRow("Line spacing", value: settings.lineSpacing, in: PrompterSettings.lineSpacingRange, step: 0.1) {
                $0.formatted(.number.precision(.fractionLength(1)))
            }
            SliderRow("Side margins", value: settings.sideMargin, in: PrompterSettings.sideMarginRange, step: 0.01) {
                "\(Int(($0 * 100).rounded()))%"
            }
            ChipPicker("Colors", selection: settings.scheme, options: [
                (.whiteOnBlack, "White on black"), (.yellowOnBlack, "Yellow on black"), (.blackOnWhite, "Black on white"),
            ])
            ToggleRow("Markdown formatting", isOn: settings.markdown)
        }
    }

    private func readingLineSection(settings: Binding<PrompterSettings>) -> some View {
        PanelSection("Reading line") {
            SliderRow("Position", value: settings.readingLinePosition, in: PrompterSettings.readingLineRange, step: 0.01) {
                "\(Int(($0 * 100).rounded()))% down"
            }
            SliderRow("Text above the line", value: settings.dimmedOpacity, in: PrompterSettings.dimmedOpacityRange,
                      step: 0.05) {
                "\(Int(($0 * 100).rounded()))%"
            }
        }
    }

    private func orientationSection(settings: Binding<PrompterSettings>) -> some View {
        PanelSection("Mirror and rotation") {
            ToggleRow("Mirror (for the glass)", isOn: settings.mirrorHorizontal)
            ToggleRow("Flip upside down", isOn: settings.flipVertical)
            ChipPicker("Rotation", selection: settings.rotation,
                       options: PrompterSettings.Rotation.allCases.map { ($0, "\($0.rawValue)°") })
        }
    }

    private func countdownSection(settings: Binding<PrompterSettings>) -> some View {
        PanelSection("Countdown") {
            ChipPicker("Countdown length", selection: settings.countdownSeconds,
                       options: PrompterSettings.countdownOptions.map { ($0, $0 == 0 ? "Off" : "\($0) s") })
            ToggleRow("Beep each second", isOn: settings.countdownBeep)
        }
    }
}

// MARK: - Controls

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PresenterTheme.caption(title)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text(format(value))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PresenterTheme.accent)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = $0 }),
                   in: range, step: step)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.system(size: 14, weight: .medium))
        }
        .toggleStyle(AmberSwitchStyle())
    }
}

/// A row of capsules, the selected one amber (a segmented control that reads from a distance).
private struct ChipPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { option in
                let isSelected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 30)
                        .foregroundStyle(isSelected ? .black : .white)
                        .background(isSelected ? PresenterTheme.accent : PresenterTheme.raised,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A switch that reads at a glance on the dark panels: amber when on, grey when off.
struct AmberSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? PresenterTheme.accent : Color.white.opacity(0.18))
                    .frame(width: 40, height: 24)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color.black : Color.white.opacity(0.85))
                            .padding(3)
                    }
                    .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
