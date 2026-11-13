import Foundation

// The rule book for settings sync.
//
// How you read follows you: these settings travel through the iCloud key-value store, one key per setting, so a change on
// one device reaches the others. How this screen is set up stays here: mirror, flip, rotation, landscape lock, text size,
// margins and the reading line belong to the device (a phone in a glass rig and an iPad read directly want different
// ones), and nothing read from iCloud may ever change them.
//
// This file only classifies settings and converts them to and from the store's values. It never talks to iCloud.

/// Where a saved setting lives.
enum SettingSyncScope: Sendable {
    /// Follows the person to their other devices through iCloud.
    case synced
    /// Stays on the device it was set on.
    case thisDevice
}

extension PrompterSettings.CodingKeys {
    /// Every saved setting is classified here, exactly once. There is no `default`, so a new setting doesn't compile
    /// until someone decides where it lives, and `SettingsSplitTests` fails until `SyncedSettingKey` matches the list.
    var syncScope: SettingSyncScope {
        switch self {
        case .scrollMode, .speedLevel, .wordsPerMinute, .finishInSeconds,
             .countdownSeconds, .countdownBeep,
             .scheme, .fontWeight, .lineSpacing, .dimmedOpacity,
             .markdown:
            .synced
        case .mirrorHorizontal, .flipVertical, .rotation, .lockLandscape,
             .fontSize, .sideMargin, .readingLinePosition:
            .thisDevice
        }
    }
}

/// One synced setting. Only these can be read from or written to iCloud; a setting that stays on the device has no case
/// here, so it can't be named in a remote change at all.
enum SyncedSettingKey: String, CaseIterable, Hashable, Sendable {
    case scrollMode, speedLevel, wordsPerMinute, finishInSeconds
    case countdownSeconds, countdownBeep
    case scheme, fontWeight, lineSpacing, dimmedOpacity
    case markdown

    /// The setting's key in the iCloud key-value store, e.g. `settings.v1.speedLevel`.
    var cloudKey: String { SettingsSync.keyPrefix + rawValue }

    /// The synced setting stored under `cloudKey`. Nil for anything else: another format version, a setting that stays
    /// on the device, or a key that isn't a setting.
    init?(cloudKey: String) {
        guard cloudKey.hasPrefix(SettingsSync.keyPrefix) else { return nil }
        self.init(rawValue: String(cloudKey.dropFirst(SettingsSync.keyPrefix.count)))
    }

    /// This setting's value in `settings`, as the store holds it.
    func cloudValue(in settings: PrompterSettings) -> SettingsCloudValue {
        switch self {
        case .scrollMode: .string(settings.scrollMode.rawValue)
        case .speedLevel: .double(settings.speedLevel)
        case .wordsPerMinute: .double(settings.wordsPerMinute)
        case .finishInSeconds: .double(settings.finishInSeconds)
        case .countdownSeconds: .int(settings.countdownSeconds)
        case .countdownBeep: .bool(settings.countdownBeep)
        case .scheme: .string(settings.scheme.rawValue)
        case .fontWeight: .string(settings.fontWeight.rawValue)
        case .lineSpacing: .double(settings.lineSpacing)
        case .dimmedOpacity: .double(settings.dimmedOpacity)
        case .markdown: .bool(settings.markdown)
        }
    }

    /// `settings` with this one setting replaced by `value`, clamped the same way as the saved blob
    /// (`PrompterSettings.clamped()`). Every other setting stays exactly as it was, even one that isn't clamped.
    ///
    /// Nil when this build can't use the value: the wrong type, an enum case it doesn't know (written by a newer build),
    /// or NaN. The caller then keeps its own value and must never write this one back. Out-of-range numbers are clamped,
    /// and so is infinity for a decimal setting. The countdown takes an `.int` or a whole-number `.double` (a fraction or
    /// infinity is ignored), and any decimal setting also takes an `.int`.
    func applying(_ value: SettingsCloudValue, to settings: PrompterSettings) -> PrompterSettings? {
        var result = settings
        switch self {
        case .scrollMode:
            guard let mode = value.text.flatMap(PrompterSettings.ScrollMode.init(rawValue:)) else { return nil }
            result.scrollMode = mode
        case .scheme:
            guard let scheme = value.text.flatMap(PrompterSettings.Scheme.init(rawValue:)) else { return nil }
            result.scheme = scheme
        case .fontWeight:
            guard let weight = value.text.flatMap(PrompterSettings.Weight.init(rawValue:)) else { return nil }
            result.fontWeight = weight
        case .speedLevel:
            guard let number = value.number else { return nil }
            result.speedLevel = Self.clamped(\.speedLevel, number)
        case .wordsPerMinute:
            guard let number = value.number else { return nil }
            result.wordsPerMinute = Self.clamped(\.wordsPerMinute, number)
        case .finishInSeconds:
            guard let number = value.number else { return nil }
            result.finishInSeconds = Self.clamped(\.finishInSeconds, number)
        case .lineSpacing:
            guard let number = value.number else { return nil }
            result.lineSpacing = Self.clamped(\.lineSpacing, number)
        case .dimmedOpacity:
            guard let number = value.number else { return nil }
            result.dimmedOpacity = Self.clamped(\.dimmedOpacity, number)
        case .countdownSeconds:
            guard let whole = value.wholeNumber else { return nil }
            result.countdownSeconds = Self.clamped(\.countdownSeconds, whole)
        case .countdownBeep:
            guard let flag = value.flag else { return nil }
            result.countdownBeep = flag
        case .markdown:
            guard let flag = value.flag else { return nil }
            result.markdown = flag
        }
        return result
    }

    /// The value as this build would keep it (clamped, in its usual type), or nil when this build can't use it. See
    /// `applying(_:to:)`.
    func decode(_ value: SettingsCloudValue) -> SettingsCloudValue? {
        applying(value, to: PrompterSettings()).map(cloudValue(in:))
    }

    /// Clamps one value through `PrompterSettings.clamped()` on a scratch copy, so the rules live in one place and no
    /// other setting is touched.
    private static func clamped<Value>(_ keyPath: WritableKeyPath<PrompterSettings, Value>, _ value: Value) -> Value {
        var scratch = PrompterSettings()
        scratch[keyPath: keyPath] = value
        return scratch.clamped()[keyPath: keyPath]
    }
}

/// One setting as the iCloud key-value store holds it: a property-list flag, number or string.
enum SettingsCloudValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// The object to hand to the store (`NSUbiquitousKeyValueStore.set(_:forKey:)`).
    var propertyListObject: Any {
        switch self {
        case .bool(let flag): flag
        case .int(let integer): integer
        case .double(let number): number
        case .string(let text): text
        }
    }

    /// Reads an object the store handed back (`NSUbiquitousKeyValueStore.object(forKey:)`). The store returns
    /// `NSNumber` for flags and numbers alike, so the number's own type decides: a boolean is `.bool`, a floating-point
    /// number is `.double`, any other number is `.int`. Nil for anything that isn't a flag, number or string (data,
    /// dates, arrays, dictionaries).
    init?(propertyListObject object: Any) {
        switch object {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                self = .double(number.doubleValue)
            } else {
                // An unsigned 64-bit number above Int64.max would read back negative through int64Value. Integers
                // that don't fit Int are no setting's value, so they're dropped.
                let type = String(cString: number.objCType)
                let integer = type == "Q" || type == "L"
                    ? Int(exactly: number.uint64Value)
                    : Int(exactly: number.int64Value)
                guard let integer else { return nil }
                self = .int(integer)
            }
        default:
            return nil
        }
    }

    fileprivate var text: String? {
        if case .string(let text) = self { text } else { nil }
    }

    fileprivate var flag: Bool? {
        if case .bool(let flag) = self { flag } else { nil }
    }

    /// Any number but NaN (which would otherwise reset a good local value). Infinity is left for clamping.
    fileprivate var number: Double? {
        switch self {
        case .double(let number): number.isNaN ? nil : number
        case .int(let integer): Double(integer)
        case .bool, .string: nil
        }
    }

    /// An integer, or a `.double` with nothing after the point. A fraction is the wrong type, as in the saved blob.
    fileprivate var wholeNumber: Int? {
        switch self {
        case .int(let integer):
            return integer
        case .double(let number):
            guard number.isFinite, number.rounded(.towardZero) == number else { return nil }
            // Far outside any setting's range; bounded first so the conversion can't trap.
            return Int(min(max(number, -1e9), 1e9))
        case .bool, .string:
            return nil
        }
    }
}

/// Converts settings to and from the iCloud key-value store's entries. Pure: the settings store's iCloud bridge does the
/// reading, writing and timing.
enum SettingsSync {
    /// Every synced key starts with this. A later format can live beside it under another version.
    static let keyPrefix = "settings.v1."

    /// Store entries for the given synced settings, keyed by `SyncedSettingKey.cloudKey`.
    static func cloudEntries(
        for settings: PrompterSettings,
        keys: some Sequence<SyncedSettingKey>
    ) -> [String: SettingsCloudValue] {
        var entries: [String: SettingsCloudValue] = [:]
        for key in keys { entries[key.cloudKey] = key.cloudValue(in: settings) }
        return entries
    }

    /// Store entries for every synced setting.
    static func cloudEntries(for settings: PrompterSettings) -> [String: SettingsCloudValue] {
        cloudEntries(for: settings, keys: SyncedSettingKey.allCases)
    }

    /// The synced settings found among the store's entries (`dictionaryRepresentation`, or the changed keys of a
    /// change notice). Everything else is dropped: other format versions, keys of settings that stay on the device,
    /// unrelated keys, and objects that aren't a flag, number or string. Values aren't checked here; `applying` does it.
    static func remoteValues(from entries: [String: Any]) -> [SyncedSettingKey: SettingsCloudValue] {
        var values: [SyncedSettingKey: SettingsCloudValue] = [:]
        for (cloudKey, object) in entries {
            guard let key = SyncedSettingKey(cloudKey: cloudKey),
                  let value = SettingsCloudValue(propertyListObject: object) else { continue }
            values[key] = value
        }
        return values
    }

    /// `settings` with the values read from iCloud applied. Only synced settings can change, and each one is clamped like
    /// the saved blob. A value this build can't use is skipped: that setting keeps its local value.
    static func applying(
        _ remote: [SyncedSettingKey: SettingsCloudValue],
        to settings: PrompterSettings
    ) -> PrompterSettings {
        var result = settings
        // A fixed order keeps the result independent of the dictionary's.
        for key in SyncedSettingKey.allCases {
            guard let value = remote[key], let applied = key.applying(value, to: result) else { continue }
            result = applied
        }
        return result
    }

    /// The synced settings whose values differ between `old` and `new`. Settings that stay on the device never count.
    static func changedSyncedKeys(from old: PrompterSettings, to new: PrompterSettings) -> Set<SyncedSettingKey> {
        Set(SyncedSettingKey.allCases.filter { $0.cloudValue(in: old) != $0.cloudValue(in: new) })
    }
}
