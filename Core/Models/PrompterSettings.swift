import Foundation

struct PrompterSettings: Codable, Equatable, Sendable {
    enum Rotation: Int, Codable, CaseIterable, Sendable { case none = 0, quarter = 90, half = 180, threeQuarters = 270 }
    enum Weight: String, Codable, CaseIterable, Sendable { case regular, medium, semibold, bold, heavy, black }
    enum Scheme: String, Codable, CaseIterable, Sendable { case whiteOnBlack, yellowOnBlack, blackOnWhite }
    /// `voice` follows the reader's voice (see `VoiceFollowController`). A mode this build doesn't know (written by a
    /// newer one) decodes as the default, like any other unknown value.
    enum ScrollMode: String, Codable, CaseIterable, Sendable { case speed, finishIn, wpm, voice }

    // Geometry
    var mirrorHorizontal: Bool = true
    var flipVertical: Bool = false
    var rotation: Rotation = .none
    var lockLandscape: Bool = true       // keep the prompter in landscape while it is open (the rig is always landscape)
    // Typography (ghost-friendly defaults)
    var fontSize: Double = 72            // points on iPhone
    var fontWeight: Weight = .heavy
    var lineSpacing: Double = 1.6        // multiple of the font's line height
    var sideMargin: Double = 0.06        // fraction of the canvas width, each side
    var scheme: Scheme = .whiteOnBlack
    // Reading line
    var readingLinePosition: Double = 1.0 / 3.0   // fraction of canvas height from the top
    var dimmedOpacity: Double = 0.35              // opacity of text above the reading line
    // Countdown
    var countdownSeconds: Int = 5        // one of countdownOptions
    var countdownBeep: Bool = true
    // Scrolling
    var scrollMode: ScrollMode = .wpm
    var speedLevel: Double = 3.0         // 1.0...10.0, step 0.1
    var finishInSeconds: Double = 300
    var wordsPerMinute: Double = 140     // also voice mode's pace for time left, and its fallback when it can't listen
    // Script formatting
    /// Markdown formatting: `**bold**` in amber, `*italic*`, `# headings`, `- bullets`… with the symbols hidden on the
    /// prompter (see `ScriptMarkdown`). Off: every character shows as written. A script without Markdown looks the same.
    var markdown: Bool = true

    /// The saved blob's keys, one per stored setting. The names are the saved format, so never rename one. Adding a
    /// setting means adding its key here and choosing, in `SettingsSync.swift`, whether it follows the person to their
    /// other devices or stays on this one (that file doesn't compile until the choice is made).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case mirrorHorizontal, flipVertical, rotation, lockLandscape
        case fontSize, fontWeight, lineSpacing, sideMargin, scheme
        case readingLinePosition, dimmedOpacity
        case countdownSeconds, countdownBeep
        case scrollMode, speedLevel, finishInSeconds, wordsPerMinute
        case markdown
    }

    static let countdownOptions: [Int] = [0, 3, 5, 10, 15]
    static let fontSizeRange: ClosedRange<Double> = 24...200
    static let lineSpacingRange: ClosedRange<Double> = 1.0...3.0
    static let sideMarginRange: ClosedRange<Double> = 0.0...0.3
    static let readingLineRange: ClosedRange<Double> = 0.1...0.9
    static let dimmedOpacityRange: ClosedRange<Double> = 0.0...1.0
    static let speedLevelRange: ClosedRange<Double> = 1.0...10.0
    static let finishInRange: ClosedRange<Double> = 10...7200
    static let wpmRange: ClosedRange<Double> = 60...300

    init() {}

    /// Tolerates settings written by older or newer builds: a missing key, an unknown enum case or a value of the
    /// wrong type keeps that setting's default instead of failing the whole decode. The result is clamped.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, or fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        var settings = PrompterSettings()
        settings.mirrorHorizontal = value(.mirrorHorizontal, or: settings.mirrorHorizontal)
        settings.flipVertical = value(.flipVertical, or: settings.flipVertical)
        settings.rotation = value(.rotation, or: settings.rotation)
        settings.lockLandscape = value(.lockLandscape, or: settings.lockLandscape)
        settings.fontSize = value(.fontSize, or: settings.fontSize)
        settings.fontWeight = value(.fontWeight, or: settings.fontWeight)
        settings.lineSpacing = value(.lineSpacing, or: settings.lineSpacing)
        settings.sideMargin = value(.sideMargin, or: settings.sideMargin)
        settings.scheme = value(.scheme, or: settings.scheme)
        settings.readingLinePosition = value(.readingLinePosition, or: settings.readingLinePosition)
        settings.dimmedOpacity = value(.dimmedOpacity, or: settings.dimmedOpacity)
        settings.countdownSeconds = value(.countdownSeconds, or: settings.countdownSeconds)
        settings.countdownBeep = value(.countdownBeep, or: settings.countdownBeep)
        settings.scrollMode = value(.scrollMode, or: settings.scrollMode)
        settings.speedLevel = value(.speedLevel, or: settings.speedLevel)
        settings.finishInSeconds = value(.finishInSeconds, or: settings.finishInSeconds)
        settings.wordsPerMinute = value(.wordsPerMinute, or: settings.wordsPerMinute)
        settings.markdown = value(.markdown, or: settings.markdown)
        self = settings.clamped()
    }

    /// Numbers clamped to their ranges (NaN → default), countdownSeconds snapped to the nearest option.
    func clamped() -> PrompterSettings {
        let defaults = PrompterSettings()
        var settings = self
        settings.fontSize = Self.clamp(fontSize, to: Self.fontSizeRange, nanDefault: defaults.fontSize)
        settings.lineSpacing = Self.clamp(lineSpacing, to: Self.lineSpacingRange, nanDefault: defaults.lineSpacing)
        settings.sideMargin = Self.clamp(sideMargin, to: Self.sideMarginRange, nanDefault: defaults.sideMargin)
        settings.readingLinePosition = Self.clamp(readingLinePosition, to: Self.readingLineRange, nanDefault: defaults.readingLinePosition)
        settings.dimmedOpacity = Self.clamp(dimmedOpacity, to: Self.dimmedOpacityRange, nanDefault: defaults.dimmedOpacity)
        settings.speedLevel = Self.clamp(speedLevel, to: Self.speedLevelRange, nanDefault: defaults.speedLevel)
        settings.finishInSeconds = Self.clamp(finishInSeconds, to: Self.finishInRange, nanDefault: defaults.finishInSeconds)
        settings.wordsPerMinute = Self.clamp(wordsPerMinute, to: Self.wpmRange, nanDefault: defaults.wordsPerMinute)
        settings.countdownSeconds = Self.nearestCountdownOption(to: countdownSeconds)
        return settings
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, nanDefault: Double) -> Double {
        value.isNaN ? nanDefault : min(max(value, range.lowerBound), range.upperBound)
    }

    private static func nearestCountdownOption(to seconds: Int) -> Int {
        let options = countdownOptions
        // Clamp first so the distance arithmetic below can't overflow.
        let target = min(max(seconds, options[0]), options[options.count - 1])
        return options.min { abs($0 - target) < abs($1 - target) } ?? options[0]
    }
}
